# lib/http.awk - HTTP request listener for awk-red
#
# Listens on /inet/tcp/PORT/0/0 (all interfaces), transforms incoming HTTP
# requests into MQTT-style "topic payload" lines on stdout (the awk-red fifo),
# and sends a small HTTP response back to the client. One request per connection.
#
# Contract (minimal, as agreed):
# - Topic: lowercase(method)/<path> where <path> has leading slashes removed.
#   A `topic=` query key overrides that derivation: its urldecoded value is used
#   verbatim as the topic. An override that is empty or contains whitespace is
#   refused with 400 Bad Request, because a space would tear the "topic payload"
#   line, and the derived topic is kept when the key is absent.
# - Payload: an explicit `m=`, `payload=` or `msg=` query key (first match wins),
#   urldecoded; otherwise the request body. A key always wins over the body. An
#   empty value is allowed (`?m=`), a bare topic line, so a request can carry a
#   payload-less event; retention and signals stay the rule's decision.
# - A request with no key and no body is refused with 400: that is what keeps a
#   browser's automatic `GET /favicon.ico` (and `/`) off the broker, especially
#   in --gateway. A body spanning more than one line, or a key whose value
#   decodes to CR or LF, is also refused - the engine carries one message per
#   line, so a newline is a second event, not payload. A body must be one
#   newline-terminated line; a declared but unreadable or multi-line body is
#   refused the same way.
# - Only `topic=`, `m=`, `payload=` and `msg=` query keys are honoured. Other
#   query parameters are ignored. The key set is deliberately small: an alias is
#   added when a real sender hardcodes it, not speculatively.
# - Invalid percent-encodings are skipped / passed through as-is by this minimal
#   decoder.
#
# Examples:
#   POST /door/front?m=open   ->  post/door/front open
#   GET  /temp?m=21.5%20C     ->  get/temp 21.5 C
#   GET  /hook?msg=hello      ->  get/hook hello
#   GET  /hook?topic=a/b&m=x  ->  a/b x
#   GET  /hook?m=             ->  get/hook (explicit empty payload)
#   POST /sensor {"t":21}     ->  post/sensor {"t":21}
#   GET  /favicon.ico         ->  400, no line
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
                # Only a plain integer is a usable length; anything else would
                # reach the ".{N}" body regexp and kill the listener, so it is
                # treated as no body.
                content_len = (h ~ /^[0-9]+$/) ? h + 0 : 0
            }
        }

        # A `topic=` override replaces the derived topic verbatim. It has to be
        # a usable topic: an empty one, or one with whitespace, would tear the
        # "topic payload" line, so it is refused instead of silently mangled.
        bad = ""
        if (query != "") {
            if (match(query, /(^|&)topic=([^&]*)/, args)) {
                override = urldecode(args[2])
                if (override == "" || override ~ /[[:space:]]/)
                    bad = 1
                else
                    topic = override
            }
        }

        # Recognised payload keys, first match wins (m, then payload, then msg).
        # A key always wins over the body; an empty value is an explicit empty
        # payload, not "no payload". Kept deliberately small; form-encoded
        # bodies are not decoded.
        payload = ""
        have_payload = 0
        if (query != "") {
            if (match(query, /(^|&)m=([^&]*)/, args)) {
                payload = urldecode(args[2])
                have_payload = 1
            } else if (match(query, /(^|&)payload=([^&]*)/, args)) {
                payload = urldecode(args[2])
                have_payload = 1
            } else if (match(query, /(^|&)msg=([^&]*)/, args)) {
                payload = urldecode(args[2])
                have_payload = 1
            }
        }

        # A newline in a value is a second engine line, not payload: refuse it
        # the same way a whitespace topic is refused.
        if (have_payload && payload ~ /[\r\n]/)
            bad = 1

        # Otherwise a single-line body is the payload. gawk reads by RS, so the
        # body must be one newline-terminated line; RT is the matched separator,
        # which tells a real terminator from a read that merely timed out. On
        # timeout gawk still hands back the bytes it has, so RT is the only
        # reliable signal that the line really ended. Content-Length then says
        # whether that one line was the whole body, otherwise it is refused
        # rather than silently truncated.
        if (!bad && !have_payload && content_len > 0) {
            if ((service |& getline body) > 0 && RT == "\n") {
                body_len = length(body)
                sub(/\r$/, "", body)
                if (content_len > body_len + 1)
                    bad = 1
                else {
                    payload = body
                    have_payload = 1
                }
            } else {
                bad = 1
            }
        }

        # No key and no body is not an event: it is what a browser's automatic
        # /favicon.ico (and /) look like, so it must not reach the broker.
        if (bad || !have_payload) {
            resp = "HTTP/1.1 400 Bad Request\r\nContent-Type: text/plain\r\nContent-Length: 5\r\nConnection: close\r\n\r\nBad\n"
            print resp |& service
            close(service)
            continue
        }

        resp = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 3\r\nConnection: close\r\n\r\nOK\n"
        print resp |& service
        close(service)

        print topic (payload == "" ? "" : " ") payload
        fflush("")
    }
}
