# lib/router.awk - awk-red core engine
#
# The engine never changes when automations are added. It owns:
#   * configuration (environment, .env values already exported by ./awk-red)
#   * the dispatch table: reg() / route()
#   * side effects: emit(), pub(), notify via MQTT or any other command
#   * payload adapters, so rules never care whether a topic is plain or JSON
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

# Payload adapters. The first pattern that matches the topic decides how the
# payload is normalised, so rules read plain text either way:
#     adapter("^home/sensor/json$", ".temperature")
# Patterns follow the same rules as reg().
function adapter(pattern, jq_filter) {
    if (jq_filter ~ /'/)
        return warn("adapter filter " jq_filter " contains a quote, ignored")
    if (!have_jq())
        return warn("adapter " pattern " ignored, jq is not installed")
    JN++
    JQ_PATTERN[JN] = pattern
    JQ_FILTER[JN] = jq_filter
    JQ_CMD[JN] = "jq -r --unbuffered " shquote(jq_filter) " 2>/dev/null | head -n 1"
    debug("adapter " pattern " -> jq " jq_filter)
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

# Run the payload through the registered adapter, if any. The adapter must
# yield exactly one line per message; head -n 1 drops the rest, otherwise one
# extra line would desync every following message.
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

    # Coprocess: one persistent jq per adapter, started on first use.
    # Both sides must flush per message or the pair deadlocks on a full buffer.
    print payload |& cmd
    fflush(cmd)
    n = (cmd |& getline out)
    if (n <= 0) {
        warn("jq adapter " JQ_PATTERN[i] " produced no output, payload passed through raw")
        close(cmd)
        return payload
    }
    debug("adapter output: " out)
    return out
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
    if (N == 0 && JN == 0)
        print "  (nothing registered)"
    for (i = 1; i <= N; i++)
        printf "  rule    %-22s %-18s %s\n", ROUTE[i], HANDLER[i], DESC[i]
    for (i = 1; i <= JN; i++)
        printf "  adapter %-22s %-18s jq %s\n", JQ_PATTERN[i], "(payload)", JQ_FILTER[i]
    printf "\n%d rule(s), %d adapter(s)\n", N, JN
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
    MSGS = 0
}

# The one generic rule: parse the line and dispatch. This is the whole engine.
{
    if ($0 == "")
        next
    topic = $1
    payload = substr($0, length(topic) + 2)
    payload = adapt(topic, payload)
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
        debug(MSGS " message(s) processed")
}