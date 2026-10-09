#!/usr/bin/env bash
# test/run.sh - regression tests for awk-red.
#
#   ./test/run.sh            run everything
#   ./test/run.sh deny       run only the cases whose name matches "deny"
#
# No test framework and no dependencies beyond bash, coreutils and awk-red
# itself: the subscriber is replaced by test/fake-mosquitto-sub, so a refusal, a
# crash or a silent broker can be produced on demand. Every case here exists
# because something once went wrong - the supervision cases are regression tests
# for a hang that only appeared with the clock enabled, and the buffering case
# fails if the stdbuf wiring is removed.

set -u
# Monitor mode gives every background job its own process group, so a run's pid
# is also its group id and every process it leaves behind stays in that group.
# That is how the strays are found: by group, never by matching a command line.
# Matching a name is how this harness first reported a leftover subscriber that
# was the shell running the tests.
set -m

cd "$(dirname "$0")/.." || exit 1

export MOSQ_SUB="$PWD/test/fake-mosquitto-sub"
# Inputs are opt-in and each case names the ones it wants: a developer's .env
# must not switch one on (or off) behind the suite's back.
export AWKRED_MQTT=0 AWKRED_TICK=0 AWKRED_HTTP_PORT=0
# The rate-limit test seam, pinned like the inputs: a value in a developer's
# .env must not move a window behind the suite's back.
export AWKRED_TEST_STEP=0
AWKRED="$PWD/awk-red"
FILTER=${1:-${FILTER:-}}   # ./test/run.sh [case-substring]
CASE=""

WORK=$(mktemp -d) || exit 1
OUT="$WORK/out"
ERR="$WORK/err"
# Scoped so the fifo check below cannot see a fifo belonging to something else.
export TMPDIR="$WORK/tmp"
mkdir -p "$TMPDIR" || exit 1
passed=0
failed=0
declare -a strays=()

cleanup() {
    local pid
    for pid in "${strays[@]:-}"; do
        [[ -n $pid ]] && kill -KILL -- "-$pid" 2>/dev/null
    done
    rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

# ------------------------------------------------------------------ helpers

pass() {
    [[ -z ${CASE_FAILED:-} ]] || return 0
    printf '  ok    %s\n' "$1"
    passed=$(( passed + 1 ))
}

# bad reports why a case failed and marks it, so a case can continue to the end
# and still be counted as failed. Without the flag a case that printed a
# complaint and then carried on was counted as a pass.
bad() {
    printf '        %s\n' "$*" >&2
    CASE_FAILED=1
    return 1
}

# A live run must not leave anything behind. Two checks, neither of which can
# match the harness itself: no process left in the run's process group, and no
# fifo left in the per-run TMPDIR.
assert_no_strays() {
    local found
    if [[ -n ${RUN_PID:-} ]] && found=$(pgrep -a -g "$RUN_PID" 2>/dev/null); then
        printf '        leftover in group %s: %s\n' "$RUN_PID" "${found//$'\n'/ }" >&2
        kill -KILL -- "-$RUN_PID" 2>/dev/null
        CASE_FAILED=1
        return 1
    fi
    if compgen -G "$TMPDIR/awk-red.??????" >/dev/null 2>&1; then
        printf '        leftover fifo: %s\n' "$TMPDIR"/awk-red.* >&2
        CASE_FAILED=1
        return 1
    fi
    return 0
}

# Start awk-red in the background, keeping the pid so a case can signal it
# directly instead of hunting for it.
RUN_PID=""
start_awkred() {
    "$AWKRED" "$@" >"$OUT" 2>"$ERR" &
    RUN_PID=$!
    strays+=("$RUN_PID")
}

signal_awkred() {
    kill -"$1" "$RUN_PID" 2>/dev/null || true
}

# Signal it, then wait for it and hand back the exit status.
finish_awkred() {
    signal_awkred "${1:-TERM}"
    local i
    for (( i = 0; i < 40; i++ )); do
        kill -0 "$RUN_PID" 2>/dev/null || break
        sleep 0.1
    done
    wait "$RUN_PID"
}

# Wait for a run that should end on its own - a failed source closes the fifo
# and the engine exits - and hand back the exit status. If it does not end, it
# is a hang: report it, kill it, and let the case still check its output.
wait_awkred() {
    local i
    for (( i = 0; i < 50; i++ )); do
        kill -0 "$RUN_PID" 2>/dev/null || break
        sleep 0.1
    done
    if kill -0 "$RUN_PID" 2>/dev/null; then
        bad "still running after 5 s" || true
        kill -TERM "$RUN_PID" 2>/dev/null || true
    fi
    wait "$RUN_PID"
}



# Simple HTTP client using /dev/tcp; returns 1 on failure. gawk's listener
# refuses a connection while it is handling the previous one, so the client
# retries a few times - the same "retry on Connection refused" the README
# documents for real senders.
http_get() {
    local port=$1
    local path=$2
    local resp rc=1 attempt
    for attempt in 1 2 3 4; do
        resp=""
        # The 2>/dev/null lives on the brace group, not on exec: a redirection
        # on exec itself would permanently point the suite's stderr at
        # /dev/null, and every later failure message would silently vanish.
        if { exec 3<>/dev/tcp/127.0.0.1/"$port"; } 2>/dev/null; then
            printf 'GET %s HTTP/1.1\r\nHost: test\r\nConnection: close\r\n\r\n' "$path" >&3
            resp=$(timeout 5 head -c 4096 <&3 2>/dev/null || true)
            exec 3<&- 3>&-
            printf '%s' "$resp" >"$WORK/httpresp"
            if [[ $resp == *"200 OK"* ]]; then
                rc=0
                break
            fi
        fi
        sleep 0.2
    done
    return $rc
}

# -------------------------------------------------------------------- cases

case_replay_golden() {
    CASE="replay against a recording matches the golden output"
    local rc
    "$AWKRED" -n -q -i examples/messages.log >"$OUT" 2>"$ERR"
    rc=$?
    (( rc == 0 )) || bad "exit $rc, stderr: $(cat "$ERR")"
    diff -u test/expected/messages.log.out "$OUT" >"$ERR" || bad "$(cat "$ERR")"
    assert_no_strays
    pass "$CASE"
}

case_tick_offline() {
    CASE="a tick line in a recording routes to the heartbeat rule"
    local rc
    echo 'awk-red/tick/2026-10-03T11:22:33Z 1756899753' \
        | "$AWKRED" -n -q -i - >"$OUT" 2>"$ERR"
    rc=$?
    (( rc == 0 )) || bad "exit $rc, stderr: $(cat "$ERR")"
    grep -qF -- "-t 'awk-red/heartbeat/2026-10-03T11:22:33Z' -m '1756899753'" "$OUT" \
        || bad "no heartbeat published, got: $(cat "$OUT")"
    pass "$CASE"
}

case_tick_off_by_default() {
    CASE="the clock is off unless asked for"
    local banner
    banner=$("$AWKRED" -n -i examples/messages.log 2>&1 >/dev/null)
    [[ $banner != *"clock"* ]] || bad "the banner mentions a clock without --tick"
    grep -qF '^awk-red/tick/' "$OUT" 2>/dev/null && bad "ticks appeared without --tick"
    pass "$CASE"
}

case_tick_on_silent_broker() {
    CASE="ticks arrive while the broker sends nothing"
    local rc
    start_awkred -n -v --tick 1 --mqtt -h test.invalid
    sleep 3.2
    finish_awkred TERM
    rc=$?
    (( rc == 0 )) || bad "exit $rc, stderr: $(cat "$ERR")"
    local ticks
    ticks=$(grep -c '^DRYRUN> ' "$OUT")
    (( ticks >= 2 )) || bad "only $ticks ticks in 3 s"
    grep -qF 'route awk-red/tick/' "$ERR" || bad "the engine did not route the tick as a message"
    assert_no_strays
    pass "$CASE"
}

case_deny_no_tick() {
    CASE="a refused subscription exits 5 without a clock"
    local rc
    FAKE_SUB_MODE=deny timeout 15 "$AWKRED" -n --mqtt -h test.invalid >"$OUT" 2>"$ERR"
    rc=$?
    (( rc == 5 )) || bad "exit $rc (124 means it hung), stderr: $(cat "$ERR")"
    grep -qF 'mosquitto_sub exited with status 5' "$ERR" || bad "stderr explains nothing: $(cat "$ERR")"
    assert_no_strays
    pass "$CASE"
}

# The regression this suite exists for. With a third writer on the fifo gawk no
# longer sees EOF, and a version of the supervision code that waited only for the
# reader hung here for ever instead of exiting.
case_deny_with_tick() {
    CASE="a refused subscription exits 5 with a clock (regression)"
    local rc
    FAKE_SUB_MODE=deny timeout 15 "$AWKRED" -n --mqtt -h test.invalid --tick 1 >"$OUT" 2>"$ERR"
    rc=$?
    (( rc == 5 )) || bad "exit $rc (124 means it hung), stderr: $(cat "$ERR")"
    assert_no_strays
    pass "$CASE"
}

case_die_with_tick() {
    CASE="a subscriber that fails outright exits with its status"
    local rc
    FAKE_SUB_MODE=die FAKE_SUB_CODE=3 timeout 15 "$AWKRED" -n --mqtt -h test.invalid --tick 1 \
        >"$OUT" 2>"$ERR"
    rc=$?
    (( rc == 3 )) || bad "exit $rc (124 means it hung), stderr: $(cat "$ERR")"
    assert_no_strays
    pass "$CASE"
}

case_sigterm() {
    CASE="SIGTERM stops everything and exits 0"
    local rc
    start_awkred -n --mqtt -h test.invalid --tick 1
    sleep 2.5
    finish_awkred TERM
    rc=$?
    (( rc == 0 )) || bad "exit $rc, stderr: $(cat "$ERR")"
    assert_no_strays
    pass "$CASE"
}

# timeout starts awk-red in its own process group and signals the group, which is
# what Ctrl-C does. It also means awk-red is not a background job of this script,
# so it does not inherit SIGINT as ignored - which is exactly what a plain "&"
# here would silently fail to test.
case_sigint() {
    CASE="Ctrl-C stops everything and exits 0"
    timeout --preserve-status --signal=INT --kill-after=3 3 \
        "$AWKRED" -n --mqtt -h test.invalid --tick 1 >"$OUT" 2>"$ERR"
    local rc=$?
    case $rc in
    0) ;;
    137 | 124) bad "awk-red ignored SIGINT (exit $rc)" ;;
    *) bad "exit $rc, stderr: $(cat "$ERR")" ;;
    esac
    assert_no_strays
    pass "$CASE"
}

case_signal_without_tick() {
    CASE="a plain SIGTERM during a normal run exits 0"
    local rc
    start_awkred -n --mqtt -h test.invalid
    sleep 1.5
    finish_awkred TERM
    rc=$?
    (( rc == 0 )) || bad "exit $rc, stderr: $(cat "$ERR")"
    assert_no_strays
    pass "$CASE"
}

# If stdbuf -oL goes from either stage, the engine buffers until a multiple of
# 4-8 KB. This case looks at the output while awk-red is still running, so a
# block-buffered engine cannot pass by accident: it would have nothing to show
# yet, and a killed process never flushes.
case_buffering() {
    CASE="messages are not stuck in a buffer (stdbuf wiring)"
    export FAKE_SUB_MODE=buffered FAKE_SUB_COUNT=3
    export FAKE_SUB_TOPIC=home/door FAKE_SUB_PAYLOAD=open
    start_awkred -n -q --mqtt -h test.invalid
    unset FAKE_SUB_MODE FAKE_SUB_COUNT FAKE_SUB_TOPIC FAKE_SUB_PAYLOAD
    sleep 2
    local lines
    lines=$(grep -c '^DRYRUN> ' "$OUT")
    (( lines >= 2 )) || bad "only $lines published lines after 2 s of a live run: $(cat "$OUT")"
    finish_awkred TERM
    assert_no_strays
    pass "$CASE"
}

case_stream_routes() {
    CASE="a live stream reaches the rules"
    FAKE_SUB_MODE=stream FAKE_SUB_COUNT=3 \
        timeout 8 "$AWKRED" -n -v --mqtt -h test.invalid >"$OUT" 2>"$ERR"
    local lines
    lines=$(grep -c 'route home/kitchen/temp' "$ERR")
    (( lines == 3 )) || bad "$lines of 3 messages routed, stderr: $(cat "$ERR")"
    pass "$CASE"
}

case_validation() {
    CASE="bad clock values are usage errors"
    local rc
    "$AWKRED" --tick abc -l >/dev/null 2>"$ERR"
    rc=$?
    (( rc == 2 )) || bad "--tick abc gave exit $rc"
    "$AWKRED" --tick 5 -i examples/messages.log >/dev/null 2>"$ERR"
    rc=$?
    (( rc == 2 )) || bad "--tick with --input gave exit $rc"
    "$AWKRED" --tick 0 -l >/dev/null 2>"$ERR"
    rc=$?
    (( rc == 0 )) || bad "--tick 0 gave exit $rc"
    "$AWKRED" -l >/dev/null 2>"$ERR"
    rc=$?
    (( rc == 0 )) || bad "--list-rules gave exit $rc"
    # http validation
    "$AWKRED" --http-port abc >/dev/null 2>"$ERR"
    rc=$?
    (( rc == 2 )) || bad "--http-port abc gave exit $rc"
    "$AWKRED" --http-port 99999 >/dev/null 2>"$ERR"
    rc=$?
    (( rc == 2 )) || bad "--http-port 99999 gave exit $rc"
    "$AWKRED" -P 0 -l >/dev/null 2>"$ERR"
    rc=$?
    (( rc == 0 )) || bad "-P 0 gave exit $rc"
    "$AWKRED" -P 9 -i examples/messages.log >/dev/null 2>"$ERR"
    rc=$?
    (( rc == 2 )) || bad "-P with -i gave exit $rc"
    "$AWKRED" --mqtt -i examples/messages.log >/dev/null 2>"$ERR"
    rc=$?
    (( rc == 2 )) || bad "--mqtt with -i gave exit $rc"
    pass "$CASE"
}

case_no_input() {
    CASE="running with no input source is a usage error"
    local rc
    "$AWKRED" -n >/dev/null 2>"$ERR"
    rc=$?
    (( rc == 2 )) || bad "no-input run gave exit $rc"
    grep -qF 'no input source' "$ERR" || bad "message missing: $(cat "$ERR")"
    grep -qF -- '--tick' "$ERR" || bad "message does not say how to start: $(cat "$ERR")"
    pass "$CASE"
}

case_help_and_version() {
    CASE="help lists both forms of every paired flag"
    "$AWKRED" --help >"$OUT" 2>&1 || bad "help exited $?"
    local flag
    for flag in -n --dry-run -h --host -i --input -r --rules --tick --mqtt; do
        grep -qF -- "$flag" "$OUT" || bad "help does not mention $flag"
    done
    "$AWKRED" --version >/dev/null 2>&1 || bad "--version exited $?"
    pass "$CASE"
}


case_http_off_by_default() {
    CASE="http is off by default"
    local banner
    banner=$("$AWKRED" -n -q -i examples/messages.log 2>&1 >/dev/null)
    [[ $banner != *"http"* ]] || bad "the banner mentions http without --http-port"
    pass "$CASE"
}

case_http_routes() {
    CASE="http requests become MQTT-style lines and rules route them"
    local rc rc_msg rc_prec port
    port=$((20000 + RANDOM % 10000))
    # An http-only run: -h is a broker setting, never an input of its own.
    start_awkred -n -v --http-port "$port" -r test/rules
    sleep 1.2
    http_get "$port" "/hook/x?p=HOOKPAYLOAD"
    rc=$?
    http_get "$port" "/hook/m?msg=MSGVAL"
    rc_msg=$?
    http_get "$port" "/hook/prec?p=FIRST&msg=SECOND"
    rc_prec=$?
    finish_awkred TERM
    (( rc == 0 )) || bad "http client did not get 200 OK (p=)"
    (( rc_msg == 0 )) || bad "http client did not get 200 OK (msg=)"
    (( rc_prec == 0 )) || bad "http client did not get 200 OK (precedence)"
    grep -qF "DRYRUN> echo hook 'HOOKPAYLOAD'" "$OUT" || bad "hook echo not found, got: $(cat "$OUT")"
    grep -qF "DRYRUN> echo hook 'MSGVAL'" "$OUT" || bad "msg= payload not routed, got: $(cat "$OUT")"
    grep -qF "DRYRUN> echo hook 'FIRST'" "$OUT" || bad "p= should win over msg=, got: $(cat "$OUT")"
    grep -qF "hook 'SECOND'" "$OUT" && bad "msg= payload used despite p= being present"
    grep -qF 'route get/hook/x' "$ERR" || bad "route not logged, stderr: $(cat "$ERR")"
    assert_no_strays
    pass "$CASE"
}

case_http_port_taken() {
    CASE="http port already in use fails fast"
    local rc port
    port=$((21000 + RANDOM % 10000))
    # gawk binds lazily on the first getline, so this holds the port for as
    # long as it blocks in accept(). Keeps the suite bash+coreutils+gawk only.
    timeout 30 gawk -v PORT="$port" 'BEGIN { s = "/inet/tcp/" PORT "/0/0"; r = (s |& getline l) }' </dev/null &
    local occup=$!
    # gawk binds on first use of the /inet/tcp file and then blocks in accept()
    # for as long as it is held. Wait for the listen to appear in /proc/net/tcp
    # - a connect would consume that one accept() and release the port, letting
    # awk-red's preflight "win" and the run hang instead of failing fast.
    local hex
    hex=$(printf '%04X' "$port")
    listening() { grep -q ":${hex} 00000000:0000 0A " /proc/net/tcp 2>/dev/null; }
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
        listening && break
        sleep 0.1
    done
    if ! listening; then
        kill $occup 2>/dev/null; wait $occup 2>/dev/null
        bad "port $port never became busy"
    fi
    # The preflight must fail fast and exit 1. If anything makes awk-red go
    # live instead, timeout keeps the suite from hanging forever on it.
    timeout 15 "$AWKRED" -n -q --http-port "$port" >/dev/null 2>"$ERR"
    rc=$?
    kill $occup 2>/dev/null; wait $occup 2>/dev/null
    (( rc == 1 )) || bad "exit $rc (expected 1), stderr: $(cat "$ERR")"
    grep -qF "http port $port is not available" "$ERR" || bad "stderr: $(cat "$ERR")"
    assert_no_strays
    pass "$CASE"
}

case_http_deny() {
    CASE="http with refused subscription exits 5 without hang"
    local rc port
    port=$((22000 + RANDOM % 10000))
    FAKE_SUB_MODE=deny timeout 15 "$AWKRED" -n --mqtt --http-port "$port" -h test.invalid >/dev/null 2>"$ERR"
    rc=$?
    (( rc == 5 )) || bad "exit $rc (124 means hung), stderr: $(cat "$ERR")"
    assert_no_strays
    pass "$CASE"
}

case_http_sigterm() {
    CASE="http listener stops cleanly on SIGTERM"
    local rc port
    port=$((23000 + RANDOM % 10000))
    start_awkred -n --http-port "$port"
    sleep 1.0
    finish_awkred TERM
    rc=$?
    (( rc == 0 )) || bad "exit $rc, stderr: $(cat "$ERR")"
    assert_no_strays
    pass "$CASE"
}
case_list_rules() {
    CASE="every example rule is discovered"
    "$AWKRED" -l >"$OUT" 2>&1 || bad "--list-rules exited $?"
    grep -qF '^awk-red/tick(/|$)' "$OUT" || bad "no heartbeat rule listed"
    grep -qF '7 rule(s), 2 json(s), 0 smooth(s), 0 limit(s)' "$OUT" || bad "unexpected rule count: $(cat "$OUT")"
    pass "$CASE"
}

# Rate limits are kept per exact topic: noise/x is dropped inside its window
# while noise/y, which has a window of its own, still gets through. The first
# message on a topic always passes, so this case needs no fake clock.
case_limit_drop() {
    CASE="a rate-limited topic drops messages inside its window"
    local rc
    printf 'noise/x 1\nnoise/x 2\nnoise/y 1\nnoise/x 3\n' \
        | "$AWKRED" -n -q -r test/rules -i - >"$OUT" 2>"$ERR"
    rc=$?
    (( rc == 0 )) || bad "exit $rc, stderr: $(cat "$ERR")"
    [[ $(grep -c '^DRYRUN> echo limited ' "$OUT") == 2 ]] \
        || bad "expected 2 surviving messages, got: $(cat "$OUT")"
    grep -qF "DRYRUN> echo limited 'noise/x 1'" "$OUT" \
        || bad "the first noise/x was dropped: $(cat "$OUT")"
    grep -qF "DRYRUN> echo limited 'noise/y 1'" "$OUT" \
        || bad "noise/y does not have its own window: $(cat "$OUT")"
    grep -qF "DRYRUN> echo limited 'noise/x 3'" "$OUT" \
        && bad "noise/x passed a message inside its window: $(cat "$OUT")"
    pass "$CASE"
}

# Expiry must not be waited for on real time, and a burst on the real clock can
# straddle a second boundary, so the engine's clock can step: AWKRED_TEST_STEP=60
# advances one 60 s window per check, which is what makes this deterministic.
case_limit_expiry() {
    CASE="messages flow again once the limit window has passed"
    local rc
    printf 'noise/x 1\nnoise/x 2\nnoise/x 3\n' \
        | AWKRED_TEST_STEP=60 "$AWKRED" -n -q -r test/rules -i - >"$OUT" 2>"$ERR"
    rc=$?
    (( rc == 0 )) || bad "exit $rc, stderr: $(cat "$ERR")"
    [[ $(grep -c '^DRYRUN> echo limited ' "$OUT") == 3 ]] \
        || bad "expected all 3 messages after the window, got: $(cat "$OUT")"
    pass "$CASE"
}

case_limit_lists() {
    CASE="a registered limit is listed by --list-rules"
    "$AWKRED" -l -r test/rules >"$OUT" 2>&1 || bad "--list-rules exited $?"
    grep -qF 'limit   ^noise/' "$OUT" || bad "no limit row: $(cat "$OUT")"
    grep -qF '2 limit(s)' "$OUT" || bad "summary has no limit count: $(cat "$OUT")"
    pass "$CASE"
}

case_smooth_lists() {
    CASE="a registered smoother is listed by --list-rules"
    "$AWKRED" -l -r test/rules >"$OUT" 2>&1 || bad "--list-rules exited $?"
    grep -qF 'smooth  ^smooth/' "$OUT" || bad "no smooth row: $(cat "$OUT")"
    grep -qF '2 smooth(s)' "$OUT" || bad "summary has no smooth count: $(cat "$OUT")"
    pass "$CASE"
}

# The json() coprocess is persistent: several messages in a row must all be
# extracted, not just the first. The `head -n 1` that used to guard the pipe
# exited after one line and killed jq with EPIPE - see design.md.
case_json_stream() {
    CASE="a json() extraction keeps working across a stream of messages"
    local rc
    command -v jq >/dev/null 2>&1 || bad "jq is not installed"
    printf 'json/a {"temperature": 100}\njson/a {"temperature": 200}\njson/a {"temperature": 300}\n' \
        | "$AWKRED" -n -q -r test/rules -i - >"$OUT" 2>"$ERR"
    rc=$?
    (( rc == 0 )) || bad "exit $rc, stderr: $(cat "$ERR")"
    grep -qF "DRYRUN> echo extracted '100'" "$OUT" \
        || bad "first message not extracted: $(cat "$OUT")"
    grep -qF "DRYRUN> echo extracted '200'" "$OUT" \
        || bad "second message not extracted: $(cat "$OUT")"
    grep -qF "DRYRUN> echo extracted '300'" "$OUT" \
        || bad "third message not extracted: $(cat "$OUT")"
    grep -qF 'warning' "$ERR" && bad "the json() filter warned: $(cat "$ERR")"
    pass "$CASE"
}

# The README recipe: one JSON message, both fields on one line, and the rule
# publishes each field to its own topic - two messages from one input.
case_split_recipe() {
    CASE="one JSON message becomes a publish per field"
    local rc
    command -v jq >/dev/null 2>&1 || bad "jq is not installed"
    printf 'split/s {"temperature": 21.5, "humidity": 41}\n' \
        | "$AWKRED" -n -q -r test/rules -i - >"$OUT" 2>"$ERR"
    rc=$?
    (( rc == 0 )) || bad "exit $rc, stderr: $(cat "$ERR")"
    grep -qF "DRYRUN> mosquitto_pub " "$OUT" \
        || bad "nothing was published: $(cat "$OUT")"
    grep -qF -- "-t 'split/s/temperature' -m '21.5'" "$OUT" \
        || bad "no temperature topic: $(cat "$OUT")"
    grep -qF -- "-t 'split/s/humidity' -m '41'" "$OUT" \
        || bad "no humidity topic: $(cat "$OUT")"
    [[ $(grep -c '^DRYRUN> mosquitto_pub ' "$OUT") == 2 ]] \
        || bad "expected exactly 2 publishes: $(cat "$OUT")"
    pass "$CASE"
}

# chain() keeps the event in the process: the chained rules run with no broker
# at all, and only the eventual emit() is visible. A payload that triggered no
# rule looks like a broken test, so both fields have a handler.
case_chain_inprocess() {
    CASE="chain() routes an internal event with no broker"
    local rc
    command -v jq >/dev/null 2>&1 || bad "jq is not installed"
    printf 'chain/split {"temperature": 21, "humidity": 40}\n' \
        | "$AWKRED" -n -q -r test/rules -i - >"$OUT" 2>"$ERR"
    rc=$?
    (( rc == 0 )) || bad "exit $rc, stderr: $(cat "$ERR")"
    grep -qF "DRYRUN> echo chained-temp '21'" "$OUT" \
        || bad "the chained temperature rule did not run: $(cat "$OUT")"
    grep -qF "DRYRUN> echo chained-hum '40'" "$OUT" \
        || bad "the chained humidity rule did not run: $(cat "$OUT")"
    [[ $(grep -c '^DRYRUN> ' "$OUT") == 2 ]] \
        || bad "expected exactly 2 chained echoes, got: $(cat "$OUT")"
    pass "$CASE"
}

# A chained event is fed through the whole pipeline, not routed raw: JSON text
# queued to a topic that has a json() filter of its own must still be
# extracted. The source rule chains JSON, the target decodes it.
case_chain_pipeline() {
    CASE="a chained event re-enters the json() pipeline"
    local rc
    command -v jq >/dev/null 2>&1 || bad "jq is not installed"
    printf 'chain/numsrc 7\n' \
        | "$AWKRED" -n -q -r test/rules -i - >"$OUT" 2>"$ERR"
    rc=$?
    (( rc == 0 )) || bad "exit $rc, stderr: $(cat "$ERR")"
    grep -qF "DRYRUN> echo chained-num '7'" "$OUT" \
        || bad "the chained JSON was not extracted: $(cat "$OUT")"
    pass "$CASE"
}

# A chain that keeps matching its own topic must be cut off, not spun. The
# guard drops the event once it exceeds AWKRED_CHAIN_MAX and warns; without it
# the run would never end.
case_chain_loop_guard() {
    CASE="a self-matching chain is cut off, not spun"
    local rc
    printf 'chain/loop x\n' \
        | AWKRED_CHAIN_MAX=4 timeout 15 "$AWKRED" -n -q -r test/rules -i - \
            >"$OUT" 2>"$ERR"
    rc=$?
    (( rc == 0 )) || bad "exit $rc (124 means it spun), stderr: $(cat "$ERR")"
    grep -qF 'chain depth 5 exceeds 4' "$ERR" \
        || bad "no hop-guard warning: $(cat "$ERR")"
    pass "$CASE"
}

# The pipeline is json(), smoother, limiter: a JSON payload must be
# extracted before it can be averaged, so the average is over the numbers.
case_smooth_after_json() {
    CASE="a JSON payload is extracted before it is smoothed"
    local rc
    command -v jq >/dev/null 2>&1 || bad "jq is not installed"
    printf 'smooth/json {"temperature": 100}\nsmooth/json {"temperature": 0}\nsmooth/json {"temperature": 0}\n' \
        | "$AWKRED" -n -q -r test/rules -i - >"$OUT" 2>"$ERR"
    rc=$?
    (( rc == 0 )) || bad "exit $rc, stderr: $(cat "$ERR")"
    grep -qF "DRYRUN> echo smoothed 'smooth/json 100'" "$OUT" \
        || bad "the first value was not extracted: $(cat "$OUT")"
    grep -qF "DRYRUN> echo smoothed 'smooth/json 50'" "$OUT" \
        || bad "the second value was not averaged: $(cat "$OUT")"
    grep -qF "DRYRUN> echo smoothed 'smooth/json 25'" "$OUT" \
        || bad "the third value was not averaged: $(cat "$OUT")"
    pass "$CASE"
}

# An average carries one state value per exact topic: it starts from the first
# message, moves by the factor per message, and a payload that is not a number
# passes through untouched - it must not drag the average toward zero.
case_smooth_ema() {
    CASE="a smoothed topic averages with the factor, per topic"
    local rc
    printf 'smooth/x 100\nsmooth/x 0\nsmooth/x 0\nsmooth/y 7\n' \
        | "$AWKRED" -n -q -r test/rules -i - >"$OUT" 2>"$ERR"
    rc=$?
    (( rc == 0 )) || bad "exit $rc, stderr: $(cat "$ERR")"
    grep -qF "DRYRUN> echo smoothed 'smooth/x 100'" "$OUT" \
        || bad "the first message did not seed the state: $(cat "$OUT")"
    grep -qF "DRYRUN> echo smoothed 'smooth/x 50'" "$OUT" \
        || bad "the second message was not averaged: $(cat "$OUT")"
    grep -qF "DRYRUN> echo smoothed 'smooth/x 25'" "$OUT" \
        || bad "the third message was not averaged: $(cat "$OUT")"
    grep -qF "DRYRUN> echo smoothed 'smooth/y 7'" "$OUT" \
        || bad "smooth/y does not have state of its own: $(cat "$OUT")"
    pass "$CASE"
}

case_smooth_nonnumeric() {
    CASE="a non-numeric payload passes through and leaves the state alone"
    local rc
    printf 'smooth/x 100\nsmooth/x open\nsmooth/x 0\n' \
        | "$AWKRED" -n -q -r test/rules -i - >"$OUT" 2>"$ERR"
    rc=$?
    (( rc == 0 )) || bad "exit $rc, stderr: $(cat "$ERR")"
    grep -qF "DRYRUN> echo smoothed 'smooth/x open'" "$OUT" \
        || bad "the word was not passed through: $(cat "$OUT")"
    grep -qF "DRYRUN> echo smoothed 'smooth/x 50'" "$OUT" \
        || bad "the state moved on a non-number: $(cat "$OUT")"
    pass "$CASE"
}

# Smoothing runs before the limiter, so the average sees the messages the
# limiter drops: 100 seeds, the dropped 0 still moves the state to 50, and the
# next message through the open window carries 25. A smoother on the far side
# of the limiter would miss the dropped 0 and emit 50. AWKRED_TEST_STEP=40
# walks the 60 s window: t, t+40 (inside), t+80 (expired), no sleeping.
case_smooth_before_limit() {
    CASE="the smoother sees the messages the limiter drops"
    local rc
    printf 'throttle/x 100\nthrottle/x 0\nthrottle/x 0\n' \
        | AWKRED_TEST_STEP=40 "$AWKRED" -n -q -r test/rules -i - >"$OUT" 2>"$ERR"
    rc=$?
    (( rc == 0 )) || bad "exit $rc, stderr: $(cat "$ERR")"
    grep -qF "DRYRUN> echo smoothed 'throttle/x 100'" "$OUT" \
        || bad "the first message did not get through: $(cat "$OUT")"
    grep -qF "DRYRUN> echo smoothed 'throttle/x 25'" "$OUT" \
        || bad "the state did not include the dropped message: $(cat "$OUT")"
    [[ $(grep -c '^DRYRUN> echo smoothed ' "$OUT") == 2 ]] \
        || bad "expected exactly 2 messages through the window: $(cat "$OUT")"
    pass "$CASE"
}

# The clock must be a complete run by itself: no broker contacted, no banner
# line about one, and a clean exit on SIGTERM.
case_tick_only() {
    CASE="the clock alone runs with no broker input"
    local rc ticks
    start_awkred -n -v --tick 1
    sleep 2.5
    ticks=$(grep -c '^DRYRUN> ' "$OUT")
    (( ticks >= 2 )) || bad "only $ticks ticks in 2.5 s"
    grep -qF 'route awk-red/tick/' "$ERR" || bad "tick not routed: $(cat "$ERR")"
    grep -qF 'broker' "$ERR" && bad "the banner mentions a broker without --mqtt"
    finish_awkred TERM
    rc=$?
    (( rc == 0 )) || bad "exit $rc, stderr: $(cat "$ERR")"
    assert_no_strays
    pass "$CASE"
}

# A listener that dies on its own ends the run with its status and says so,
# instead of hanging forever on a fifo nobody will write to again.
case_http_death() {
    CASE="a killed http listener ends the run with its status"
    local rc port listener
    port=$((24000 + RANDOM % 10000))
    start_awkred -n --http-port "$port"
    sleep 1.0
    listener=$(pgrep -g "$RUN_PID" -f 'lib/http\.awk' | head -n 1)
    if [[ -z $listener ]]; then
        bad "no listener process found"
    else
        kill -KILL "$listener" 2>/dev/null || true
    fi
    wait_awkred
    rc=$?
    (( rc == 137 )) || bad "exit $rc (expected 137), stderr: $(cat "$ERR")"
    grep -qF 'http listener exited with status 137' "$ERR" || bad "stderr: $(cat "$ERR")"
    assert_no_strays
    pass "$CASE"
}

# --------------------------------------------------------------------- main

cases=(
    case_replay_golden
    case_tick_offline
    case_tick_off_by_default
    case_tick_on_silent_broker
    case_deny_no_tick
    case_deny_with_tick
    case_die_with_tick
    case_sigterm
    case_sigint
    case_signal_without_tick
    case_buffering
    case_stream_routes
    case_validation
    case_no_input
    case_help_and_version
    case_list_rules
    case_limit_drop
    case_limit_expiry
    case_limit_lists
    case_smooth_lists
    case_smooth_ema
    case_smooth_nonnumeric
    case_smooth_before_limit
    case_json_stream
    case_split_recipe
    case_chain_inprocess
    case_chain_pipeline
    case_chain_loop_guard
    case_smooth_after_json
    case_tick_only
    case_http_death
    case_http_off_by_default
    case_http_routes
    case_http_port_taken
    case_http_deny
    case_http_sigterm
)

printf 'awk-red test suite\n\n'
for c in "${cases[@]}"; do
    [[ -n $FILTER && $c != *"$FILTER"* ]] && continue
    CASE=""
    CASE_FAILED=""
    "$c" || true
    [[ -z $CASE_FAILED ]] || failed=$(( failed + 1 ))
    [[ -z $CASE_FAILED ]] || printf '  FAIL  %s\n' "${CASE:-$c}" >&2
done

printf '\n%d passed, %d failed\n' "$passed" "$failed"
(( failed == 0 ))
