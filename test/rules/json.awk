# test/rules/json.awk - JSON extraction and split test rule
BEGIN {
    json("^json/", ".temperature")
    reg("^json/", "json_handler", "echo the extracted value")

    # The README recipe: one message, both fields on one line, the rule
    # publishes each field to its own topic.
    json("^split/", "[.temperature, .humidity] | @tsv")
    reg("^split/", "split_handler", "publish each field to its own topic")
}

function json_handler(topic, payload) {
    emit("echo extracted " shquote(payload))
}

function split_handler(topic, payload,    f) {
    split(payload, f, "\t")
    pub(topic "/temperature", f[1])
    pub(topic "/humidity", f[2])
}
