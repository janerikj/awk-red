# examples/door.awk - door state changes
#
# Shows the retained flag: the last state stays on the broker, so a dashboard
# that subscribes to home/door gets the current value immediately.

BEGIN {
    reg("^home/door$", "door_handler", "publish every door state change")
}

function door_handler(topic, payload,    state) {
    state = payload

    if (state != "open" && state != "closed")
        return debug("ignoring unknown door state: " state)

    if (state == DOOR)
        return debug("door already " state)

    DOOR = state
    pub_retained("home/door/state", state)

    # emit() runs any command; here the system logger.
    emit("logger -t awk-red -p daemon.info 'door is now " state "'")
}