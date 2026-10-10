# Examples

This directory is the default rule directory (`-r examples`), so the bundled
rules work out of the box and double as a starting point for your own.

```shell
./awk-red -l                        # what is in here
./awk-red -n -i messages.log       # dry run against the recording
./awk-red -v -i messages.log       # the same, with routing decisions logged
./awk-red --tick 2                 # the clock alone, no broker needed
./awk-red -n --mqtt -h mqtt.local  # live, dry run against a real broker
./awk-red --mqtt -h mqtt.local --tick 2   # live, with a clock every 2 s
```

| File | Shows |
| --- | --- |
| `temp.awk` | state between messages: alerts on the rising edge, not on every reading |
| `door.awk` | state changes, retained messages, `emit()` for an arbitrary command |
| `json.awk` | a JSON topic extracted by `json()`, so the handler sees plain text |
| `chain.awk` | one reading split into internal events with `chain()`, handled by other rules |
| `heartbeat.awk` | scheduled work from the built-in clock, publishing a heartbeat topic |
| `modbus.sh` | a `--pipe` poll: one register read per row of `modbus.map`, printed as topics |
| `modbus.map` | the register map (`slave type addr count fmt topic`) the recipe reads |
| `messages.log` | a recorded `mosquitto_sub -v` stream used by `--input` |

Point a real broker at them and publish:

```shell
mosquitto_pub -t home/kitchen/temp -m 33.5
mosquitto_pub -t home/door -m open
mosquitto_pub -t home/sensor/json -m '{"temperature": 31.2, "humidity": 44}'
```

Without `--dry-run` the actions run for real: they publish back to the broker
and hand the door state to `logger`.

## `heartbeat.awk`

Runs on the clock from `--tick` / `AWKRED_TICK` instead of on broker traffic,
which is the only way to get periodic work out of a router that also has to stay
quiet while nothing happens. The rule can be tested offline, because a tick is
just a line in a recording:

```shell
echo 'awk-red/tick/2026-10-03T11:22:33Z 1756899753' | ./awk-red -n -q -i -
```

## `modbus.sh`

A `--pipe` recipe that turns a Modbus/TCP device into topics: for each row of
`modbus.map` it runs one `mbpoll` read and prints the value as `topic payload`.
Different register types need different reads, so the map's `type` column picks
the Modbus function code.

```shell
awk-red --pipe './examples/modbus.sh 10.0.0.5' --every 5 --changed
```

It needs `mbpoll` (not an awk-red dependency): `sudo apt install mbpoll`.
`MODBUS_HOST`, `MODBUS_PORT` (default 502) and `MODBUS_MAP` set the defaults.
`./examples/modbus.sh --help` (or `-?`) explains the map columns and options.

## `messages.log`

Exactly what `mosquitto_sub -v` prints, one `topic payload` per line. Record
your own with:

```shell
mosquitto_sub -v -t '#' | tee my.log
./awk-red -n -i my.log
```

## `awk-red.service`

A systemd unit. It assumes the script in `/usr/local/bin/awk-red`, rules in
`/etc/awk-red/rules` and configuration in `/etc/awk-red/.env`. See the
deployment section in [../README.md](../README.md).

## Your own rules

Copy the directory, delete what you do not need and keep what you do:

```shell
cp -r examples ~/rules && rm ~/rules/json.awk
$EDITOR ~/rules/door.awk
./awk-red -r ~/rules -n -i ~/rules/recording.log
```