# examples/heartbeat.awk - scheduled work and a heartbeat
#
# With --tick SECONDS (or AWKRED_TICK) awk-red injects a message on a fixed
# interval, so rules keep running even when the broker is completely silent:
#
#     awk-red/tick/2026-10-03T11:22:33Z 1756899753
#
#     topic    the ISO-8601 UTC timestamp
#     payload  seconds since the epoch, ready for arithmetic with systime()
#
# The clock lives in the shell script, not here: gawk has no timers and no
# concurrency, so nothing inside the router can fire while input is idle.

BEGIN {
    reg("^awk-red/tick(/|$)", "tick_handler", "heartbeat and scheduled work")
}

function tick_handler(topic, payload,    iso) {
    iso = topic
    sub(/^awk-red\/tick\//, "", iso)

    debug("tick at " iso " (epoch " payload ")")

    # Periodic work goes here: prune old state, poll something slow, publish a
    # summary of the last interval. Everything the tick arrives in is normal
    # router state, for example the HOT array kept by temp.awk.
    pub("awk-red/heartbeat/" iso, payload)
}

# Do not publish to ^awk-red/tick/ from here. With the default subscription the
# router receives its own messages back, and a rule that writes to the topic it
# matches re-triggers itself once per interval, forever. Publishing to a
# different topic, as above, is what keeps the loop closed exactly once.
#
# A tick also proves nothing about awk-red itself: a heartbeat consumed by the
# router cannot report that the router died. If something outside needs that,
# publish a separate topic from a systemd timer.