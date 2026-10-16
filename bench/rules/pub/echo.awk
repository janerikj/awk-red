# Benchmark rule: publish every matched message to BENCH_OUT with pub(), the
# way a real rule would. One mosquitto_pub process and one broker connection per
# message, which is exactly the cost this stage is meant to expose.
BEGIN {
    IN  = getenv("BENCH_IN", "awk-red-bench/in")
    OUT = getenv("BENCH_OUT", "awk-red-bench/out")
    reg(IN, "bench_echo", "benchmark publisher")
}

function bench_echo(topic, payload) {
    pub(OUT, payload)
}
