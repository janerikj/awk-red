# examples/json.awk - a topic that speaks JSON
#
# The payload of a JSON topic is extracted by json() before any rule sees
# it, so the handler below is written exactly like a plain-text handler. This
# is what keeps one rule implementation working for both formats:
#
#     home/sensor/json  {"temperature": 33.7, "humidity": 41}
#         -- json() ".temperature" -->
#     home/sensor/json  33.7
#
# The json() table is filled in here, next to the rule that owns the topic;
# the coprocess plumbing lives in the engine.

BEGIN {
    json("^home/sensor/json$", ".temperature")
    reg("^home/sensor/json$", "json_handler", "alarm from a JSON sensor")
}

function json_handler(topic, payload,    temp) {
    temp = payload + 0

    if (temp > 30)
        pub("alarm/sensor", "json sensor reports " temp "C")

    pub_retained("home/sensor/json/last", temp "C")
}
