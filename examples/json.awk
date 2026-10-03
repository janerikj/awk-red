# examples/json.awk - a topic that speaks JSON
#
# The payload of a JSON topic is normalised by an adapter before any rule sees
# it, so the handler below is written exactly like a plain-text handler. This
# is what keeps one rule implementation working for both formats:
#
#     home/sensor/json  {"temperature": 33.7, "humidity": 41}
#         -- adapter ".temperature" -->
#     home/sensor/json  33.7
#
# The adapter table is filled in here, next to the rule that owns the topic;
# the coprocess plumbing lives in the engine.

BEGIN {
    adapter("^home/sensor/json$", ".temperature")
    reg("^home/sensor/json$", "json_handler", "alarm from a JSON sensor")
}

function json_handler(topic, payload,    temp) {
    temp = payload + 0

    if (temp > 30)
        pub("alarm/sensor", "json sensor reports " temp "C")

    pub_retained("home/sensor/json/last", temp "C")
}