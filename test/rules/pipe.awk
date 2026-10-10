# test/rules/pipe.awk - the rule the --pipe cases route through.
#
# Echoes every message so a case can count deliveries: the examples' temperature
# rule keeps state and would hide a duplicate behind its rising-edge alarm.
BEGIN {
    reg("^pipe/", "pipe_echo", "echo every pipe message")
    reg("^modbus/", "pipe_echo", "echo every Modbus recipe message")
}

function pipe_echo(topic, payload) {
    emit("echo pipe " shquote(topic "=" payload))
}
