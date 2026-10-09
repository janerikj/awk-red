# examples/chain.awk - link rules without leaving the process
#
# One reading arrives as JSON with two fields. Instead of publishing each field
# to the broker and waiting for a subscription to bring it back, the rule hands
# them to other rules in-process with chain(). The chained event goes through
# json()/smooth()/limit() and routing exactly like a message from an input, but
# it never reaches the broker - so this works under --input too.
#
# A chained topic still needs a rule, because there is no broker and no retained
# copy to fall back on. Chain when the next step is another rule; publish when
# it has to leave the process.

BEGIN {
    json("^home/reading$", "[.temperature, .humidity] | @tsv")
    reg("^home/reading$", "reading_split", "chain each field to its own topic")

    reg("^home/reading/temperature$", "reading_temp", "alert on the chained temperature")
    reg("^home/reading/humidity$", "reading_humidity", "alert on the chained humidity")
}

function reading_split(topic, payload,    f) {
    split(payload, f, "\t")
    chain("home/reading/temperature", f[1])
    chain("home/reading/humidity", f[2])
}

function reading_temp(topic, payload) {
    if (payload + 0 > 30)
        pub("alarm/reading", "hot: " payload "C")
}

function reading_humidity(topic, payload) {
    if (payload + 0 > 60)
        pub("alarm/reading", "humid: " payload "%")
}
