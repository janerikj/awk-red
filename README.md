# awk-red ![Version](https://img.shields.io/badge/version-v0.2.0-red)

A Node-RED style event router built on MQTT, `mosquitto_sub` and AWK.

Node-RED is built on a handful of simple ideas:

1. subscribe to events (MQTT)
2. filter them
3. transform the data
4. decide something
5. call an external program or publish a new MQTT message

AWK's `pattern { action }` model covers exactly those steps: pattern matching
filters, the action body transforms and decides, and `system()` calls out to
other programs. awk-red is that idea implemented as two files - a shell script
that handles what AWK is bad at, and a small AWK engine that routes.

```
mosquitto_sub -v -t '#'
        |
        |  line buffered (stdbuf -oL)          HTTP clients (--http-port)
        |                                       |  one request per connection
        +-------------------+-------------------+
                            v
gawk -f lib/router.awk -f <rules>/*.awk     the engine
        |
        +--> pub()    -> mosquitto_pub    (new MQTT messages)
        +--> emit()   -> any command      (logger, ntfy, curl, scripts)
```

The engine never changes when automations are added. A rule is a new file in
a rule directory, and nothing else.

## Requirements

| Tool | Why | Install |
| --- | --- | --- |
| `bash` >= 4.4 | the entry point | ships everywhere |
| `gawk` >= 4.0 | indirect calls, two-way coprocesses | `sudo apt install gawk` |
| `mosquitto_sub` | the MQTT subscription | `sudo apt install mosquitto-clients` |
| `stdbuf`, `timeout` | line buffering and the HTTP preflight (coreutils) | usually already installed |
| `jq` | only for JSON payload adapters | `sudo apt install jq` |
| `ntfy` | only if a rule emits ntfy notifications | <https://github.com/dschep/ntfy> |

`mawk` is the default `awk` on Raspberry Pi OS and is **not** supported: awk-red
calls `gawk` explicitly.

## Quick start

```shell
git clone <this repo> && cd awk-red
cp .env.example .env                     # set MQTT_HOST at least
./awk-red -n -i examples/messages.log    # dry run against a recording
./awk-red -l                             # what handles what
./awk-red -r ./rules -h mqtt.local       # live, with your own rules
```

Try it against a real broker without writing a single rule:

```shell
# terminal 1
./awk-red -n -v
# terminal 2
mosquitto_pub -t home/kitchen/temp -m 33.5      # -> DRYRUN> ... alarm/temp/kitchen
mosquitto_pub -t home/door -m open
```

## Layout

```
awk-red              the application: .env, flags, dependencies, rule discovery,
                     line buffering, process supervision
lib/router.awk       the engine: dispatch table, side effects, adapters, logging
examples/            default rule directory (--rules), plus a recorded stream
docs/design.md       why it is built this way, and what was tried instead
.env.example         every configuration variable with its default
```

There is no fixed `rules/` directory in the repository. `--rules DIR` points
at any directory of `*.awk` files, which is what makes the examples and your
own rules the same thing:

```shell
./awk-red -r examples            # the bundled examples (default)
./awk-red -r ./rules             # a directory next to the script
./awk-red -r /etc/awk-red/rules  # a system-wide set of rules
```

## Configuration

Everything is configured through environment variables; the flags are
shortcuts for the most common ones. Copy `.env.example` to `.env` and edit -
it is sourced at start-up, so it may contain ordinary shell syntax, and it is
never committed.

| Variable | Default | Meaning |
| --- | --- | --- |
| `MQTT_HOST` | `localhost` | broker hostname (`-h`) |
| `MQTT_PORT` | `1883` | broker port (`-p`) |
| `MQTT_USER` / `MQTT_PASS` | empty | broker credentials, sent as `-u`/`-P` |
| `MQTT_TLS` | `0` | `1` enables TLS on both the subscription and `pub()` |
| `MQTT_CAFILE` | system CA bundle | CA bundle used when TLS is on |
| `MQTT_CLIENT_ID` | empty | client id, useful in broker logs |
| `MQTT_TOPIC` | `#` | subscription filter (`-t`) |
| `DRYRUN` | `0` | `1` prints commands instead of running them |
| `AWKRED_RULES` | `examples` | rule directory (`-r`) |
| `AWKRED_FIRST_MATCH` | `0` | stop after the first matching rule |
| `AWKRED_VERBOSE` | `0` | log routing decisions |
| `AWKRED_TICK` | `0` | clock interval in seconds, `0` is off (`--tick`) |
| `AWKRED_HTTP_PORT` | `0` | listen for HTTP webhooks on this port, `0` is off (`--http-port`) |
| `AWKRED_ENV` | `./.env` if present | env file to load (`-e`) |

> [!NOTE]
> **Precedence:** command line > environment > `.env` > built-in default.

A password reaches the broker clients as a command-line argument, so it is
visible in `ps` to other users on the machine. On a shared host, connect over
TLS or give the broker a dedicated user for this service. Keep `.env` at mode
`600`; it is sourced, and it is git-ignored.

Live mode executes actions. Use `--dry-run` whenever you are not sure.

## Options

```
-h, --host HOST     broker hostname
-p, --port PORT     broker port
-t, --topic FILTER  subscription filter (default '#')
-r, --rules DIR     rule directory, *.awk loaded in sorted order
-e, --env FILE      env file to load
-i, --input FILE    read messages from FILE ('-' = stdin) instead of MQTT
    --tick SECONDS  clock message on awk-red/tick/<timestamp> every SECONDS
-P, --http-port [PORT]  serve HTTP webhooks on PORT (default 8080 if given
                    without a value; off unless set)
-n, --dry-run       print commands instead of running them
-l, --list-rules    list the loaded rules and exit
-v, --verbose       log routing decisions to stderr
-q, --quiet         only report errors
    --first-match   stop after the first matching rule
-?, --help          show help
    --version       show version
```

Exit codes: `0` success, `1` dependency or runtime error, `2` usage error.

Short options take their value as a separate argument (`-i file`), long options
also accept `--name=value`.

Rule files are loaded in sorted order, and that order is the order rules are
tried in, so it is stable regardless of locale. All matching rules run unless
`--first-match` is set.

## Writing a rule

A rule file registers a topic pattern and implements the handler the engine
calls. That is the whole contract:

```awk
# rules/lights.awk
BEGIN {
    reg("^home/door$", "door_handler", "turn the light on when the door opens")
}

function door_handler(topic, payload) {
    if (payload == "open")
        pub("home/lights/kitchen", "on")
}
```

The handler gets `topic` and `payload` as arguments, not as `$1` and `$2`, so
a payload containing spaces survives intact. AWK arrays are global and keep
state between messages, which is how you get "alert once, not ten times a
minute" or "only on a state change".

### Engine API

| Call | Does |
| --- | --- |
| `reg(pattern, handler, description)` | register a rule; called from `BEGIN` |
| `adapter(pattern, jq_filter)` | normalise a JSON payload before rules see it |
| `pub(topic, payload)` | publish an MQTT message, using the configured broker |
| `pub_retained(topic, payload)` | the same, with the retained flag |
| `emit(command)` | run any command, subject to `--dry-run` |
| `shquote(string)` | quote a value for use in `emit()` |
| `debug(msg)` | log when `--verbose` is set |
| `warn(msg)` / `error(msg)` | diagnostics on stderr |
| `getenv(name, default)` | read configuration |

Every side effect goes through `emit()`, so `--dry-run` covers the whole
system: commands are printed, not executed.

```shell
./awk-red -n -i examples/messages.log
```

```plain
DRYRUN> mosquitto_pub -h 'localhost' -p '1883' -t 'alarm/temp/kitchen' -m 'hot: 31.2C in kitchen'
```

Rules never hardcode a hostname, port or credential. If you need a command
that is not MQTT, build it with `shquote()` so values with spaces stay one
argument:

```awk
# send a notification via ntfy (topic can vary per rule)
emit("ntfy publish alerts " shquote("Door opened"))

# or trigger a webhook
emit("curl -fsS " shquote("https://example.org/hook?msg=" url))
```

## Payload formats

Topics do not all speak the same language. Rather than forcing everything into
one serialisation, the engine hides the difference behind per-topic adapters.
A rule sees plain text either way:

```awk
BEGIN {
    adapter("^home/sensor/json$", ".temperature")   # JSON in
    reg("^home/sensor/json$", "json_handler", "alarm from a JSON sensor")
}

function json_handler(topic, payload) {            # plain text out
    if (payload + 0 > 30)
        pub("alarm/sensor", "hot: " payload)
}
```

`examples/json.awk` is this file in full, and `examples/temp.awk` is the same
automation for a plain-text topic - the handler code is identical.

An adapter must yield exactly one line per message. Extra lines are dropped;
a filter that yields nothing will desync that adapter, so keep it to a single
value. If a topic carries deeply nested JSON with varying schemas, parse it in
AWK instead - see `docs/design.md`.

## HTTP webhooks

Rules can be driven over plain HTTP as well as MQTT. It is off unless asked
for: `--http-port PORT` or `AWKRED_HTTP_PORT`, where `-P` on its own means
8080. The listener binds all interfaces (there is no host option), so treat it
like any other port you expose and firewall it accordingly.

A request becomes one line of engine input, exactly as a broker would deliver
it:

```text
POST /door/front?p=open        ->  post/door/front open
GET  /temp?p=21.5%20C          ->  get/temp 21.5 C
POST /sensor   {"t":21}        ->  post/sensor {"t":21}
```

* The topic is the lowercased method plus the path with leading slashes
  stripped, so `/Door/Front` and `GET` give `get/door/front`.
* The payload is `p=` or `payload=` from the query string, urldecoded. If
  neither is present, the request body is used as a single line; a multi-line
  body is truncated at the first line.
* Every other query parameter is ignored.
* One request per connection. It is answered `200 OK` or `400 Bad Request` and
  the connection is closed.

awk-red checks the port before it starts anything, so a webhook port that is
already taken fails immediately with a clear message rather than starting a
run that can never answer.

```awk
# rules/webhook.awk
BEGIN { reg("^get/hook/", "hook_handler", "manual trigger") }
function hook_handler(topic, payload) { emit("echo got " shquote(payload)) }
```

gawk's `/inet/tcp` is not a web server: it accepts one connection at a time
and closes the listening socket while the request is being handled, so a
connection arriving in that window is refused by the kernel. Send webhooks one
at a time and retry on `Connection refused`; see *Limitations*.

## Buffering between stages

If rules load but nothing seems to happen, and output arrives in bursts, the
cause is almost always libc block buffering: a process writing to a pipe
buffers 4-8 KB at a time, while the same process on a terminal writes line by
line. Manual testing then always looks fine while pipes and systemd stand
still.

awk-red line-buffers both stages:

```shell
stdbuf -oL mosquitto_sub -h "$MQTT_HOST" -p "$MQTT_PORT" -v -t "$MQTT_TOPIC" > "$fifo" &
stdbuf -oL gawk -f lib/router.awk -f rules/*.awk < "$fifo" &
```

`stdbuf` works through libc stdio and is enough for mosquitto_sub and gawk.
Programs that do their own buffering need their own flag - `jq --unbuffered`,
which awk-red passes to its adapters. As a second line of defence the engine
also calls `fflush()` after every message.

Diagnose which stage is buffering:

```shell
mosquitto_sub -v -t '#' | cat                                    # do lines appear at once?
stdbuf -oL mosquitto_sub -v -t '#' | awk '{print; fflush("")}'   # and now?
```

`fflush()` inside AWK only affects AWK's own stdout. If mosquitto_sub is the
one buffering, the fix has to be on the reading side of the pipe, which is
what `stdbuf -oL` does.

## Replaying a recorded stream

`--input` replaces the broker with a file, which makes rules testable and
reproducible:

```shell
./awk-red -n -v -i examples/messages.log      # what would happen
./awk-red -v -i examples/messages.log         # what does happen
mosquitto_sub -v -t '#' | tee recording.log   # record a real stream
./awk-red -n -i recording.log                 # replay it
```

A recording is exactly what `mosquitto_sub -v` prints: `topic payload`, one
line per message. Two caveats: a payload that itself contains newlines
arrives as several lines, and a multi-line payload cannot be replayed
faithfully without extra framing.

## Scheduled work

Rules normally react to broker traffic, which means they cannot fire while the
broker is quiet. `--tick SECONDS` adds a clock for that case:

```shell
./awk-red --tick 300 -r ~/rules       # every five minutes
```

The script then publishes

```
awk-red/tick/2026-10-03T11:22:33Z 1756899753
```

on the same input stream as everything else: topic, ISO-8601 UTC timestamp,
payload with the epoch seconds. A rule is an ordinary rule that matches the
topic, so periodic work - pruning old state, polling something slow, publishing
a summary - is a `reg()` and a function like any other, and
`examples/heartbeat.awk` is a working one.

The clock lives in the shell, not in AWK. gawk has no timers and no
concurrency: nothing inside the router can fire while input is idle, and a
handler that waits blocks every other message behind it.

Two consequences worth knowing:

* the tick is a third writer on the fifo, so gawk no longer sees EOF when
  `mosquitto_sub` disconnects. The run therefore ends when either stage stops,
  and a subscription that fails on its own exits with its status, so systemd
  restarts the service instead of leaving a router that is subscribed to
  nothing
* never publish to `^awk-red/tick/` from a rule. With the default subscription
  the router receives its own messages back, so such a rule re-triggers itself
  once per interval, forever. Publishing elsewhere, as `heartbeat.awk` does,
  closes the loop exactly once

A tick says nothing about awk-red itself - a heartbeat consumed by the router
cannot report that the router died. If something outside needs to detect that,
publish a separate topic from a systemd timer rather than reusing this one,
otherwise the pulse keeps coming from a router that is gone.

`--tick` cannot be combined with `--input`: a recording has a fixed timeline,
so put the line in the file instead.

```shell
echo 'awk-red/tick/2026-10-03T11:22:33Z 1756899753' | ./awk-red -n -q -i -
```

## Running as a service

`examples/awk-red.service` is a systemd unit. The points that matter:

* use `Restart=always` and `RestartSec=5`
* pass `-r /etc/awk-red/rules` explicitly instead of relying on the default
* keep `-v` out of it and use `-q`, so the journal holds errors instead of one
  line per message
* `Type=simple`, since the script runs in the foreground
* `--tick` only if the rules need it, so `AWKRED_TICK=0` stays the default and
  an installation with no scheduled work behaves exactly like the examples

```shell
sudo install -m755 awk-red /usr/local/bin/awk-red
sudo install -d /etc/awk-red/rules
sudo cp examples/*.awk /etc/awk-red/rules/
sudo install -m644 .env /etc/awk-red/.env
sudo cp examples/awk-red.service /etc/systemd/system/
sudo systemctl enable --now awk-red
```

Keep credentials in `/etc/awk-red/.env` with mode `600`, and pass the file
with `-e /etc/awk-red/.env`. Do not commit it.

## Troubleshooting

**No output at all.** Check the subscription and the rules:

```shell
./awk-red -l                      # are any rules loaded?
./awk-red -v -t 'home/#'          # does anything match the topic filter?
mosquitto_sub -v -t 'home/#'      # is anything published at all?
```

**Rules load but nothing fires.** Add `-v`: every message is logged with the
handler it routed to, or `no rule matched <topic>`. An adapter that failed
also warns and passes the raw payload through.

**Actions do not happen.** Live mode is the default. Either you are running
without `--dry-run` and the commands fail - the exit status of `system()` is
logged with `-v` - or you are running with `--dry-run`, in which case the
`DRYRUN>` lines are the expected output.

**A rule throws a gawk error.** awk-red stops; that is deliberate, a broken
rule should not silently swallow the stream. Run it against a recording to
reproduce: `./awk-red -n -i examples/messages.log`.

## Tests

```shell
./test/run.sh              # everything
./test/run.sh buffering    # only cases whose name contains "buffering"
```

No broker, no network and no extra dependencies: `test/fake-mosquitto-sub`
stands in for `mosquitto_sub` and produces the failure paths on demand, which
is where most of the bugs lived - a refused subscription, one that dies, one
that delivers nothing, one that block-buffers. A run takes a few seconds and
ends with `N passed, 0 failed`.

## Design notes

`docs/design.md` covers why the split between shell and AWK looks the way it
does, the alternatives that were rejected, and what is worth building next.

## Limitations

* One message per line, no multi-line payloads (see *Replaying*).
* Rules are trusted code, and `.env` is sourced, not parsed. Anyone who can
  write a rule file can run commands.
* Delays belong in the command you `emit()`, not in the router; a sleeping
  handler stalls every other rule. Scheduled work comes from `--tick` instead.
* A tick is one message per interval, not a general timer wheel: there is one
  interval, and it is the same for every rule.
* HTTP webhooks are served one connection at a time. gawk closes the listening
  socket while it handles a request, so concurrent requests get `Connection
  refused` - retry, or space them out. A client that connects and never sends a
  request is dropped after 1.5 s.
* This is not Node-RED. It is comfortable up to roughly a hundred
  automations, not for flows with hundreds of branches.

## License

MIT, see [LICENSE](LICENSE).
