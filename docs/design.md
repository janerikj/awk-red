# Design notes

Why awk-red is built the way it is, what was tried first, and what is worth
building next. The user-facing documentation is in [README.md](../README.md).

## Why AWK at all

Node-RED is a flow engine: subscribe, filter, transform, decide, call out.
That maps unusually well onto `pattern { action }`:

| Node-RED | awk-red |
| --- | --- |
| MQTT in node | `mosquitto_sub -v` |
| switch node | topic regex in `reg()` |
| change/function node | the handler function body |
| function node calling out | `emit()`, `pub()` |
| context / flow variables | AWK globals and arrays |
| deploy | drop a file into the rule directory |

The interesting property is that a whole automation is a few lines of plain
text in a file you can `cat`, `git diff` and edit over SSH. The cost is that
AWK gives you no structure beyond what you build yourself, and that is
exactly what `lib/router.awk` is.

## Why two files instead of one AWK program

AWK is good at matching, transforming and dispatching. It is poor at process
management, argument parsing, environment files and dependency checks, so
those live in `awk-red`:

| Job | Where | Why |
| --- | --- | --- |
| load `.env`, export configuration | shell | sourcing a file is shell work; AWK has no file inclusion at all |
| flags, defaults, precedence | shell | `getopts` / `case` beats AWK's `ARGV` juggling |
| check that `gawk`, `mosquitto_sub` and `stdbuf` exist | shell | `command -v`, and a good error message |
| discover rule files, build the program | shell | globbing and sorting are shell work |
| line buffering | shell | must be set on the process *before* it starts |
| know the pids, shut them down | shell | AWK has no process supervision |
| match, transform, dispatch | AWK | what AWK is for |

The engine reads its configuration from `ENVIRON`, which means the two halves
only meet in environment variables. That boundary is also what makes the
engine testable on its own:

```shell
echo "test/temp 34" | DRYRUN=1 gawk -f lib/router.awk -f examples/temp.awk
```

## No `main.awk`, no `@include`

The first version had an explicit include list:

```awk
@include "router.awk"
@include "rules/temp.awk"
@include "rules/door.awk"
```

Every new rule meant editing that file, and the obvious automatic version does
not work:

* `gawk -f rules/*.awk` fails silently: the glob expands to separate arguments
  and everything after the first is treated as an *input file*, so stdin is
  never read and the program appears to do nothing.
* `@include "rules/*.awk"` does not glob either (tested on gawk 5.3).

So `./awk-red` assembles the program itself, one `-f` per file:

```shell
gawk -f lib/router.awk -f rules/door.awk -f rules/temp.awk
```

The rule directory is a flag (`-r`, default `examples`), the files are sorted
with `LC_ALL=C sort` so load order is identical on every machine, and a new
rule never requires touching anything else.

## Dispatch

```awk
function reg(pattern, handler, description)
```

Patterns are regexes matched against the topic. All matching rules run, in
registration order; `--first-match` turns that into the first-match-wins
semantics a switch node usually has.

The engine keeps three parallel arrays (`ROUTE`, `HANDLER`, `DESC`) indexed by
registration number. An earlier version used an associative array plus a
separate order array, which silently collapses two rules that register the
same pattern. Parallel arrays also make the order explicit instead of
inherited from hash iteration.

Handlers are called indirectly:

```awk
fn = HANDLER[i]
@fn(topic, payload)
```

The `@` is required by gawk for a call through a variable, which is also why
awk-red needs gawk and not mawk.

## Handlers get arguments, not `$0`

An early draft rewrote `$0` in the router so rules could compare `$2`, which
is neat for plain topics:

```awk
$1 == "sensor/temp" && $2 > 24 { print "varmt" }
```

It was dropped. Field splitting throws away information - a payload of
`a b c` arrives as `$2` and `$3`, and `substr($0, length($1) + 2)` is the only
way back to the original string. Passing `topic` and `payload` to the handler
keeps the payload whole, which matters as soon as a rule handles JSON, dates
or free text:

```awk
function temp_handler(topic, payload) {
    if (payload + 0 > 30)          # + 0, payload is a string
        pub("alarm/temp", "hot: " payload "C")
}
```

## Side effects belong to the engine

Rules never call `system()` or `mosquitto_pub` directly. They call `emit()`,
`pub()` or `notify()`, and the engine decides what that means. Three things
fall out of that:

* **`--dry-run` covers everything.** One switch prints every command instead
  of running it, so a full test run needs no broker and no side effects.
* **Connection details live in one place.** A rule says
  `pub("alarm/temp", "hot")`; host, port, credentials and TLS come from the
  configuration. Rules stay portable between brokers.
* **Quoting is handled once.** `shquote()` wraps values in single quotes and
  escapes embedded quotes, so a payload with spaces or a `'` cannot break the
  command line.

One subtlety worth recording: the first version did

```awk
DRYRUN = getenv("DRYRUN", "1")
function emit(cmd) { if (DRYRUN) ... }
```

and `DRYRUN=0` still dry-ran everything, because the string `"0"` is a
non-empty string and therefore true in AWK. The engine now coerces with
`envbool()`, which only accepts `1`, `true`, `yes` or `on`.

## Payload formats

Topics do not agree on a format, and forcing everything into one
serialisation - `key=value` pairs, say - breaks the plain publishers and ties
every rule to that choice. The principle instead: **rules match on topic and
fields, and the payload format is hidden per topic.**

**Variant 1, per-topic adapter (implemented).** The engine keeps a table of
topic pattern to `jq` filter. The payload is passed through `jq` and the rule
sees the extracted value, so plain and JSON topics share one handler
implementation. The coprocess is persistent, one per adapter, and started on
first use.

**Variant 2, parse in AWK (documented, not implemented).** Leave the payload
raw and parse it into an associative array, for example with `JSON.awk`.
No external processes, tolerant of nested structures and spaces in values. The
cost is a third-party parser to maintain, and rules end up mixing `$2` and
`V["/temp"]` access styles.

**Guideline:** few, known, flat JSON schemas -> variant 1, because the rule
code stays identical for both formats. Deeply nested or varying schemas, or a
host without `jq` -> variant 2.

Adapter footguns, all of them hit during development:

* The filter must yield **exactly one line per message**. `head -n 1` drops
  extras, and a filter that yields nothing desyncs every later message.
* Both sides must flush per message, `fflush(cmd)` in the engine and
  `--unbuffered` on `jq`, or the pair deadlocks on a full buffer.
* **Draining the coprocess deadlocks.** After reading the value, waiting for
  EOF means waiting for `jq` to exit, which it never does while its stdin is
  open. Read exactly one line instead.
* A missing `jq` makes gawk's coprocess start fail fatally, taking the router
  with it, so the engine checks for `jq` before registering an adapter.
* Filters go through a shell, so a filter containing a single quote is
  rejected rather than quoted into something surprising.

## Buffering between stages

This is the single most common way an awk-red-like setup appears broken.

libc block-buffers stdout when the destination is a pipe or a file: 4-8 KB at
a time. A terminal is line buffered, which is why manual testing always looks
correct while a pipe, a service or a log file stands still. Every stage in the
chain is affected, including `jq`.

awk-red uses `stdbuf -oL` on **both** stages:

```shell
stdbuf -oL mosquitto_sub -v -t '#' &
stdbuf -oL gawk -f lib/router.awk -f rules/*.awk < "$fifo" &
```

`stdbuf` works because both programs use libc stdio. The engine additionally
calls `fflush()` after every message, which is cheap insurance, but it cannot
help the other stage: `fflush()` inside AWK only touches AWK's own stdout. If
mosquitto_sub is buffering, the fix has to be on the reading side of the
pipe. Programs that buffer themselves need their own flag instead -
`jq --unbuffered`, which awk-red passes.

To find out which stage is at fault:

```shell
mosquitto_sub -v -t '#' | cat                                    # buffered? sub is
stdbuf -oL mosquitto_sub -v -t '#' | awk '{print; fflush("")}'   # still stuck? awk is
```

Worth knowing while testing this: gawk flushes its output before it reads a
record, so a program that prints and then blocks on *input* looks line buffered
whether it is or not. `perl` is not affected by `stdbuf` at all - it buffers in
its own IO layer, not in libc. To see block buffering for real you need a
program that prints and then blocks somewhere that is not an input read, which
is what `test/fake-mosquitto-sub` does.

`mawk -W interactive` was the other option, and it works, but mawk cannot run
awk-red anyway.

## A fifo instead of a pipeline

The obvious live mode is a two-stage pipeline. It has one problem: bash does
not expose the pid of each stage, so when gawk dies, `mosquitto_sub` keeps
sitting on the broker connection until the next message arrives - it never
gets EPIPE because nobody writes to it. Over weeks that is a quietly leaked
connection and a surprise on the next start.

Connecting the stages through a fifo makes the writers reachable. awk-red goes
one step further and puts everything that writes to the fifo into one writer
process:

```
write_loop (background subshell, owns the fifo)
  |- mosquitto_sub     the subscription
  |- tick_loop         the clock, when --tick is on

gawk -f lib/router.awk ... < "$fifo"          the engine
```

`write_loop` runs as a subshell with the fifo as its stdout, so starting the
subscriber and the clock are ordinary child starts and `wait`ing for the
subscriber is legal - it is this process's own child, not a sibling. That one
rule is what the fifo bought:

* **The run ends with the subscription.** A refused login, a broker that went
  away or a plain disconnect ends the `wait`, the writer closes the fifo, and
  the engine sees end of input and exits by itself.
* **The writer's status is mosquitto_sub's status**, so a rejected login
  arrives as exit 5 instead of as a silent success.
* **The clock cannot outlive the subscription**, because the writer is its
  parent and kills it on the way out.

awk-red then waits for the engine and reports its status, falling back to the
writer's status only when the engine had nothing to fail about. Either process
exiting leads to a deterministic shutdown, and the fifo is removed on every
exit path.

### Polling was the first answer, and it was wrong

The first version kept all three pids in awk-red and polled them every half
second until one of them stopped. Three bugs came out of that, and all three
were shell bugs:

* `kill -0` succeeds on a zombie, so "is it still running?" had to read
  `/proc/<pid>/stat` and inspect the state field.
* Stopping three children in turn meant the survivor was only signalled after
  the earlier `wait` returned, and one ordering left the clock running.
* A 143 from gawk had to be interpreted. It means either "the subscription died
  and I stopped the reader" or "somebody asked us to stop", and the exit status
  alone cannot tell you which.

One writer process makes all three questions unnecessary, and `wait -n` would
not have helped either: it reports that a child finished but swallows which one
and what it returned. Polling also cost up to half a second of shutdown latency;
with the writer, a dead subscription ends the run in roughly 30 ms.

## Signals

Children of a non-interactive shell inherit `SIGINT` and `SIGQUIT` as
*ignored*, so `kill -INT` on a background `mosquitto_sub` or `gawk` does
nothing at all. The shutdown path therefore sends `SIGTERM` and escalates to
`SIGKILL` after a second if a child ignores it, and treats exit status 143 as
a requested stop rather than a failure.

`SIGTERM` is what systemd sends, so this is the path that matters in
production; `SIGINT` (Ctrl-C) works because the trap is installed in the
foreground shell, where signals are not inherited as ignored.

Two rules came out of testing signals rather than assuming them. A process that
starts a child owns it: a `sleep` in the foreground of a loop cannot be reached
by a trap, so it survives the loop and holds the fifo open - the clock keeps its
sleep in the background and kills it from the trap. And a script that dies on
`SIGTERM` leaves its foreground child behind, so a trap has to kill the child
too, not just exit.

## Process bugs are shell bugs, not AWK bugs

Every bug found while building the clock was in the shell layer: the ticker's
foreground `sleep` outliving its own loop, `wait` on a sibling that is not a
child, a zombie that answered `kill -0`, `SIGINT` inherited as ignored in a
background job, and a redirect test that passed for the wrong reason. The engine
was never at fault - routing, the edge-detection state and the `|&` coprocess to
`jq` behaved in every case.

That is the argument for keeping the split rather than moving the supervisor:

* **bash** owns flags, `.env`, dependency checks and the process lifecycle.
  Nothing else can start `mosquitto_sub`, hand it a fifo and reap it afterwards.
* **gawk** owns the stream: `getline` on the fifo, `$0` and `FS`, associative
  arrays for rule and edge state, and `|&` for the bidirectional coprocess `jq`
  requires.

Porting the supervisor to AWK would have kept every bug it caused, because those
bugs are in `fork`, `wait`, `kill` and trap semantics - all of which live in the
shell, not in the interpreter. Porting it to bash would have discarded the part
that works. So the fix was to make the shell layer correct and then test it.

## What the tests are for

`test/run.sh` needs no broker: `MOSQ_SUB` is overridable and
`test/fake-mosquitto-sub` produces the failure paths on demand - a refused
subscription, one that dies, one that delivers nothing, one that block-buffers.
Nothing that shaped the supervision code was an MQTT bug, so a real broker would
only add flakiness.

Three traps the tests had to avoid, each of which cost time:

* **Background jobs ignore `SIGINT`.** A Ctrl-C case that runs awk-red with `&`
  and then sends `SIGINT` passes for the wrong reason: the signal was inherited
  as `SIG_IGN`. The Ctrl-C case uses `timeout` in the foreground instead.
* **A name is not a pid.** Leftovers matched with `pgrep -f mosquitto` or
  `pkill -f` find the test runner itself. The suite runs with `set -m` and checks
  `pgrep -g` against the process group it started, killing that group and no
  other.
* **A payload that triggers nothing looks like a broken test.** The first
  buffering case sent `message 1` to a temperature rule, which correctly did
  nothing, and the case reported "no output" - indistinguishable from the
  buffering bug it was written to catch. The fake now takes an explicit payload,
  and the case inspects the output while awk-red is still running, so a
  block-buffered engine cannot pass by being flushed at exit.

The suite is worth what its failures are worth, so each guarantee was checked by
breaking it on purpose: removing `stdbuf -oL` fails the buffering case, removing
the clock's trap fails two cases, and the leftover check is what caught the
`sleep` leak in the first place.

## Things that were tried and dropped

* **`@include` lists in a `main.awk`** - a file to maintain, and the glob
  variants do not work. Replaced by flag-driven assembly.
* **Normalising every payload to `key=value`** - breaks plain publishers and
  binds rules to one serialisation. Replaced by per-topic adapters.
* **gawk as a single program including everything** - no room for `.env`,
  dependency checks or process supervision.
* **A JSON parser in AWK as the default** - more robust, but it makes every
  plain-text topic pay for a dependency it does not need.
* **`mawk` support** - the indirect call syntax and coprocess behaviour
  differ, and gawk is a one-line install on every target platform.
* **Polling `/proc` for child liveness** - needed a zombie check, a stop order
  and an interpretation of 143. Replaced by the single writer process above.
* **A clock inside AWK** - gawk has no timers, and a handler that waits blocks
  the whole stream: eight queued messages waited three seconds for a
  `sleep 0.1`. Replaced by a shell ticker writing into the fifo.
* **`mosquitto_pub` for the heartbeat** - it would publish outside the
  subscription filter and race the engine's own messages. A tick line in the
  same fifo keeps the order deterministic.

## The clock lives in the shell, not in AWK

Periodic work is possible two ways, and only one of them works.

A `systime()` timer inside the engine is free, needs no new parts, and was the
first idea. It is also not a timer. It is checked when a record arrives, so it
fires while the broker is busy and silently stops while the broker is quiet -
which is exactly when a heartbeat is worth having. Measured on gawk 5.1: a
handler that waits blocks every message behind it (eight queued messages all
arrived three seconds late after one three-second handler), and `sleep()` is not
even available in a stock build. AWK has no timers and no concurrency, so
nothing inside the router can fire while input is idle.

The clock therefore lives in `awk-red`, as a third writer on the fifo:

```
awk-red/tick/2026-10-03T11:22:33Z 1756899753
```

Shell, `date`, one `printf`. The engine needs no change at all: it is a message
on the same stream as any other, which means a scheduled rule is an ordinary
rule, is testable offline by putting the line in a recording, and shows up in
`-v` routing logs like everything else. The ISO-8601 timestamp in the topic and
the epoch seconds in the payload are the same instant in both forms a rule is
likely to want.

Two costs, both accepted deliberately:

* **EOF.** A second writer holds the fifo open, so gawk no longer sees EOF when
  `mosquitto_sub` disconnects. Supervision therefore cannot rely on the pipe
  closing, and the run now ends when *either* stage stops rather than when the
  reader does. Polling looked like the wrong tool for this - a child that exited
  without being reaped is a zombie that still answers `kill -0`, which is
  exactly how the first version of this passed a rejected login and then hung
  for ever with the ticker running. Liveness is therefore read from
  `/proc/<pid>/stat` (with a `kill -0` fallback), at the price of one small file
  read and up to half a second of shutdown latency. The alternatives were
  worse: a watchdog subshell cannot `wait` for a sibling, since `wait` only
  accepts children, and bash 5.1's `wait -n` swallows the exit status of the
  child it reports - which is the one thing needed to tell a deliberate stop
  from a dead subscription.
* **Feedback.** With `-t '#'` the router receives its own published messages.
  A rule that publishes to the topic it matches re-triggers itself once per
  interval, so `awk-red/tick/` is write-once by contract and heartbeat output
  goes to `awk-red/heartbeat/`. The contract is documented where the rule is
  written, in `examples/heartbeat.awk`.

Exit status follows from the same split: a subscription that failed on its own
is reported with its own status so systemd restarts the service, and only a
130/143 without that failure counts as a stop we asked for. A reader stopped
for that reason exits 143, which is why the subscription check runs first.

The interval is one number, off by default, because a clock nobody asked for is
a surprise in a router that is otherwise purely reactive.

## One heartbeat, not two

A cron-driven heartbeat was the original plan and is deliberately not what
awk-red ships. A heartbeat consumed by the router cannot report that the router
died - the check and the thing being checked are the same process - so for
scheduled automations cron adds nothing that the internal clock does not already
do, and it actively misleads: it keeps publishing every five minutes while
awk-red is down, so an external watcher sees a healthy pulse on a dead router.

Cron, or better a systemd timer, earns its place only for a different job:
telling something *outside* awk-red that the router is gone. That wants its own
topic, published by a unit that does not depend on awk-red, so the two signals
cannot be confused. It is not built, because nothing outside needs it yet.

Note that the `%` in a crontab line is a newline to cron, which is an argument
for a systemd timer over cron regardless.

## Roadmap

Roughly in order of value per effort:

* **Rate limiting / debounce** with `systime()`: at most one alarm per sensor
  per interval, independent of the state logic each rule writes today.
* **State persistence**: dump selected variables on `END`, reload in `BEGIN`,
  so a restart does not re-alarm on stale values.
* **A test runner**: replay a directory of recordings and diff against
  expected output, which turns `--input` into real regression tests.
* **A control topic** (`awk-red/cmd/#`): reload rules, report status or reset
  state without restarting the service.
* **Repeated rule directories**, so a shared library of rules can be combined
  with a local set; ordering already makes this well defined.
* **Observability**: per-topic counters and status reporting on
  `awk-red/status`.
* **External liveness**, if an outside system ever needs it: a systemd timer
  unit publishing on a topic of its own, `awk-red/external/heartbeat`, which
  never depends on awk-red being alive. Deliberately not a cron entry - cron
  treats `%` as a newline, and the escaping that requires is exactly the
  fragility a timer unit avoids.

## Versions

Developed and tested against gawk 5.1 and 5.3, mosquitto-clients 2.0,
coreutils `stdbuf`, and bash 5.1. The engine needs gawk >= 4.0 for indirect
calls and two-way coprocesses; the script needs bash >= 4.4 for `mapfile -d`.