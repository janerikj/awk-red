# test/rules/regexp.awk - the _re() escape hatches still take a regular
# expression.
#
# An MQTT topic filter is the default because + and # cover almost every topic
# that exists, but they cannot say "one or more levels" or "only lowercase
# letters". These registrations prove every _re() form matches an ERE exactly
# like the old API did, and - because they skip the filter translation - that
# they route without a [filter] annotation.
BEGIN {
    reg_re("^re/(a|b)/two$", "re_alt", "alternation is a regex, not a filter")
    reg_re("^re/ol/[a-z]+$", "re_ol", "a character class is a regex, not a filter")

    changed_re("^re/edge/[0-9]$")
    reg_re("^re/edge/[0-9]$", "re_edge", "echo each changed edge")

    limit_re("^re/lim/[0-9]+$", 60)
    reg_re("^re/lim/[0-9]+$", "re_lim", "echo the messages that survive the limit")

    smooth_re("^re/sm/[0-9]+$", 0.5)
    reg_re("^re/sm/[0-9]+$", "re_sm", "echo the smoothed value")

    json_re("^re/json/(a|b)$", ".value")
    reg_re("^re/json/(a|b)$", "re_json", "echo the extracted value")
}

function re_alt(topic, payload) {
    emit("echo alt " shquote(topic "=" payload))
}

function re_ol(topic, payload) {
    emit("echo ol " shquote(topic "=" payload))
}

function re_edge(topic, payload) {
    emit("echo red " shquote(topic "=" payload))
}

function re_lim(topic, payload) {
    emit("echo rlm " shquote(topic " " payload))
}

function re_sm(topic, payload) {
    emit("echo rsm " shquote(topic " " payload))
}

function re_json(topic, payload) {
    emit("echo rjs " shquote(topic " " payload))
}