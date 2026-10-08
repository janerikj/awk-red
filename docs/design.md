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
| check that `gawk` and `stdbuf` exist (`mosquitto_sub` only with `--mqtt`) | shell | `command -v`, and a good error message |
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

Rules never call `system()` or `mosquitto_pub` directly. They call `emit()` or
`pub()`, and the engine decides what that means. Three things
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
  |- mosquitto_sub     the subscription, only with --mqtt
  |- tick_loop         the clock, when --tick is on
  |- http_loop         the HTTP listener, when --http-port is on

gawk -f lib/router.awk ... < "$fifo"          the engine
```

`write_loop` runs as a subshell with the fifo as its stdout, so starting the
subscriber and the clock are ordinary child starts and `wait`ing for a child
is legal - it is this process's own child, not a sibling. That one
rule is what the fifo bought:

* **With `--mqtt`, the run ends with the subscription.** A refused login, a
  broker that went away or a plain disconnect ends the `wait`, the writer
  closes the fifo, and the engine sees end of input and exits by itself.
* **The writer's status is mosquitto_sub's status**, so a rejected login
  arrives as exit 5 instead of as a silent success - named on stderr as
  `mosquitto_sub exited with status 5`.
* **The clock cannot outlive the subscription**, because the writer is its
  parent and kills it on the way out.

Without `--mqtt` there is no terminator to wait on, so `write_loop` waits on
whichever sources exist with `wait -n` instead: the first one to finish is
identified with `kill -0` (it was just reaped, so only the survivors still
answer) and its status is reported under its own name - `http listener exited
with status 137`, `clock exited with status N`. The signal-only lifetime that
follows from that is described under *Inputs are opt-in* below.

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

One writer process makes all three questions unnecessary. `wait -n` turned out
to be enough after all: it returns the status of *a* finished child, and
because it has already reaped that child, a `kill -0` pass separates the dead
one (no such process any more) from the survivors (still answer). That gives
both the status and the identity without polling anything. Polling also cost up
to half a second of shutdown latency; with the writer, a dead subscription ends
the run in roughly 30 ms.

## HTTP on the same fifo

`--http-port` puts another writer in `write_loop`. It had to live there: with
`--mqtt`, the run ends with the subscription, and if the listener kept the fifo
open after that, the engine would never see end of input and awk-red would hang
on its final `wait`. So `http_loop` is started only when the port is on and is
added to the `TERM`/`INT` trap alongside the other children.

`http_loop` also propagates what it waits on: the listener's exit status
becomes the subshell's status, which `write_loop` reports under its own name
(`http listener exited with status N`). Without that, a listener that crashed
on start-up or was killed mid-run would leave a run that looks healthy while
answering nothing - the exact failure the preflight only covers for the
"port taken" case. With `--http-port` as the *only* input, that status is the
whole story of the run, which is what makes an http-only mode viable.

Everything else about it is gawk's `/inet/tcp`, which is not a web server:

* **The bind is lazy.** Opening `/inet/tcp/PORT/0/0` does nothing; the real
  `socket`/`bind`/`listen` happen on the first `getline`. A taken port is
  therefore reported as `ERRNO = "Address already in use"` from `getline`, not
  from the open, and it fails immediately while a free one blocks in `accept()`.
  That asymmetry is what the preflight relies on: run the same probe under
  `timeout`, and "exited 1" means the port is taken while "still running when
  timeout killed it" means it was free. No second dependency, and no bind test
  that only ever checks loopback. gawk's own bind failure at run time is fatal
  for the same reason - without it, a failed `close`/reopen would spin.
* **`listen(fd, 1)` and one connection at a time.** gawk closes the listening
  socket as soon as it has accepted, and reopens it only after the response is
  written and the connection closed. Anything that arrives while a request is
  in flight gets an RST from the kernel: `ECONNREFUSED`, not a queue. The
  practical contract is therefore "one request at a time, retry on refusal",
  which is written down rather than papered over, because no amount of code
  here changes what gawk does with the fd.
* **`PROCINFO[service, "READ_TIMEOUT"]` only covers the read.** It drops a
  client that connects and never finishes a request line after 1.5 s - the
  listener comes back - but there is no timeout on `accept()`, so an idle port
  simply blocks, which is exactly what we want.

The preflight has a deliberate gap: it proves the port was free a moment
before the run starts, and someone could take it in between. The fatal bind
message in `lib/http.awk` covers that window, so the worst case is a run that
says why it has no listener, not one that silently never listens.

One limit is worth naming because its obvious fix is not in the code. The
request cannot choose the topic it becomes: the topic is always `method/path`,
and of the query string only `p=`, `payload=` and `msg=` survive - every other
key is dropped before a rule ever sees it. The payload aliases are held to that
short list on purpose, one added only when a real sender hardcodes it, so the
contract stays small enough to hold in your head. Reshaping the topic itself is
left to the rule, with `sub()`, which is why there is no helper for it. If a
webhook source should publish under a name of its own, the natural extension is
a reserved `topic=` key the listener uses verbatim, keeping the derivation as
the default. It is not built because no source has needed it yet and because it
widens the contract further - once a request can name its own topic, `reg()`
patterns have to assume topics that do not come from a URL.

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

One shutdown artefact is filtered out rather than explained: a source that
dies of `SIGPIPE` (exit 141) can only do so because the fifo's reader, the
engine, is gone - with the engine alive there is always someone to read. That
is the engine's story, not the source's failure, so `write_loop` drops a 141
instead of reporting it as a dead input. Without that rule the engine's own
shutdown would race the clock and report `clock exited with status 141`.

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

Four traps the tests had to avoid, each of which cost time:

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
* **A developer's `.env` reaches every case.** Since inputs are opt-in, an
  `AWKRED_MQTT=1` (or `--mqtt` baked into a shell alias) in the environment
  would quietly subscribe in cases that exist to prove no subscription happens.
  The suite pins `AWKRED_MQTT=0`, `AWKRED_TICK=0` and `AWKRED_HTTP_PORT=0`
  before running anything, so each case names its own inputs and only its own.

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

The clock therefore lives in `awk-red`, as another writer on the fifo:

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
  closing: with `--mqtt` the writer waits on the subscription and stops the
  other sources when it returns, and without it the writer waits on the
  sources themselves with `wait -n`, reaping the first one to finish and
  naming it. Polling looked like the wrong tool for this - a child that exited
  without being reaped is a zombie that still answers `kill -0`, which is
  exactly how the first version of this passed a rejected login and then hung
  for ever with the ticker running. `wait -n` is the fix precisely because it
  *reaps*: once the finished child is gone, `kill -0` sorts the dead one from
  the survivors without reading `/proc` or timing anything.
* **Feedback.** With `-t '#'` the router receives its own published messages.
  A rule that publishes to the topic it matches re-triggers itself once per
  interval, so `awk-red/tick/` is write-once by contract and heartbeat output
  goes to `awk-red/heartbeat/`. The contract is documented where the rule is
  written, in `examples/heartbeat.awk`.

Exit status follows from the same split: a source that failed on its own is
reported with its own status under its own name so systemd restarts the
service, and only a 130/143 without such a failure counts as a stop we asked
for. A source stopped for that reason exits 143, which is why the failure check
runs first.

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

## Inputs are opt-in (built in v0.3.0)

Until v0.3.0 a run always subscribed: `--http-port` and `--tick` still needed
a broker, and `mosquitto_sub` was an unconditional dependency. That made a
webhook-only or clock-only router impossible, and worse, it made the *default*
run a live subscription that nobody had asked for. `--input` already gave a
broker-free mode, but only for a recording.

Inputs are now a set, each one asked for separately:

```
--mqtt        AWKRED_MQTT       the broker subscription
--http-port   AWKRED_HTTP_PORT  HTTP webhooks
--tick        AWKRED_TICK       the clock
-i FILE                       a recording (exclusive with the rest)
```

At least one is required, otherwise it is a usage error (exit 2) - a run with
nothing to read would sit in its final `wait` forever, so refusing it outright
is the only honest option. `--input` is exclusive with every live input for the
same reason: a recording is already a complete stream, so `--mqtt`, `--http-port`
and `--tick` are all rejected when it is given.

The selection mechanism is a flag plus a truthy environment variable, default
off. The alternatives were weighed before building:

| Option | Effect |
| --- | --- |
| `--no-mqtt` / `AWKRED_MQTT=0`, MQTT on by default | Non-breaking, but keeps the surprise: a bare `./awk-red` is a live subscription. |
| `--mqtt` / `AWKRED_MQTT=1`, defaulting off (chosen) | "Turn MQTT on explicitly"; flips the default, which is fine while v0 has no users to migrate. |
| `--input`-style selector over `mqtt`, `http`, `tick` | Clearest mental model, at the cost of the largest surface - and sources combine (`--mqtt --tick`) anyway, so it would be a set of booleans with more syntax. |

What actually had to change was the lifetime model, not the flags:

* **The subscription stopped being the terminator.** With `--mqtt` it still
  is: `write_loop` waits on `mosquitto_sub`, and a refused login ends the run
  with status 5, exactly as before. Without it the writer waits on whichever
  sources exist with `wait -n` and stops the survivors when the first one
  ends. With no source failing at all the lifetime is signal-only: the run
  ends on `SIGTERM`/`SIGINT`, which is what systemd sends anyway.
* **A dead input is fatal and named.** `http_loop` used to swallow the
  listener's status (`wait "$sleeper" || true`); it propagates it now, and
  `write_loop` reports the source under its own name - `mosquitto_sub exited
  with status N` was simply wrong when the HTTP listener was the one that
  died.
* **No broker tooling required.** `mosquitto_sub` is checked (and the banner
  prints a broker line) only when MQTT input is on, mirroring the `--input`
  exemption. The `mosquitto_pub` warning still appears when `pub()` has no
  client, because that is about *outgoing* messages in any mode - and
  `MQTT_HOST`/`MQTT_PORT` configure `pub()` whether or not the input is on,
  which is why setting them alone never switches anything.

## Other input sources

The engine does not know what an input *is*. It reads lines and splits each one
at the first space: everything before is the topic, everything after is the
payload. `mosquitto_sub`, `tick_loop` and `http_loop` are three different
programs that all happen to write that one format to the fifo, so "add a new
input" almost never means touching the engine - it means writing one more bridge
to the same wire.

What it *does* mean is a change in `write_loop`, and that change is now made:
v0.3.0 turned a run into a *set* of input sources, each started, stopped and
status-reported on its own, with the lifetime decisions from *Inputs are
opt-in* (signal-only lifetime when nothing fails, a dead input fatal and
named). The remaining work for a new source is therefore the easy half: start
it in `write_loop` when its flag is set, kill it from the trap, and let the
existing `wait -n` reporting pick it up.

The cheapest source is not a new listener but a new command. `mosquitto_sub` is
already "just a process that prints lines", so the live counterpart of
`--input FILE` is a supervised `--pipe CMD`, with an optional `--every N`, whose
stdout is treated exactly like a subscription's. Most of the table below then
becomes a recipe in the documentation rather than a parser in the repository:

```shell
# journald -> host/<unit>
journalctl -f -o cat -n 0
# a serial sensor
stty -F /dev/ttyUSB0 9600 raw -echo; cat /dev/ttyUSB0
# a feed
curl -fsS https://example.org/feed.xml | some-line-formatter
```

`--changed` (emit only when the command's output differs from the last run) is
the edge detector that turns a poll into an event without new state in the
engine.

### Candidate sources

Roughly by fit and effort:

| Source | Shape | Notes |
| --- | --- | --- |
| `--pipe` / `--exec [--every] [--changed]` | any command's stdout | The general case: serial, journald, RSS, redis, sensors. Live counterpart of `--input`. |
| `--udp-port` | datagrams to `udp/<...> <payload>` | Reuses the gawk `/inet` code `http.awk` is built on: syslog, StatsD, `nc -u`, `echo > /dev/udp`, small IoT devices. Spike first - gawk's UDP is more limited than its TCP (no `READ_TIMEOUT`; "receive from any sender" is not obviously supported). |
| `--watch PATH` | `inotifywait`, polling fallback | Drop-folder, "backup finished", a rules-reload trigger. |
| `--follow FILE[:topic]` | `tail -F` lines | Sends a log to rules without a broker. |
| `--tcp-port` | `topic payload` per line | HTTP's smaller sibling, for scripts that dislike HTTP framing. |
| `--serial DEV:BAUD` | `stty` + `cat` | Arduino/ESP; also expressible as `--pipe`. |
| GPIO / `/dev/input` / MIDI | `gpiomon`, `evtest` | Button, motion, "big red button" - all `--pipe` recipes. |
| host telemetry | `/proc`, `/sys`, `sensors`, `smartctl` | A specialised `--exec`: load, memory, disk, temperature. |

Deliberately not built into the core:

* **RSS/Atom, IMAP, weather and other HTTP APIs.** These are pull, not push:
  they have to poll, they need "what is new" state that awk-red does not persist
  yet, and XML or IMAP parsing drags in a dependency that is easy to get wrong
  on real-world feeds (namespaces, CDATA, entities, encodings). They are
  `--pipe` recipes, or better, external producers that publish to MQTT or to the
  HTTP listener.
* **WebSocket, Kafka, AMQP, Slack/Matrix/IRC.** Each needs auth, TLS and a
  protocol client; none belongs in a script whose only network dependencies are
  `gawk` and `mosquitto_sub`.

### Three questions that recur

* **Dedup / last seen.** A poll has no idea what changed; `--changed` and a
  persisted state file (Roadmap) are the same answer.
* **Lifetime.** A source that goes quiet is not a source that died - which is
  exactly the "a dead input is fatal and named" rule that *Inputs are opt-in*
  put in `write_loop`.
* **Ordering.** All writers share one fifo, so messages from different sources
  interleave, but each line is written atomically (below `PIPE_BUF`), so a line
  is never torn. That is the property that lets a source be a plain `printf`.

## Roadmap

Roughly in order of value per effort:

* **A `topic=` override for webhooks.** Let a request name the engine topic
  instead of deriving it from the method and path; see *HTTP on the same fifo*.
* **A generic `--pipe` / `--exec` input.** The live counterpart of `--input`:
  run a command and treat its lines as a subscription, optionally `--every` and
  `--changed`. Unlocks serial, journald and RSS as recipes rather than code; see
  *Other input sources*.
* **A `--watch` / `--follow` input.** File and directory changes, and `tail -F`
  of a log, as topics; `inotifywait` when present, polling otherwise.
* **A UDP listener** (`--udp-port`) beside the HTTP one, for syslog, StatsD and
  one-line senders.
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