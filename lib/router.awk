# lib/router.awk - awk-red core engine
#
# The engine never changes when automations are added. It owns:
#   * configuration (environment, .env values already exported by ./awk-red)
#   * the dispatch table: reg() / route()
#   * side effects: emit(), pub(), notify via MQTT or any other command
#   * JSON extraction, so rules never care whether a topic is plain or JSON
#   * payload smoothing, so a jittery numeric topic reaches rules as an EMA
#   * rate limits, so a noisy topic is dropped before any rule runs
#   * change detection, so a level that is republished is not an event
#   * in-process chaining: chain() queues a message for another rule
#   * diagnostics: log(), debug(), warn(), error()
#
# A rule file only registers a topic filter and implements a handler:
#
#   BEGIN { reg("home/door", "door_handler", "notify on state change") }
#   function door_handler(topic, payload) { ... }
#
# reg(), json(), smooth(), limit() and changed() take an MQTT topic filter, with
# + and # wildcards. The _re forms (reg_re(), ...) take a regular expression
# instead, for the cases a filter cannot express.
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

# Run one publish and, when it fails, add the one thing mosquitto_pub's own
# "Error: ..." does not say: which broker it was talking to, and that the
# failure is a publish. mosquitto_pub's line still reaches stderr first, so its
# reason is not lost; this only attributes it. The run keeps going - a down
# broker is not a reason to drop the stream - and the status is still returned.
function publish(cmd,    rc) {
    rc = emit(cmd)
    if (rc != 0)
        error("publish to " PUB_HOST ":" PUB_PORT " failed: mosquitto_pub exited with status " rc " (is the broker running?)")
    return rc
}

# Publish an MQTT message. Connection details come from the configuration, so
# rules never hardcode host, port or credentials:
#     pub("alarm/temp", "hot")
function pub(topic, payload) {
    return publish(PUB_CMD " -t " shquote(topic) " -m " shquote(payload))
}

# Publish an MQTT message with a retained flag: pub_retained(topic, payload)
function pub_retained(topic, payload) {
    return publish(PUB_CMD " -r -t " shquote(topic) " -m " shquote(payload))
}


# ----------------------------------------------------------------- dispatch

# register_rule(pattern, handler, description) is the shared body of reg() and
# reg_re(): it appends one row to the parallel dispatch arrays.
function register_rule(pattern, handler, description) {
    N++
    ROUTE[N] = pattern
    HANDLER[N] = handler
    DESC[N] = description
}

# reg(filter, handler, description)
#
# filter is an MQTT topic filter, wildcards and all, the way you would write it
# for mosquitto_sub:
#   +   one topic level        home/+/motion
#   #   the rest of the topic  device/#
# It is rewritten to an anchored regex once, here in BEGIN, so routing never
# pays for the translation. All matching rules run, in registration order (which
# is the load order of the rule files); AWKRED_FIRST_MATCH=1 stops after the
# first. The original filter is kept only for --list-rules. For a pattern that a
# filter cannot express, use reg_re().
function reg(filter, handler, description,    re) {
    re = mqtt2re(filter)
    register_rule(re, handler, description)
    ROUTE_MQTT[N] = filter
    debug("reg " filter " -> " re)
}

# reg_re(pattern, handler, description) is reg() with a regex instead of an MQTT
# filter: the advanced form for what + and # cannot express.
function reg_re(pattern, handler, description) {
    register_rule(pattern, handler, description)
    debug("reg_re " pattern " -> " handler)
}

# Escape the ERE metacharacters in a literal MQTT topic level.
function escape_re(s) {
    gsub(/[][(){}*+?.^$|\\]/, "\\\\&", s)
    return s
}

# mqtt2re(filter) rewrites an MQTT topic filter into an anchored ERE:
#   +  -> [^/]+    exactly one (non-empty) topic level
#   #  -> .*       the remaining levels, only valid as the last level
# A trailing "/#" becomes "(/.*)?" so "home/#" also matches "home", the way a
# broker would. Every other character is escaped literally, so a topic that
# contains a regex metacharacter matches itself. A filter that still looks like
# a regex (anchors, groups, alternation - the shape of an old reg() pattern)
# warns, because it is almost certainly a pattern that has not been migrated.
function mqtt2re(filter,    n, parts, i, re) {
    if (filter ~ /[][^$()|\\]/)
        warn("mqtt pattern " filter " looks like a regex; use the _re() form")
    n = split(filter, parts, "/")
    re = "^"
    for (i = 1; i <= n; i++) {
        if (parts[i] == "#" && i == n) {
            re = re (n == 1 ? ".*" : "(/.*)?")
            break
        }
        if (i > 1)
            re = re "/"
        if (parts[i] == "+")
            re = re "[^/]+"
        else {
            if (parts[i] == "#")
                warn("mqtt filter " filter ": '#' must be the last level, treated literally")
            re = re escape_re(parts[i])
        }
    }
    return re "$"
}

# json(filter, jq_filter)
#
# The first filter that matches the topic decides how the payload is
# normalised, so rules read plain text either way:
#     json("home/sensor/json", ".temperature")
# The filter is an MQTT topic filter, like reg(). For a regex, use json_re().
function json(filter, jq_filter,    re, before) {
    re = mqtt2re(filter)
    before = JN
    json_re(re, jq_filter)
    if (JN > before) {
        JQ_MQTT[JN] = filter
        debug("json " filter " -> " re)
    }
}

# json_re(pattern, jq_filter) is json() with a regex instead of a filter.
function json_re(pattern, jq_filter) {
    if (jq_filter ~ /'/)
        return warn("json filter " jq_filter " contains a quote, ignored")
    if (!have_jq())
        return warn("json " pattern " ignored, jq is not installed")
    JN++
    JQ_PATTERN[JN] = pattern
    JQ_FILTER[JN] = jq_filter
    JQ_CMD[JN] = "jq -r --unbuffered " shquote(jq_filter) " 2>/dev/null"
    debug("json_re " pattern " -> jq " jq_filter)
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

# smooth(filter, factor) replaces every numeric payload on a matching topic
# with an exponential moving average:
#     new = factor * current + (1 - factor) * last
# where last is the previous smoothed value, so one state value per topic
# carries the whole history. The first message seeds the state and passes
# through unchanged. The filter is an MQTT topic filter; first match wins,
# state is kept per exact topic. A factor outside (0..1] warns and registers no
# smoothing, the way a bad window does. For a regex, use smooth_re().
function smooth(filter, factor,    re, before) {
    re = mqtt2re(filter)
    before = SN
    smooth_re(re, factor)
    if (SN > before) {
        SMOOTH_MQTT[SN] = filter
        debug("smooth " filter " -> " re)
    }
}

# smooth_re(pattern, factor) is smooth() with a regex instead of a filter.
function smooth_re(pattern, factor) {
    if (factor !~ /^[+]?[0-9]*\.?[0-9]+$/ || factor + 0 <= 0 || factor + 0 > 1)
        return warn("smooth " pattern " needs a factor in (0..1], ignored")
    SN++
    SMOOTH_PATTERN[SN] = pattern
    SMOOTH_FACTOR[SN] = factor + 0
    SMOOTH_ARG[SN] = factor
    debug("smooth_re " pattern " -> EMA " factor " per topic")
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

# limit(filter, seconds) allows at most one message per matching topic per
# window; every message inside the window is dropped after the payload is
# normalised and smoothed but before any rule runs, so no handler sees it. The
# filter is an MQTT topic filter; first match wins, and the window is kept per
# exact topic, so a filter over a prefix gives every topic under it a window of
# its own. A bad window is a warning and no limit, not a silent
# one-message-per-lifetime trap. For a regex, use limit_re().
function limit(filter, seconds,    re, before) {
    re = mqtt2re(filter)
    before = LN
    limit_re(re, seconds)
    if (LN > before) {
        LIMIT_MQTT[LN] = filter
        debug("limit " filter " -> " re)
    }
}

# limit_re(pattern, seconds) is limit() with a regex instead of a filter.
function limit_re(pattern, seconds) {
    if (seconds !~ /^[0-9]+$/ || seconds + 0 < 1)
        return warn("limit " pattern " needs whole seconds >= 1, ignored")
    LN++
    LIMIT_PATTERN[LN] = pattern
    LIMIT_SECONDS[LN] = seconds + 0
    debug("limit_re " pattern " -> 1 per " seconds "s per topic")
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

# ------------------------------------------------------------- dedup

# changed(filter) drops a matching topic's repeated payloads: a message only
# reaches the rules when its payload differs from the last one that did, so a
# level that a sensor keeps republishing - or a poll that reads the same
# register twice - is not an event. It is the level-to-edge conversion that
# turns "same value again" into nothing, and it is per exact topic, just like
# smooth() and limit(). The filter is an MQTT topic filter; first match wins.
# For a regex, use changed_re().
function changed(filter,    re, before) {
    re = mqtt2re(filter)
    before = CN
    changed_re(re)
    if (CN > before) {
        CHANGED_MQTT[CN] = filter
        debug("changed " filter " -> " re)
    }
}

# changed_re(pattern) is changed() with a regex instead of a filter.
function changed_re(pattern) {
    CN++
    CHANGED_PATTERN[CN] = pattern
    debug("changed_re " pattern " -> drop repeated payloads per topic")
}

# 1 when the payload repeats the last one seen on the topic, so the message is
# dropped before routing. The state is the last payload that passed, and this
# stage runs after the limiter, so a value the limiter dropped never consumes
# the edge - only a message that would have reached a rule updates it.
function unchanged(topic, payload,    i, key) {
    for (i = 1; i <= CN; i++) {
        if (topic ~ CHANGED_PATTERN[i]) {
            key = i SUBSEP topic
            if ((key in LAST_PAYLOAD) && LAST_PAYLOAD[key] == payload)
                return 1
            LAST_PAYLOAD[key] = payload
            return 0
        }
    }
    return 0
}

# Internal: dispatch one message to every matching handler. Not part of the
# rule-facing API - a rule hands work to another rule with chain(), never by
# calling route() itself.
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
    if (hits == 0) {
        if (GATEWAY) {
            # Gateway mode: an unmatched message is forwarded unchanged to the
            # publish broker, so awk-red bridges without any rule. A message
            # that matched is never republished here - the rule owns it - so an
            # acting rule and the gateway cannot double-publish.
            debug("gateway " topic " (" payload ")")
            pub(topic, payload)
        } else {
            debug("no rule matched " topic)
        }
    }
    return hits
}

# ------------------------------------------------------------------ chaining

# Internal: one message through the whole pipeline, whether it came from an
# input or from chain(). JSON first (a JSON topic must yield the number before
# it can be smoothed), smoothing next (the average needs every sample, including
# messages the limiter is about to drop), the limiter next (it gates the rules
# without gatekeeping the state), and change detection last, on the messages
# that survived the limit, so a value the limiter threw away never looks like
# the edge it was. hops is 0 for an external message and grows by one per
# chain(). Rules must not call this - it bypasses the queue and the hop guard;
# use chain() instead.
function feed(topic, payload, hops) {
    payload = adapt(topic, payload)
    payload = smoothed(topic, payload)
    if (limited(topic)) {
        DROPPED++
        debug("limited " topic " (" payload ")")
        return
    }
    if (unchanged(topic, payload)) {
        UNCHANGED++
        debug("unchanged " topic " (" payload ")")
        return
    }
    MSGS++
    CUR_HOPS = hops
    route(topic, payload)
}

# chain(topic, payload) queues an internal event for routing right after the
# current message, without publishing it. Unlike pub() the event never leaves
# the process: no broker, no subscription round-trip, and it works under
# --input too. It is fed through the same pipeline (json, smooth, limit) as an
# external message.
function chain(topic, payload) {
    CHAIN_N++
    CHAIN_TOPIC[CHAIN_N] = topic
    CHAIN_PAYLOAD[CHAIN_N] = payload
    CHAIN_HOPS[CHAIN_N] = CUR_HOPS + 1
    debug("chain " CHAIN_HOPS[CHAIN_N] ": " topic " (" payload ")")
}

# Internal: drain the queue after the current message is fully routed, called
# only by the main input loop. Iterative, not recursive: a handler may chain
# more events, which land behind the read pointer and are picked up by the same
# loop, so a long chain cannot grow the stack. The guard counts hops per event,
# so a chain that matches itself is cut off instead of spun. Reset the indices
# once drained so a long run does not accumulate queue state. Rules must not
# call this; use chain() to queue and let the engine schedule the drain.
function drain(    t, p, h) {
    while (CHAIN_READ < CHAIN_N) {
        CHAIN_READ++
        t = CHAIN_TOPIC[CHAIN_READ]
        p = CHAIN_PAYLOAD[CHAIN_READ]
        h = CHAIN_HOPS[CHAIN_READ]
        if (h > CHAIN_MAX) {
            warn("chain depth " h " exceeds " CHAIN_MAX " on " t ", dropped")
            continue
        }
        feed(t, p, h)
    }
    CHAIN_READ = 0
    CHAIN_N = 0
}

# -------------------------------------------------------------------- setup

# Publish broker connection, built from MQTT_PUB_* with a fallback to the
# subscription's MQTT_* (see docs/design.md, "Pub broker configuration"). Each
# value is resolved once here, so a bridge between two brokers is pure
# configuration and rules never see the difference.
function build_pub_cmd(    cmd) {
    cmd = "mosquitto_pub -h " shquote(PUB_HOST) " -p " shquote(PUB_PORT)
    if (PUB_USER != "")
        cmd = cmd " -u " shquote(PUB_USER)
    if (PUB_PASS != "")
        cmd = cmd " -P " shquote(PUB_PASS)
    if (PUB_TLS)
        cmd = cmd " --cafile " shquote(PUB_CAFILE != "" ? PUB_CAFILE : CA_BUNDLE)
    if (PUB_CLIENT_ID != "")
        cmd = cmd " -i " shquote(PUB_CLIENT_ID)
    return cmd
}

function list_rules(    i) {
    printf "rules from %s\n\n", RULES_DIR
    if (N == 0 && JN == 0 && SN == 0 && LN == 0 && CN == 0)
        print "  (nothing registered)"
    for (i = 1; i <= N; i++) {
        if (i in ROUTE_MQTT)
            printf "  rule    %-22s %-18s %s  [mqtt %s]\n", ROUTE[i], HANDLER[i], DESC[i], ROUTE_MQTT[i]
        else
            printf "  rule    %-22s %-18s %s\n", ROUTE[i], HANDLER[i], DESC[i]
    }
    for (i = 1; i <= JN; i++) {
        if (i in JQ_MQTT)
            printf "  json    %-22s %-18s jq %s  [mqtt %s]\n", JQ_PATTERN[i], "(payload)", JQ_FILTER[i], JQ_MQTT[i]
        else
            printf "  json    %-22s %-18s jq %s\n", JQ_PATTERN[i], "(payload)", JQ_FILTER[i]
    }
    for (i = 1; i <= SN; i++) {
        if (i in SMOOTH_MQTT)
            printf "  smooth  %-22s %-18s ema %s  [mqtt %s]\n", SMOOTH_PATTERN[i], "(payload)", SMOOTH_ARG[i], SMOOTH_MQTT[i]
        else
            printf "  smooth  %-22s %-18s ema %s\n", SMOOTH_PATTERN[i], "(payload)", SMOOTH_ARG[i]
    }
    for (i = 1; i <= LN; i++) {
        if (i in LIMIT_MQTT)
            printf "  limit   %-22s %-18s 1 per %ds  [mqtt %s]\n", LIMIT_PATTERN[i], "(topic)", LIMIT_SECONDS[i], LIMIT_MQTT[i]
        else
            printf "  limit   %-22s %-18s 1 per %ds\n", LIMIT_PATTERN[i], "(topic)", LIMIT_SECONDS[i]
    }
    for (i = 1; i <= CN; i++) {
        if (i in CHANGED_MQTT)
            printf "  changed %-22s %-18s per topic  [mqtt %s]\n", CHANGED_PATTERN[i], "(payload)", CHANGED_MQTT[i]
        else
            printf "  changed %-22s %-18s per topic\n", CHANGED_PATTERN[i], "(payload)"
    }
    printf "\n%d rule(s), %d json(s), %d smooth(s), %d limit(s), %d changed(s)\n", N, JN, SN, LN, CN
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
    GATEWAY = envbool("AWKRED_GATEWAY", "0")
    RULES_DIR = getenv("AWKRED_RULES", "(none)")

    MQTT_HOST = getenv("MQTT_HOST", "localhost")
    MQTT_PORT = getenv("MQTT_PORT", "1883")
    MQTT_USER = getenv("MQTT_USER", "")
    MQTT_PASS = getenv("MQTT_PASS", "")
    MQTT_TLS = envbool("MQTT_TLS", "0")
    MQTT_CAFILE = getenv("MQTT_CAFILE", "")
    MQTT_CLIENT_ID = getenv("MQTT_CLIENT_ID", "")

    # Publish broker. Every MQTT_PUB_* falls back to its MQTT_* counterpart, so
    # an existing single-broker setup is unchanged; setting any of them points
    # pub() at a different broker without touching the subscription.
    PUB_HOST = getenv("MQTT_PUB_HOST", MQTT_HOST)
    PUB_PORT = getenv("MQTT_PUB_PORT", MQTT_PORT)
    PUB_USER = getenv("MQTT_PUB_USER", MQTT_USER)
    PUB_PASS = getenv("MQTT_PUB_PASS", MQTT_PASS)
    PUB_CAFILE = getenv("MQTT_PUB_CAFILE", MQTT_CAFILE)
    PUB_CLIENT_ID = getenv("MQTT_PUB_CLIENT_ID", MQTT_CLIENT_ID)
    PUB_TLS = (getenv("MQTT_PUB_TLS", "") != "") ? envbool("MQTT_PUB_TLS", "0") : MQTT_TLS

    PUB_CMD = build_pub_cmd()
    CLOCK_STEP = getenv("AWKRED_TEST_STEP", "0") + 0
    CHAIN_MAX = getenv("AWKRED_CHAIN_MAX", "32") + 0
    if (CHAIN_MAX < 1)
        CHAIN_MAX = 32
    CHAIN_READ = 0
    CHAIN_N = 0
    CUR_HOPS = 0
    MSGS = 0
    DROPPED = 0
    UNCHANGED = 0
}

# The one generic rule: parse the line and dispatch. This is the whole engine.
{
    if ($0 == "")
        next
    topic = $1
    payload = substr($0, length(topic) + 2)
    feed(topic, payload, 0)
    drain()
    fflush("")
}

END {
    for (i = 1; i <= JN; i++)
        close(JQ_CMD[i])
    if (LIST)
        list_rules()
    else if (VERBOSE && !QUIET)
        debug(MSGS " message(s) processed" \
              (DROPPED > 0 ? ", " DROPPED " dropped by a rate limit" : "") \
              (UNCHANGED > 0 ? ", " UNCHANGED " dropped as unchanged" : ""))
}
