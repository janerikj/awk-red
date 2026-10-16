#!/usr/bin/env bash
#
# bench - compare awk-red's capacity with a raw MQTT round trip.
#
# Four stages handle the exact same N messages, each measured as the wall-clock
# span from the first to the last message of the run, at the point that stage
# can see it:
#
#   broker      mosquitto_pub -l -> broker -> mosquitto_sub -C N
#   subscriber  mosquitto_pub -l -> broker -> mosquitto_sub -> fifo -> engine
#   engine      awk-red -i (no broker), pure pipeline
#   publisher   awk-red -i, a rule pub()ing each message -> broker -> monitor
#
# The broker is on another host by design; latency is part of the number. The
# two mosquitto tools stamp arrivals with %U (epoch, nanoseconds); the awk-red
# stages cannot clock themselves (gawk's systime() is whole seconds), so the
# benchmark rule shells out `date +%s.%N` on message #1 and #N only.
#
# usage: bench/run.sh [-h HOST] [-p PORT] [-u USER] [-P PASS]
#                     [-n "N N"] [-r REPEATS] [-q QOS] [--nodelay] [--sleep S]
#
# defaults: host mqtt.example.invalid, port 1883, N "100 1000", 5 repeats, QoS 0.
# Precedence is the same as awk-red's: command line > environment > .env >
# default, and any MQTT_* exported here wins over .env.
set -euo pipefail

SELF_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd -- "$SELF_DIR/.." && pwd)
AWKRED="$ROOT/awk-red"
RULES_SUB="$SELF_DIR/rules/sub"
RULES_PUB="$SELF_DIR/rules/pub"
TMP="$SELF_DIR/tmp"
mkdir -p "$TMP"

OPT_HOST="" OPT_PORT="" OPT_USER="" OPT_PASS=""
OPT_N="" OPT_REPEATS="" OPT_QOS="" OPT_NODELAY="" OPT_SLEEP=""

usage() {
    sed -n '2,25p' "$SELF_DIR/run.sh" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

while (( $# )); do
    case $1 in
        -h|--host)     OPT_HOST=$2; shift 2 ;;
        --host=*)      OPT_HOST=${1#*=}; shift ;;
        -p|--port)     OPT_PORT=$2; shift 2 ;;
        --port=*)      OPT_PORT=${1#*=}; shift ;;
        -u|--user)     OPT_USER=$2; shift 2 ;;
        --user=*)      OPT_USER=${1#*=}; shift ;;
        -P|--pass)     OPT_PASS=$2; shift 2 ;;
        --pass=*)      OPT_PASS=${1#*=}; shift ;;
        -n|--count)    OPT_N=$2; shift 2 ;;
        --count=*)     OPT_N=${1#*=}; shift ;;
        -r|--repeats)  OPT_REPEATS=$2; shift 2 ;;
        --repeats=*)   OPT_REPEATS=${1#*=}; shift ;;
        -q|--qos)      OPT_QOS=$2; shift 2 ;;
        --qos=*)       OPT_QOS=${1#*=}; shift ;;
        --nodelay)     OPT_NODELAY=1; shift ;;
        --sleep)       OPT_SLEEP=$2; shift 2 ;;
        --sleep=*)     OPT_SLEEP=${1#*=}; shift ;;
        -?|--help)     usage 0 ;;
        -*)            printf 'bench: unknown option: %s\n' "$1" >&2; usage 2 ;;
        *)             printf 'bench: unexpected argument: %s\n' "$1" >&2; usage 2 ;;
    esac
done

# ------------------------------------------------------------ config
need() { command -v "$1" >/dev/null 2>&1 || { printf 'bench: %s not found\n' "$1" >&2; exit 1; }; }
need mosquitto_pub
need mosquitto_sub
need gawk
need stdbuf
need date
[[ -x $AWKRED ]] || { printf 'bench: %s not executable\n' "$AWKRED" >&2; exit 1; }

# The environment wins over .env, the way awk-red resolves it. Capture what was
# exported, source .env, then put the exported values back.
ENV_HOST=${MQTT_HOST:-} ENV_PORT=${MQTT_PORT:-} ENV_USER=${MQTT_USER:-} ENV_PASS=${MQTT_PASS:-}
if [[ -z ${BENCH_NO_ENV:-} && -r $ROOT/.env ]]; then
    set -a; # shellcheck disable=SC1091
    . "$ROOT/.env"; set +a
fi
[[ -n $ENV_HOST ]] && MQTT_HOST=$ENV_HOST
[[ -n $ENV_PORT ]] && MQTT_PORT=$ENV_PORT
[[ -n $ENV_USER ]] && MQTT_USER=$ENV_USER
[[ -n $ENV_PASS ]] && MQTT_PASS=$ENV_PASS

HOST=${OPT_HOST:-${MQTT_HOST:-mqtt.example.invalid}}
PORT=${OPT_PORT:-${MQTT_PORT:-1883}}
USER=${OPT_USER:-${MQTT_USER:-}}
PASS=${OPT_PASS:-${MQTT_PASS:-}}
N_LIST=${OPT_N:-"100 1000"}
REPEATS=${OPT_REPEATS:-5}
QOS=${OPT_QOS:-0}
NODELAY=${OPT_NODELAY:-0}
READY_SLEEP=${OPT_SLEEP:-0.8}

# awk-red takes the broker from the environment (and -h/-p); the credentials
# only ever come from MQTT_USER/MQTT_PASS. Export everything so a rule calling
# pub() reaches the same broker as the tools below.
export MQTT_HOST=$HOST MQTT_PORT=$PORT
[[ -n $USER ]] && export MQTT_USER=$USER
[[ -n $PASS ]] && export MQTT_PASS=$PASS
# Neutralise a developer's .env inputs: the bench names its own.
export AWKRED_MQTT=0 AWKRED_TICK=0 AWKRED_WEBHOOK=0 AWKRED_TEST_STEP=0

MOSQ=(-h "$HOST" -p "$PORT")
[[ -n $USER ]] && MOSQ+=(-u "$USER")
[[ -n $PASS ]] && MOSQ+=(-P "$PASS")
[[ $QOS -gt 0 ]] && MOSQ+=(-q "$QOS")
[[ $NODELAY == 1 ]] && MOSQ+=(--nodelay)
# -e /dev/null: ignore ./.env in awk-red, the bench has already resolved it.
AWKFLAGS=(-q -e /dev/null -h "$HOST" -p "$PORT")

# ------------------------------------------------------------- helpers
now() { date +%s.%N; }

span_file() { # ns arrivals, one per line -> last - first
    awk 'NR==1{f=$1} {l=$1} END{ if (NR>=2) printf "%.9f\n", l-f; else print "" }' "$1"
}

marker_span() { # two `date +%s.%N` files written by the benchmark rule
    awk -v m="$1" 'BEGIN{
        if ((getline a < (m ".first")) <= 0 || (getline b < (m ".last")) <= 0) { print ""; exit }
        printf "%.9f\n", b - a
    }'
}

wait_pid() { # pid, whole seconds; return 1 and TERM it if it overruns
    local pid=$1 secs=$2 i n=$(( $2 * 10 ))
    for ((i = 0; i < n; i++)); do
        kill -0 "$pid" 2>/dev/null || return 0
        sleep 0.1
    done
    printf 'bench: pid %s did not exit within %ss\n' "$pid" "$secs" >&2
    kill -TERM "$pid" 2>/dev/null || true
    return 1
}

# Each stage prints "<span> <wall>": the first-to-last span at its own clock,
# and the wall time of the sending side (publish burst / awk-red process).
# A fixed sleep establishes the subscription: mosquitto_sub's debug (-d) shares
# stdout with the payload, so it cannot be used as a readiness handshake here.
bench_broker() {
    local times=$TMP/a.times
    : > "$times"; : > "$TMP/sub.err"
    mosquitto_sub "${MOSQ[@]}" -t "$IN" -C "$N" -F '%U' > "$times" 2>"$TMP/sub.err" &
    local sp=$! t0 t1
    sleep "$READY_SLEEP"
    t0=$(now)
    mosquitto_pub "${MOSQ[@]}" -t "$IN" -l < "$PAYLOADS"
    t1=$(now)
    wait_pid "$sp" 30 || true
    printf '%s %s\n' "$(span_file "$times")" "$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.6f", b-a}')"
}

bench_subscriber() {
    local marker=$TMP/b.mark
    rm -f "$marker".first "$marker".last
    BENCH_IN="$IN" BENCH_N="$N" BENCH_MARKER="$marker" \
        "$AWKRED" --mqtt "${AWKFLAGS[@]}" -t "$IN" -r "$RULES_SUB" &
    local ap=$! t0 t1
    sleep "$READY_SLEEP"
    t0=$(now)
    mosquitto_pub "${MOSQ[@]}" -t "$IN" -l < "$PAYLOADS"
    t1=$(now)
    wait_pid "$ap" 30 || true
    printf '%s %s\n' "$(marker_span "$marker")" "$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.6f", b-a}')"
}

bench_engine() {
    local marker=$TMP/c.mark
    rm -f "$marker".first "$marker".last
    local t0 t1
    t0=$(now)
    BENCH_IN="$IN" BENCH_N="$N" BENCH_MARKER="$marker" \
        "$AWKRED" -i "$RECORDING" -r "$RULES_SUB" -q
    t1=$(now)
    printf '%s %s\n' "$(marker_span "$marker")" "$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.6f", b-a}')"
}

bench_publisher() {
    local times=$TMP/d.times
    : > "$times"; : > "$TMP/sub.err"
    mosquitto_sub "${MOSQ[@]}" -t "$OUT" -C "$N" -F '%U' > "$times" 2>"$TMP/sub.err" &
    local sp=$! t0 t1
    sleep "$READY_SLEEP"
    t0=$(now)
    BENCH_IN="$IN" BENCH_OUT="$OUT" \
        "$AWKRED" -i "$RECORDING" -r "$RULES_PUB" -q
    t1=$(now)
    wait_pid "$sp" 30 || true
    printf '%s %s\n' "$(span_file "$times")" "$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.6f", b-a}')"
}

median_col() { # file, column
    awk -v c="$2" '{v=$c; if (v=="") next; a[++n]=v} END{
        if (n==0) { print "NA"; exit }
        for (i=2;i<=n;i++){x=a[i];j=i-1; while(j>0 && a[j]>x){a[j+1]=a[j];j--} a[j+1]=x}
        if (n%2) printf "%.6f", a[(n+1)/2]; else printf "%.6f", (a[n/2]+a[n/2+1])/2
    }' "$1"
}

min_col() { # file, column: the best run, i.e. without a connection stall
    awk -v c="$2" '{v=$c; if (v=="") next; if (n==0 || v<m) m=v; n++} END{
        if (n==0) print "NA"; else printf "%.6f", m
    }' "$1"
}

rates() { # N, span_seconds -> "ms/msg msg/s"
    awk -v n="$1" -v s="$2" 'BEGIN{
        if (n<2 || s=="" || s<=0) { print "NA NA"; exit }
        printf "%.3f %.1f", (s*1000)/(n-1), (n-1)/s
    }'
}

# ---------------------------------------------------------------- run
RUNID=$(date +%s)-$$
BASE="awk-red-bench/$RUNID"
IN="$BASE/in"
OUT="$BASE/out"

printf 'bench: broker %s:%s  N "%s"  repeats %s  qos %s%s\n' \
    "$HOST" "$PORT" "$N_LIST" "$REPEATS" "$QOS" \
    "$([[ $NODELAY == 1 ]] && printf '  nodelay')"
printf 'bench: topic %s  (anonymous %s)\n' "$BASE" \
    "$([[ -z $USER ]] && printf 'yes' || printf 'no')"

for N in $N_LIST; do
    [[ $N =~ ^[0-9]+$ ]] && (( N > 1 )) || { printf 'bench: bad N: %s\n' "$N" >&2; exit 2; }
    PAYLOADS=$TMP/payloads.$N
    RECORDING=$TMP/recording.$N
    seq 0 $((N - 1)) > "$PAYLOADS"
    awk -v t="$IN" '{print t" "$0}' "$PAYLOADS" > "$RECORDING"

    for stage in broker subscriber engine publisher; do : > "$TMP/$stage.$N"; done

    # One discarded warm-up per stage: fills caches, connects the broker, and
    # keeps the awk-red gawk compile out of the measured runs.
    bench_broker      >/dev/null 2>>"$TMP/warn.$N" || true
    bench_subscriber  >/dev/null 2>>"$TMP/warn.$N" || true
    bench_engine      >/dev/null 2>>"$TMP/warn.$N" || true
    bench_publisher   >/dev/null 2>>"$TMP/warn.$N" || true

    for ((k = 1; k <= REPEATS; k++)); do
        bench_broker     >> "$TMP/broker.$N"
        bench_subscriber >> "$TMP/subscriber.$N"
        bench_engine     >> "$TMP/engine.$N"
        bench_publisher  >> "$TMP/publisher.$N"
    done
done

# --------------------------------------------------------------- table
fmt_rate() { # N, span -> "ms/msg    msg/s"
    rates "$1" "$2" | awk '{printf "%9s  %10s", $1, $2}'
}

for N in $N_LIST; do
    printf '\nN = %s messages, median of %s runs (broker %s:%s)\n' "$N" "$REPEATS" "$HOST" "$PORT"
    printf '%-12s %12s %12s %10s %11s %10s\n' stage 'span_s' 'best_s' 'ms/msg' 'msg/s' 'wall_s'

    declare -A SPAN
    for stage in broker subscriber engine publisher; do
        f=$TMP/$stage.$N
        span=$(median_col "$f" 1)
        best=$(min_col "$f" 1)
        wall=$(median_col "$f" 2)
        SPAN[$stage]=$span
        rate=$(fmt_rate "$N" "$span")
        printf '%-12s %12s %12s %s %10s\n' "$stage" "${span:-NA}" "${best:-NA}" "$rate" "${wall:-NA}"
    done

    input=$(awk -v a="${SPAN[broker]:-}" -v b="${SPAN[subscriber]:-}" \
        'BEGIN{ if(a=="" || b=="") print "NA"; else printf "%.6f", b-a }')
    pub=$(awk -v a="${SPAN[engine]:-}" -v b="${SPAN[publisher]:-}" \
        'BEGIN{ if(a=="" || b=="") print "NA"; else printf "%.6f", b-a }')
    printf '%-12s %12s  (subscriber - broker: MQTT input path)\n' 'delta' "$input"
    printf '%-12s %12s  (publisher - engine: one mosquitto_pub per message)\n' 'delta' "$pub"
done

printf '\nraw: %s/<stage>.<N>  (span wall, one line per run)\nwarnings: %s/warn.*\n' "$TMP" "$TMP"
