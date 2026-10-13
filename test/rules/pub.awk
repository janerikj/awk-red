# test/rules/pub.awk - the rule the publish-broker cases route through.
#
# It calls both publishers so one message exercises pub() and pub_retained(),
# and a case can inspect the mosquitto_pub command line dry-run prints.
BEGIN {
    reg("pub/all", "pub_all", "publish plain and retained for the broker test")
}

function pub_all(topic, payload) {
    pub("pub/out", payload)
    pub_retained("pub/out", payload)
}
