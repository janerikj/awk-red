# lib/http.awk - HTTP request listener for awk-red
#
# Listens on /inet/tcp/PORT/0/0 (all interfaces), transforms incoming HTTP
# requests into MQTT-style "topic payload" lines on stdout (the awk-red fifo),
# and sends a small HTTP response back to the client. One request per connection.
#
# Contract (minimal, as agreed):
# - Topic: lowercase(method)/<path> where <path> has leading slashes removed
# - Payload: use `p=` or `payload=` from the query if present; if not present,
#   use the request body as a single line (multi-line bodies are truncated to
#   the first line read: the implementation reads at most one line of body).
#   Payload strings are urldecoded for `p=`/`payload=`.
# - Only `p=` and `payload=` query keys are honoured. Other query parameters are
#   ignored.
# - Invalid percent-encodings are skipped / passed through as-is by this minimal
#   decoder.
#
# Examples:
#   POST /door/front?p=open  ->  post/door/front open
#   GET  /temp?p=21.5%20C    ->  get/temp 21.5 C
#   POST /sensor {"t":21}    ->  post/sensor {"t":21}
#   DELETE /nopay           ->  delete/nopay (empty payload)
#
# Limitations (gawk's /inet/tcp is not a real web server):
# - One connection at a time. gawk closes the listening socket right after
#   accept() and reopens it only after the response has been written, so a
#   connection that arrives while a request is being processed is refused by
#   the kernel. Clients should send requests one at a time and retry on
#   ECONNREFUSED. listen() backlog is 1, so even sequential-but-simultaneous
#   connections are mostly refused.
# - A client that connects and never finishes a request line is dropped after
#   PROCINFO["READ_TIMEOUT"] (1500 ms) and the listener recovers. Blocking in
#   accept() itself has no timeout: no client ever arriving is harmless.
# - Bind failures are fatal: gawk reports them on the first getline with
#   ERRNO="Address already in use" rather than at open().

function urldecode(str,    s, hex, i, c, n) {
    s = ""
    gsub(/\+/, " ", str)
    i = 1
    while (i <= length(str)) {
        c = substr(str, i, 1)
        if (c == "%") {
            if (i + 2 <= length(str)) {
                hex = substr(str, i + 1, 2)
                n = strtonum("0x" hex)
                if (n >= 0) {
                    s = s sprintf("%c", n)
                    i += 3
                    continue
                }
            }
            s = s c
            i++
        } else {
            s = s c
            i++
        }
    }
    return s
}

BEGIN {
    if (!PORT || PORT + 0 <= 0) {
        print "awk-red: lib/http.awk requires -v PORT=<port>" > "/dev/stderr"
        exit 1
    }

    service = "/inet/tcp/" PORT "/0/0"
    PROCINFO[service, "READ_TIMEOUT"] = 1500
    RS = "\n"

    while (1) {
        res = (service |& getline req)
        if (res <= 0) {
            if (ERRNO ~ /already in use/) {
                printf "awk-red: cannot listen on port %d: %s\n", PORT, ERRNO > "/dev/stderr"
                exit 1
            }
            close(service)
            continue
        }

        sub(/\r$/, "", req)
        split(req, parts, " ")
        method = tolower(parts[1])
        uri = parts[2]

        if (method == "" || uri == "") {
            resp = "HTTP/1.1 400 Bad Request\r\nContent-Type: text/plain\r\nContent-Length: 5\r\nConnection: close\r\n\r\nBad\n"
            print resp |& service
            close(service)
            continue
        }

        q = index(uri, "?")
        if (q > 0) {
            path = substr(uri, 1, q - 1)
            query = substr(uri, q + 1)
        } else {
            path = uri
            query = ""
        }
        sub(/^\/+/, "", path)
        topic = method "/" path

        content_len = 0
        while ((service |& getline h) > 0) {
            sub(/\r$/, "", h)
            if (h == "")
                break
            if (tolower(h) ~ /^content-length:/) {
                sub(/^[^:]+:[ \t]*/, "", h)
                gsub(/^[ \t]+|[ \t]+$/, "", h)
                content_len = h + 0
            }
        }

        payload = ""
        if (query != "") {
            if (match(query, /(^|&)p=([^&]*)/, m)) {
                payload = urldecode(m[2])
            } else if (match(query, /(^|&)payload=([^&]*)/, m)) {
                payload = urldecode(m[2])
            }
        }

        if (payload == "" && content_len > 0) {
            if ((service |& getline body) > 0) {
                sub(/\r$/, "", body)
                payload = body
            }
        }

        resp = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 3\r\nConnection: close\r\n\r\nOK\n"
        print resp |& service
        close(service)

        print topic (payload == "" ? "" : " ") payload
        fflush("")
    }
}
