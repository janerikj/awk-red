# test/rules/webhook.awk - webhook test rule
BEGIN {
    reg("^get/hook/", "hook_handler", "webhook echo for tests")
}

function hook_handler(topic, payload) {
    emit("echo hook " shquote(payload))
}
