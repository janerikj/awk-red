# lib/router.awk - awk-red core engine
#
# The engine never changes when automations are added. It owns:
#   * configuration (environment, .env values already exported by ./awk-red)
#   * the dispatch table: reg() / route()
#   * side effects: emit(), pub(), notify via MQTT or any other command
#   * JSON extraction, so rules never care whether a topic is plain or JSON
#   * payload smoothing, so a jittery numeric topic reaches rules as an EMA
#   * rate limits, so a noisy topic is dropped before any rule runs
#   * diagnostics: log(), debug(), warn(), error()
#
# A rule file only registers a topic pattern and implements a handler:
#
#   BEGIN { reg("^home/door$", "door_handler", "notify on state change") }
#   function door_handler(topic, payload) { ... }
#
# Do not run this file directly - use ./awk-red, which adds the rule files,
# line-buffers both pipeline stages and passes the configuration.
#
# Requires gawk >= 4.0 (indirect calls, two-way coprocesses, strftime()).

# ---------------------------------------------------------------- utilities

function getenv(name, def) {
    return (name in ENVIRON) && ENVIRON[name] != "" ? ENVIRON[name] : def
}

function envbool(name, def) {
    v = getenv(name, def)
    return (v ~ /^(1|true|yes|on)$/) ? 1 : 0
}

# Single-quote a string for /bin/sh. Used for every value that ends up in a
# command line, so payloads containing spaces or quotes stay one argument.
function shquote(s,    r) {
    r = s ""
    gsub(/'/, "'\\''", r)
    return "'" r "'"
}

function debug(msg) {
    if (VERBOSE && !QUIET)
        printf "%s %s\n", strftime("%H:%M:%S"), msg > STDERR
}

function warn(msg) {
    printf "%s: warning: %s\n", PROG, msg > STDERR
}

function error(msg) {
    printf "%s: error: %s\n", PROG, msg > STDERR
}

# ------------------------------------------------------------- side effects

# Every side effect goes through emit(), so DRYRUN covers the whole system.
# DRYRUN=1 prints the command instead of running it.
function emit(cmd,    rc) {
    if (DRYRUN) {
        printf "DRYRUN> %s\n", cmd
        fflush("")
        return 0
    }
    rc = system(cmd)
    debug("exit " rc ": " cmd)
    fflush("")
    return rc
}

# Publish an MQTT message. Connection details come from the configuration, so
# rules never hardcode host, port or credentials:
#     pub("alarm/temp", "hot")
function pub(topic, payload) {
    return emit(PUB_CMD " -t " shquote(topic) " -m " shquote(payload))
}

# Publish an MQTT message with a retained flag: pub_retained(topic, payload)
function pub_retained(topic, payload) {
    return emit(PUB_CMD " -r -t " shquote(topic) " -m " shquote(payload))
}


# ----------------------------------------------------------------- dispatch

# reg(pattern, handler, description)
#
# pattern is a regex matched against the topic. All matching rules run, in
# registration order (registration order is the load order of the rule files).
# Set AWKRED_FIRST_MATCH=1 to stop after the first match.
function reg(pattern, handler, description) {
    N++
    ROUTE[N] = pattern
    HANDLER[N] = handler
    DESC[N] = description
    debug("registered " pattern " -> " handler)
}

# JSON extraction. The first pattern that matches the topic decides how the
# payload is normalised, so rules read plain text either way:
#     json("^home/sensor/json$", ".temperature")
# Patterns follow the same rules as reg().
function json(pattern, jq_filter) {
    if (jq_filter ~ /'/)
        return warn("json filter " jq_filter " contains a quote, ignored")
    if (!have_jq())
        return warn("json " pattern " ignored, jq is not installed")
    JN++
    JQ_PATTERN[JN] = pattern
    JQ_FILTER[JN] = jq_filter
    JQ_CMD[JN] = "jq -r --unbuffered " shquote(jq_filter) " 2>/dev/null"
    debug("json " pattern " -> jq " jq_filter)
}

# Coprocesses die fatally if the program cannot be started, so check once.
function have_jq(    cmd) {
    if (JQ_CHECKED)
        return JQ_OK
    cmd = "command -v jq 2>/dev/null"
    JQ_CHECKED = 1
    JQ_OK = ((cmd | getline found) > 0 && found != "")
    close(cmd)
    return JQ_OK
}

# Run the payload through the registered json() filter, if any. The filter
# must yield exactly one line per message; this reads exactly one line, so a
# filter that yields more leaves the extra in the pipe and desyncs every later
# message (see design.md - do not "guard" the command with `head -n 1`:
# head exits after its first line and kills jq with EPIPE).
function adapt(topic, payload,    i, cmd, out, n) {
    cmd = ""
    for (i = 1; i <= JN; i++) {
        if (topic ~ JQ_PATTERN[i]) {
            cmd = JQ_CMD[i]
            break
        }
    }
    if (cmd == "")
        return payload

    # Coprocess: one persistent jq per filter, started on first use.
    # Both sides must flush per message or the pair deadlocks on a full buffer.
    print payload |& cmd
    fflush(cmd)
    n = (cmd |& getline out)
    if (n <= 0) {
        warn("json " JQ_PATTERN[i] ": jq produced no output, payload passed through raw")
        close(cmd)
        return payload
    }
    debug("json output: " out)
    return out
}

# ------------------------------------------------------------- smoothing

# smooth(pattern, factor) replaces every numeric payload on a matching topic
# with an exponential moving average:
#     new = factor * current + (1 - factor) * last
# where last is the previous smoothed value, so one state value per topic
# carries the whole history. The first message seeds the state and passes
# through unchanged. Patterns follow the same rules as reg() and json():
# first match wins, state is kept per exact topic. A factor outside (0..1]
# warns and registers no smoothing, the way a bad window does.
function smooth(pattern, factor) {
    if (factor !~ /^[+]?[0-9]*\.?[0-9]+$/ || factor + 0 <= 0 || factor + 0 > 1)
        return warn("smooth " pattern " needs a factor in (0..1], ignored")
    SN++
    SMOOTH_PATTERN[SN] = pattern
    SMOOTH_FACTOR[SN] = factor + 0
    SMOOTH_ARG[SN] = factor
    debug("smooth " pattern " -> EMA " factor " per topic")
}

# Run the payload through the registered smoother, if any. A payload that is
# not a number is passed through untouched and does not touch the state, so a
# broad pattern over a topic that also carries words cannot drag the average
# toward zero. The state keeps full double precision; the payload rules see
# is formatted explicitly so a rule redefining CONVFMT cannot change it.
function smoothed(topic, payload,    i, v, key, last) {
    for (i = 1; i <= SN; i++) {
        if (topic ~ SMOOTH_PATTERN[i]) {
            if (payload !~ /^[ \t]*[+-]?([0-9]+(\.[0-9]*)?|\.[0-9]+)([eE][+-]?[0-9]+)?[ \t]*$/) {
                debug("smooth " topic ": payload is not a number, passed through")
                return payload
            }
            v = payload + 0
            key = i SUBSEP topic
            last = (key in EMA) ? EMA[key] : v
            EMA[key] = SMOOTH_FACTOR[i] * v + (1 - SMOOTH_FACTOR[i]) * last
            return sprintf("%.6g", EMA[key])
        }
    }
    return payload
}

# ------------------------------------------------------------- rate limits

# limit(pattern, seconds) allows at most one message per matching topic per
# window; every message inside the window is dropped after the payload is
# normalised and smoothed but before any rule runs, so no handler sees it.
# Patterns follow the same rules as reg() and json(): first match wins, and
# the window is kept per exact topic, so a pattern over a prefix gives every
# topic under it a window of its own. A bad window is a warning and no limit,
# not a silent one-message-per-lifetime trap.
function limit(pattern, seconds) {
    if (seconds !~ /^[0-9]+$/ || seconds + 0 < 1)
        return warn("limit " pattern " needs whole seconds >= 1, ignored")
    LN++
    LIMIT_PATTERN[LN] = pattern
    LIMIT_SECONDS[LN] = seconds + 0
    debug("limit " pattern " -> 1 per " seconds "s per topic")
}

# The clock a limit window is measured against: systime(), whose one-second
# resolution is the resolution of a window. AWKRED_TEST_STEP is a test seam,
# not configuration (like MOSQ_SUB it exists so test/ can produce a behaviour
# deterministically): when it is set, clock() starts at the real time and
# advances by that many seconds per check, so a test can cross a window
# boundary without sleeping or risking a second-boundary flake.
function clock(    now) {
    if (CLOCK_STEP == 0)
        return systime()
    if (CLOCK_BASE == 0)
        CLOCK_BASE = systime()
    now = CLOCK_BASE + CLOCK_TICKS * CLOCK_STEP
    CLOCK_TICKS++
    return now
}

# 1 when the topic is inside its window, in which case the message is dropped.
function limited(topic,    i, key, now) {
    for (i = 1; i <= LN; i++) {
        if (topic ~ LIMIT_PATTERN[i]) {
            key = i SUBSEP topic
            now = clock()
            if ((key in LIMIT_LAST) && now - LIMIT_LAST[key] < LIMIT_SECONDS[i])
                return 1
            LIMIT_LAST[key] = now
            return 0
        }
    }
    return 0
}

function route(topic, payload,    i, hits, fn) {
    hits = 0
    for (i = 1; i <= N; i++) {
        if (topic ~ ROUTE[i]) {
            hits++
            debug("route " topic " (" payload ") -> " HANDLER[i])
            fn = HANDLER[i]       # indirect call needs @, gawk >= 4.0
            @fn(topic, payload)
            if (FIRST_MATCH)
                return hits
        }
    }
    if (hits == 0)
        debug("no rule matched " topic)
    return hits
}

# -------------------------------------------------------------------- setup

function build_pub_cmd(    cmd) {
    cmd = "mosquitto_pub -h " shquote(MQTT_HOST) " -p " shquote(MQTT_PORT)
    if (MQTT_USER != "")
        cmd = cmd " -u " shquote(MQTT_USER)
    if (MQTT_PASS != "")
        cmd = cmd " -P " shquote(MQTT_PASS)
    if (MQTT_TLS)
        cmd = cmd " --cafile " shquote(MQTT_CAFILE != "" ? MQTT_CAFILE : CA_BUNDLE)
    return cmd
}

function list_rules(    i) {
    printf "rules from %s\n\n", RULES_DIR
    if (N == 0 && JN == 0 && SN == 0 && LN == 0)
        print "  (nothing registered)"
    for (i = 1; i <= N; i++)
        printf "  rule    %-22s %-18s %s\n", ROUTE[i], HANDLER[i], DESC[i]
    for (i = 1; i <= JN; i++)
        printf "  json    %-22s %-18s jq %s\n", JQ_PATTERN[i], "(payload)", JQ_FILTER[i]
    for (i = 1; i <= SN; i++)
        printf "  smooth  %-22s %-18s ema %s\n", SMOOTH_PATTERN[i], "(payload)", SMOOTH_ARG[i]
    for (i = 1; i <= LN; i++)
        printf "  limit   %-22s %-18s 1 per %ds\n", LIMIT_PATTERN[i], "(topic)", LIMIT_SECONDS[i]
    printf "\n%d rule(s), %d json(s), %d smooth(s), %d limit(s)\n", N, JN, SN, LN
}

BEGIN {
    STDERR = "/dev/stderr"
    CA_BUNDLE = "/etc/ssl/certs/ca-certificates.crt"

    PROG = getenv("AWKRED_PROG", "awk-red")
    DRYRUN = envbool("DRYRUN", "0")
    VERBOSE = envbool("AWKRED_VERBOSE", "0")
    QUIET = envbool("AWKRED_QUIET", "0")
    LIST = envbool("AWKRED_LIST", "0")
    FIRST_MATCH = envbool("AWKRED_FIRST_MATCH", "0")
    RULES_DIR = getenv("AWKRED_RULES", "?")

    MQTT_HOST = getenv("MQTT_HOST", "localhost")
    MQTT_PORT = getenv("MQTT_PORT", "1883")
    MQTT_USER = getenv("MQTT_USER", "")
    MQTT_PASS = getenv("MQTT_PASS", "")
    MQTT_TLS = envbool("MQTT_TLS", "0")
    MQTT_CAFILE = getenv("MQTT_CAFILE", "")

    PUB_CMD = build_pub_cmd()
    CLOCK_STEP = getenv("AWKRED_TEST_STEP", "0") + 0
    MSGS = 0
    DROPPED = 0
}

# The one generic rule: parse the line and dispatch. This is the whole engine.
{
    if ($0 == "")
        next
    topic = $1
    payload = substr($0, length(topic) + 2)
    # json() first: JSON topics must yield the number before it can be
    # smoothed. Smoothing next: the average needs every sample, including
    # messages the limiter is about to drop. The limiter runs last of the
    # three, so it gates the rules without gatekeeping the state.
    payload = adapt(topic, payload)
    payload = smoothed(topic, payload)
    if (limited(topic)) {
        DROPPED++
        debug("limited " topic " (" payload ")")
        next
    }
    MSGS++
    route(topic, payload)
    fflush("")
}

END {
    for (i = 1; i <= JN; i++)
        close(JQ_CMD[i])
    if (LIST)
        list_rules()
    else if (VERBOSE && !QUIET)
        debug(MSGS " message(s) processed" \
              (DROPPED > 0 ? ", " DROPPED " dropped by a rate limit" : ""))
}
