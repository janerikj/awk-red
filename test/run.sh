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
        if exec 3<>/dev/tcp/127.0.0.1/"$port" 2>/dev/null; then
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
    start_awkred -n -v --tick 1 -h test.invalid
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
    FAKE_SUB_MODE=deny timeout 15 "$AWKRED" -n -h test.invalid >"$OUT" 2>"$ERR"
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
    FAKE_SUB_MODE=deny timeout 15 "$AWKRED" -n -h test.invalid --tick 1 >"$OUT" 2>"$ERR"
    rc=$?
    (( rc == 5 )) || bad "exit $rc (124 means it hung), stderr: $(cat "$ERR")"
    assert_no_strays
    pass "$CASE"
}

case_die_with_tick() {
    CASE="a subscriber that fails outright exits with its status"
    local rc
    FAKE_SUB_MODE=die FAKE_SUB_CODE=3 timeout 15 "$AWKRED" -n -h test.invalid --tick 1 \
        >"$OUT" 2>"$ERR"
    rc=$?
    (( rc == 3 )) || bad "exit $rc (124 means it hung), stderr: $(cat "$ERR")"
    assert_no_strays
    pass "$CASE"
}

case_sigterm() {
    CASE="SIGTERM stops everything and exits 0"
    local rc
    start_awkred -n -h test.invalid --tick 1
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
        "$AWKRED" -n -h test.invalid --tick 1 >"$OUT" 2>"$ERR"
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
    start_awkred -n -h test.invalid
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
    start_awkred -n -q -h test.invalid
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
        timeout 8 "$AWKRED" -n -v -h test.invalid >"$OUT" 2>"$ERR"
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
    pass "$CASE"
}

case_help_and_version() {
    CASE="help lists both forms of every paired flag"
    "$AWKRED" --help >"$OUT" 2>&1 || bad "help exited $?"
    local flag
    for flag in -n --dry-run -h --host -i --input -r --rules --tick; do
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
    start_awkred -n -v --http-port "$port" -r test/rules -h test.invalid
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
    sleep 0.6
    "$AWKRED" -n -q --http-port "$port" >/dev/null 2>"$ERR"
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
    FAKE_SUB_MODE=deny timeout 15 "$AWKRED" -n --http-port "$port" -h test.invalid >/dev/null 2>"$ERR"
    rc=$?
    (( rc == 5 )) || bad "exit $rc (124 means hung), stderr: $(cat "$ERR")"
    assert_no_strays
    pass "$CASE"
}

case_http_sigterm() {
    CASE="http listener stops cleanly on SIGTERM"
    local rc port
    port=$((23000 + RANDOM % 10000))
    start_awkred -n --http-port "$port" -h test.invalid
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
    grep -qF '4 rule(s), 1 adapter(s)' "$OUT" || bad "unexpected rule count: $(cat "$OUT")"
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
    case_help_and_version
    case_list_rules
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
