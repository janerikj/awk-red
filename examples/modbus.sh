#!/usr/bin/env bash
# examples/modbus.sh - Modbus/TCP -> awk-red recipe.
#
# Reads a register map and, for each row, runs one mbpoll read, then prints the
# values as awk-red "topic payload" lines. mbpoll reads one register type per
# invocation (each type is a different Modbus function code), so the map's type
# column decides the -t argument and rows of different types are simply separate
# invocations - Modbus has no single request that spans them.
#
#   usage: modbus.sh [-?|--help] HOST [MAP]
#
# mbpoll is not a dependency of awk-red, only of this recipe:
#     sudo apt install mbpoll          # or build github.com/epsilonrt/mbpoll
#
# Run it as a poll, and let --changed turn a re-read value into an event:
#     awk-red --pipe './examples/modbus.sh 10.0.0.5' --every 5 --changed
#
# Map columns (whitespace separated, '#' comments):
#
#   slave  type      addr  count  fmt     topic
#
#   type   coil (0x) | discrete (1x) | input (3x) | holding (4x)
#   fmt    -, int16, hex, string, int or float (- for the bit types)
#   topic  base topic; with count > 1 each value becomes topic/<ref>
#
# The host is an argument, not a map column, because every row reads the same
# device. MODBUS_HOST, MODBUS_PORT (default 502) and MODBUS_MAP set the
# defaults; MBPOLL overrides the binary, which is how the test suite swaps in a
# stand-in.
set -uo pipefail

here=$(dirname -- "${BASH_SOURCE[0]}")

usage() {
    cat <<EOF
modbus.sh - Modbus/TCP -> awk-red recipe

usage: modbus.sh [-?|--help] HOST [MAP]

Runs one mbpoll read per map row and prints the values as awk-red
"topic payload" lines, ready for a poll:

    awk-red --pipe './examples/modbus.sh HOST' --every 5 --changed

HOST   Modbus/TCP device (or MODBUS_HOST)
MAP    register map (or MODBUS_MAP), default $here/modbus.map
       columns: slave type addr count fmt topic
       type: coil (0x) | discrete (1x) | input (3x) | holding (4x)
       fmt:  - | int16 | hex | string | int | float

MODBUS_PORT  TCP port (default 502)
MBPOLL       mbpoll binary to run, not an awk-red dependency

  -?, --help   show this help and exit
EOF
}

posargs=()
while (( $# )); do
    case $1 in
        -\?|--help) usage; exit 0 ;;
        -*) printf 'modbus.sh: unknown option: %s\n' "$1" >&2; exit 2 ;;
        *) posargs+=("$1"); shift ;;
    esac
done

host=${posargs[0]:-${MODBUS_HOST:-}}
map=${posargs[1]:-${MODBUS_MAP:-$here/modbus.map}}
port=${MODBUS_PORT:-502}
mbpoll=${MBPOLL:-mbpoll}

[[ -n $host ]] || { printf 'modbus.sh: need HOST (or MODBUS_HOST)\n' >&2; exit 2; }
[[ -r $map ]] || { printf 'modbus.sh: map not readable: %s\n' "$map" >&2; exit 2; }
command -v "$mbpoll" >/dev/null 2>&1 ||
    { printf 'modbus.sh: mbpoll not found (sudo apt install mbpoll)\n' >&2; exit 1; }

mbtype() {
    case $1 in
        coil)     printf '0' ;;
        discrete) printf '1' ;;
        input)    printf '3' ;;
        holding)  printf '4' ;;
        *)        return 1 ;;
    esac
}

while read -r slave type addr count fmt topic; do
    [[ -n ${slave:-} && $slave != \#* ]] || continue
    t=$(mbtype "$type") ||
        { printf 'modbus.sh: unknown type: %s\n' "$type" >&2; continue; }
    [[ $count =~ ^[0-9]+$ ]] || count=1

    tspec=$t
    [[ -n ${fmt:-} && $fmt != - ]] && tspec="$t:$fmt"
    args=(-m tcp -p "$port" -a "$slave" -t "$tspec" -r "$addr" -c "$count" -1)

    # A row that times out is skipped, not fatal: the next poll retries it.
    out=$("$mbpoll" "${args[@]}" "$host" 2>/dev/null) || {
        printf 'modbus.sh: read failed: slave %s %s @%s\n' "$slave" "$type" "$addr" >&2
        continue
    }

    printf '%s\n' "$out" | gawk -v topic="$topic" -v count="$count" '
        match($0, /^\[([0-9A-Fa-f]+)\]:[ \t]*(.*)/, m) {
            val = m[2]
            sub(/[ \t]+$/, "", val)
            if (count + 0 > 1)
                printf "%s/%s %s\n", topic, m[1], val
            else
                printf "%s %s\n", topic, val
            fflush("")
        }'
done < "$map"
