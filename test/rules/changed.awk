# test/rules/changed.awk - the rule the changed() case routes through.
#
# changed() drops a repeated payload on a topic before any rule runs; the echo
# makes the surviving edges countable. The state is per exact topic, so edge/x
# and edge/y each keep one.
BEGIN {
    changed("^edge/")
    reg("^edge/", "edge_echo", "echo each changed edge message")
}

function edge_echo(topic, payload) {
    emit("echo edge " shquote(topic "=" payload))
}
