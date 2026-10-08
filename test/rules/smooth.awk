# test/rules/smooth.awk - smoothing test rule
BEGIN {
    smooth("^smooth/", 0.5)
    reg("^smooth/", "smooth_handler", "echo the smoothed value")

    # json() feeds the smoother: on this topic the average is over the
    # extracted number, not over the JSON text. The handler is already
    # reached through ^smooth/.
    json("^smooth/json$", ".temperature")

    # The ordering proof: throttle/ is both smoothed and limited. With a 60 s
    # window and AWKRED_TEST_STEP=40 the second message lands inside the
    # window and the third outside it, so a case can watch the average move on
    # a message the limiter drops - without sleeping.
    smooth("^throttle/", 0.5)
    limit("^throttle/", 60)
    reg("^throttle/", "throttle_handler", "echo the value that survives")
}

function smooth_handler(topic, payload) {
    emit("echo smoothed " shquote(topic " " payload))
}

function throttle_handler(topic, payload) {
    emit("echo smoothed " shquote(topic " " payload))
}
