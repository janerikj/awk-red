# Tests

```shell
./test/run.sh              # everything, a few seconds
./test/run.sh buffering    # only cases whose name contains "buffering"
```

No broker, no network, no dependencies beyond bash, coreutils and gawk - the
project's own. A run ends with `N passed, 0 failed`, or with `N passed, M
failed` and the failing case named.

## What is here

| File | Purpose |
| --- | --- |
| `run.sh` | the suite: replay, clock, failure paths, signals, buffering, HTTP |
| `fake-mosquitto-sub` | a stand-in subscriber whose behaviour comes from the environment |
| `rules/webhook.awk` | the rule the HTTP cases route through |
| `expected/messages.log.out` | golden output for the replay case |

`awk-red` reads `MOSQ_SUB` from the environment, which is what lets the suite
replace the subscriber. Nothing else about the run is faked: the real `awk-red`
binary, the real engine, the real example rules and a real fifo are all used.

## The fake subscriber

`MOSQ_SUB=test/fake-mosquitto-sub ./awk-red ...`, with one of:

| `FAKE_SUB_MODE` | Behaviour |
| --- | --- |
| `accept` | connect and stay silent (the default) |
| `deny` | refuse the connection and exit 5, like a rejected login |
| `die` | exit `FAKE_SUB_CODE` (default 1) straight away |
| `stream` | `FAKE_SUB_COUNT` messages, `FAKE_SUB_GAP` apart, then silence |
| `buffered` | the same messages, but block-buffered - see below |

Also `FAKE_SUB_TOPIC`, `FAKE_SUB_PAYLOAD`, `FAKE_SUB_COUNT`, `FAKE_SUB_GAP` and
`FAKE_SUB_CODE`.

Two of these deserve an explanation, because both were wrong the first time:

* **`buffered`** prints its messages from a gawk that then blocks on a fifo that
  nobody writes to. It looks like a leak, but gawk flushes its output before it
  reads a record, so a fake that prints and then blocks on *input* arrives
  immediately whether or not it is buffered. Blocking on a `getline` from a fifo
  is what exposes block buffering for real: the line only leaves the process
  because `awk-red` wrapped the subscriber in `stdbuf -oL`.
* **`FAKE_SUB_PAYLOAD`** exists because a payload that triggers no rule looks
  exactly like a broken run. `message 1` sent to a temperature rule correctly
  publishes nothing, and the case then reports "no output".

The fake keeps its connection open with one-second sleeps rather than one long
sleep, and kills its own children from a trap: a killed child inherits the fifo
descriptor, and a lingering sleep would keep the fifo open after the reader is
gone.

## HTTP

Five cases, all offline: `http is off by default`, `http requests become
MQTT-style lines and rules route them`, `http port already in use fails fast`,
`http with refused subscription exits 5 without hang` and `http listener stops
cleanly on SIGTERM`.

They are written the same way as the rest of the suite - no HTTP library, no
python:

* **`http_get`** is a bash function over `/dev/tcp`: open, `printf` a request,
  `head -c` the reply. It only reports success on `200 OK`, and it never runs
  two requests at once, because gawk's listener closes its listening socket
  while it is handling one.
* **Taking a port** starts a gawk that holds it. gawk's bind is lazy - opening
  `/inet/tcp/PORT/0/0` does nothing until the first `getline` - so a bare
  `BEGIN` that does that `getline` binds, listens and then blocks in `accept()`,
  which is exactly the hold we want. The same asymmetry drives the preflight in
  `awk-red`: on a taken port `getline` returns immediately with
  `ERRNO = "Address already in use"`, on a free one it blocks, and `timeout`
  tells them apart.
* **No hangs.** Every case that starts a run goes through `timeout`, so a
  listener that outlives its subscription is reported as exit 124 instead of
  stalling the suite.

## Leftovers are a failure

Every live case ends by checking that the process group it started is empty
(`assert_no_strays`). This is the check that found the clock leaking a
`sleep 1` on shutdown, and it is why the suite uses `set -m` and `pgrep -g`
against its own process group instead of matching process names - `pkill -f
mosquitto` in a test runner finds the runner.

## Signals

`SIGTERM` is sent to a backgrounded `awk-red`. `SIGINT` is not: children of a
non-interactive shell inherit it as ignored, so `kill -INT` on a background job
does nothing and the case would pass for the wrong reason. Ctrl-C is tested with
`timeout --signal=INT` in the foreground instead.

## Adding a case

Add a `case_*` function, then its name to the `cases` array at the bottom of
`run.sh`. Call `bad "why"` for a failure and `pass "$CASE"` at the end; the loop
counts the case once, and one failing assertion is enough.

Prefer a payload that makes a rule actually publish, and assert while the
process is still running when the property is about timing.
