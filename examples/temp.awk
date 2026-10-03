# examples/temp.awk - temperature alarm with state
#
# A rule file registers a topic pattern and implements one handler. Nothing
# else: no configuration, no system() calls, no knowledge of the broker.
#
# Registered patterns are tried in load order, and every match runs.

BEGIN {
    reg("^home/(.*)/temp$", "temp_handler", "alarm when a room gets too hot")
}

# The handler gets the topic and the payload, not $0, so a payload with spaces
# stays intact. AWK arrays keep state between messages - here: "already
# reported hot", so we alert on the rising edge only and not ten times a
# minute.
function temp_handler(topic, payload,    room, temp, key) {
    room = topic
    sub(/^home\//, "", room)
    sub(/\/temp$/, "", room)

    temp = payload + 0          # payload is a string; + 0 makes it numeric
    key = "hot:" room

    if (temp > 30) {
        if (!(key in HOT)) {
            HOT[key] = 1
            pub("alarm/temp/" room, "hot: " temp "C in " room)
            pub_retained("home/" room "/temp_alarm", "1")
        } else {
            debug(room " is still hot (" temp "C), no new alarm")
        }
    } else if (key in HOT) {
        delete HOT[key]
        pub("alarm/temp/" room, "back to normal: " temp "C in " room)
        pub_retained("home/" room "/temp_alarm", "0")
    }
}