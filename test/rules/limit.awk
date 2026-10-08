# test/rules/limit.awk - rate-limit test rule
BEGIN {
    limit("^noise/", 60)
    reg("^noise/", "noise_handler", "echo the messages that survive the limit")
}

function noise_handler(topic, payload) {
    emit("echo limited " shquote(topic " " payload))
}
