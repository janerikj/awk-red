# test/rules/mqtt.awk - the MQTT topic filter cases route through here.
#
# Each registration uses an MQTT topic filter and the echo makes the match
# countable. The mqtt/ namespace keeps these topics clear of the other rules.
BEGIN {
    reg("mqtt/+/temp", "plus_echo", "one level with +")
    reg("mqtt/tree/#", "hash_echo", "the rest with #, parent included")
    reg("mqtt/lit/v1.0/+", "lit_echo", "a literal dot is not a regex wildcard")
}

function plus_echo(topic, payload) {
    emit("echo plus " shquote(topic "=" payload))
}

function hash_echo(topic, payload) {
    emit("echo hash " shquote(topic "=" payload))
}

function lit_echo(topic, payload) {
    emit("echo lit " shquote(topic "=" payload))
}
