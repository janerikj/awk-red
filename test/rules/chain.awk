# test/rules/chain.awk - in-process chaining test rule
BEGIN {
    # A JSON reading is split into two internal events, each handled by its
    # own rule. Nothing here publishes: the chained rules do.
    json("^chain/split$", "[.temperature, .humidity] | @tsv")
    reg("^chain/split$", "chain_split", "chain each field to its own topic")
    reg("^chain/temp$", "chain_temp", "echo the chained temperature")
    reg("^chain/hum$", "chain_hum", "echo the chained humidity")

    # A chained event re-enters the pipeline: this rule queues JSON text to a
    # topic that has a json() filter of its own, so the value must be extracted
    # on the way in.
    reg("^chain/num$", "chain_num", "echo the decoded chained value")
    json("^chain/num$", ".value")
    reg("^chain/numsrc$", "chain_numsrc", "chain JSON text to a json() topic")

    # Self-matching on purpose: exercises the hop guard instead of spinning.
    reg("^chain/loop$", "chain_loop", "chain back to itself")
}

function chain_split(topic, payload,    f) {
    split(payload, f, "\t")
    chain("chain/temp", f[1])
    chain("chain/hum", f[2])
}

function chain_temp(topic, payload) {
    emit("echo chained-temp " shquote(payload))
}

function chain_hum(topic, payload) {
    emit("echo chained-hum " shquote(payload))
}

function chain_num(topic, payload) {
    emit("echo chained-num " shquote(payload))
}

function chain_numsrc(topic, payload) {
    chain("chain/num", "{\"value\": " payload "}")
}

function chain_loop(topic, payload) {
    chain("chain/loop", payload)
}
