# examples/mqtt.awk - register rules with an MQTT topic filter
#
# reg() takes the topic filter you would hand to mosquitto_sub, wildcards and
# all, and rewrites it to a regex once at start-up:
#
#   +   one topic level        home/+/motion
#   #   the rest of the topic  device/#
#
# The translation happens in BEGIN, so after start-up this is an ordinary rule:
# it matches no slower than the regex you would have written by hand. For a
# pattern a filter cannot express, reach for reg_re() and a regex.

BEGIN {
    # + matches exactly one level, so home/hall/motion matches but
    # home/hall/upstairs/motion does not.
    reg("home/+/motion", "motion_handler", "motion in any single room")

    # # matches the rest of the topic, including the parent device itself, so
    # every message below device/ reaches one handler.
    reg("device/#", "device_handler", "log everything below device/")
}

function motion_handler(topic, payload,    room) {
    if (payload != "on")
        return

    room = topic
    sub(/^home\//, "", room)
    sub(/\/motion$/, "", room)
    pub("alarm/motion/" room, "motion in " room)
}

function device_handler(topic, payload) {
    pub("device/log", topic " = " payload)
}
