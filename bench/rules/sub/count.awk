# Benchmark rule: count the matched messages, timestamp the first and the last
# with a shell clock, and exit so an --mqtt run ends after BENCH_N messages
# instead of sitting on the subscription for ever.
#
# The two timestamps bracket the steady-state transport: message #1 has already
# crossed the broker, mosquitto_sub, the fifo and the pipeline by the time it is
# marked, and so has #N. The fork cost of the two `date` calls is symmetric, so
# it largely cancels in the span.
#
# Names avoid the engine's globals (N is the rule count, MSGS the message
# count): a benchmark rule shares the gawk program with router.awk.
BEGIN {
    IN    = getenv("BENCH_IN", "awk-red-bench/in")
    TOTAL = getenv("BENCH_N", "100") + 0
    MARK  = getenv("BENCH_MARKER", "/tmp/awk-red-bench")
    SEEN  = 0
    reg(IN, "bench_count", "benchmark message counter")
}

function bench_count(topic, payload) {
    SEEN++
    if (SEEN == 1)
        system("date +%s.%N > " shquote(MARK ".first"))
    if (SEEN >= TOTAL) {
        system("date +%s.%N > " shquote(MARK ".last"))
        exit
    }
}
