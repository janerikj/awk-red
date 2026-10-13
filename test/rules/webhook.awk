# test/rules/webhook.awk - webhook test rule
BEGIN {
    reg("get/hook/#", "hook_handler", "webhook echo for tests")
    reg("post/hook/#", "hook_handler", "webhook POST body echo for tests")
}

function hook_handler(topic, payload) {
    emit("echo hook " shquote(payload))
}

BEGIN {
    reg("custom/#", "custom_handler", "topic override echo for tests")
}

function custom_handler(topic, payload) {
    emit("echo custom " shquote(payload))
}
