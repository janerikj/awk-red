# Benchmarks

`bench/run.sh` compares awk-red's capacity with a raw MQTT round trip on the
same broker. It is deliberately separate from `test/`: this needs a real broker
(ideally on another host) and a real network, so it is not part of the no-network
suite.

```shell
bench/run.sh                                   # broker mqtt.example.invalid, N = 100 and 1000, 5 repeats
bench/run.sh -h mqtt.example -p 1883 -n 5000 -r 7
bench/run.sh --nodelay                         # disable Nagle on the mosquitto tools
```

Options: `-h/--host` (default `mqtt.example.invalid`; pass `-h` or set
`MQTT_HOST`), `-p/--port` (1883), `-u/--user`,
`-P/--pass`, `-n/--count "N N"`, `-r/--repeats`, `-q/--qos`, `--nodelay`,
`--sleep` (subscription settle time, default 0.8 s). Configuration follows
awk-red's precedence: command line > environment > `.env` > default, and any
`MQTT_*` exported in the environment wins over `.env`.

## What is measured

Four stages handle the exact same N messages. Each is reported as the span from
the first to the last message of a run, at the clock of the stage that sees it:

| stage | path | clock |
| --- | --- | --- |
| `broker` | `mosquitto_pub -l` -> broker -> `mosquitto_sub -C N` | `mosquitto_sub -F '%U'` (epoch, ns) |
| `subscriber` | same feed -> broker -> `mosquitto_sub` -> fifo -> engine | benchmark rule `date +%s.%N` on #1 and #N |
| `engine` | `awk-red -i recording.log`, no broker | benchmark rule, as above |
| `publisher` | `awk-red -i`, a rule `pub()`ing each message -> broker -> monitor | `mosquitto_sub -F '%U'` |

`span_s` is the median over the repeats, `best_s` the fastest run (the one
without a connection stall, see below). `ms/msg` and `msg/s` come from the
median. Two deltas are printed: **subscriber - broker** is what awk-red's MQTT
input path costs on top of a plain subscription, and **publisher - engine** is
what one `mosquitto_pub` process and connection per message costs on top of the
engine.

The engine cannot clock itself: gawk's `systime()` is whole seconds, so the two
awk-red stages use a benchmark rule (`rules/sub/count.awk`) that shells out
`date +%s.%N` twice, on message #1 and #N, and exits so the `--mqtt` run ends.
The fork cost is symmetric, so it largely cancels in the span. `%U`'s
nanosecond epoch does the same job for the two native-mosquitto stages.

## Reading the numbers

* **The `subscriber` and `engine` stages are the interesting ones for the
  engine.** Both are a few hundred microseconds per message; the MQTT input
  path (`subscriber - broker`) is close to zero relative to the broker, because
  `mosquitto_sub -> fifo -> gawk` adds little on top of the socket round trip.
* **`publisher` is dominated by process and connection setup, not by AWK.**
  `pub()` runs one `mosquitto_pub` per message, and each is a fresh TCP connect
  and MQTT session. The `broker` and `subscriber` stages use `mosquitto_pub -l`
  (one connection for the whole batch), so the comparison is deliberately
  between a batched feed and a per-message publish. This is the shape of
  awk-red's `pub()`, not an artefact of the benchmark.
* **Connection churn can add a ~1 s stall.** Rapid short-lived connections to
  the broker sometimes lose a packet and wait out the TCP RTO (Linux minimum
  1 s). It shows up as one large gap in a run, roughly 2-3 runs in 6 here, and
  it happens with a plain bash loop too - it is the network/broker, not gawk.
  `best_s` is the run that escaped it; the median absorbs most of it. A local
  broker (loopback) removes it.

## Caveats

* QoS 0 throughout; single connection for the `-l` feed.
* The remote broker puts network latency inside every number, which is the
  point - this measures the whole path, not gawk in isolation.
* `-i` replay compiles the rules once and reads a file, so the `engine` span is
  pure pipeline throughput with no socket. Startup is excluded by the #1/#N
  marks (and by the discarded warm-up run per stage).
* Generated files (payloads, recordings, per-run timings, warnings) land in
  `bench/tmp/`, which is git-ignored. Raw per-run `span wall` pairs are kept as
  `bench/tmp/<stage>.<N>`.
