#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
container="mactower-mqtt-${PPID}-$$"
wire_log="$(mktemp "${TMPDIR:-/tmp}/mactower-mqtt-wire.XXXXXX")"
capture_pid=""
cleanup() {
    if [[ -n "$capture_pid" ]]; then
        kill "$capture_pid" >/dev/null 2>&1 || true
        wait "$capture_pid" >/dev/null 2>&1 || true
    fi
    docker rm -f "$container" >/dev/null 2>&1 || true
    rm -f "$wire_log"
}
trap cleanup EXIT HUP INT TERM

docker run --rm -d \
    --name "$container" \
    -p 127.0.0.1::1883 \
    -v "$project_root/tests/fixtures/mosquitto.conf:/mosquitto/config/mosquitto.conf:ro" \
    eclipse-mosquitto:2.0 >/dev/null

for _ in {1..30}; do
    if docker exec "$container" mosquitto_pub \
        -h 127.0.0.1 -t mac_tower_test/readiness -m ready >/dev/null 2>&1
    then
        break
    fi
    sleep 1
done

port="$(docker port "$container" 1883/tcp | /usr/bin/awk -F: 'NR == 1 { print $NF }')"
if [[ ! "$port" =~ ^[0-9]+$ ]]; then
    printf 'Unable to determine the Docker MQTT port.\n' >&2
    exit 1
fi

docker exec "$container" mosquitto_sub \
    -h 127.0.0.1 -t 'mac_tower_test/#' -F '%r|%t|%p' >"$wire_log" &
capture_pid=$!

capture_topic="mac_tower_test/wire-capture-ready"
for _ in {1..30}; do
    docker exec "$container" mosquitto_pub \
        -h 127.0.0.1 -t "$capture_topic" -m ready >/dev/null
    if /usr/bin/grep -q "|${capture_topic}|ready$" "$wire_log"; then
        break
    fi
    sleep 0.1
done
if ! /usr/bin/grep -q "|${capture_topic}|ready$" "$wire_log"; then
    printf 'Unable to start the MQTT wire capture.\n' >&2
    exit 1
fi

MACTOWER_MQTT_TEST_PORT="$port" \
    "$project_root/src/scripts/test.sh" --filter MQTTDockerIntegrationTests

payload="$(docker exec "$container" mosquitto_sub \
    -h 127.0.0.1 -t mac_tower_test/integration/state -C 1 -W 5)"
if [[ "$payload" != '{"status":"ok"}' ]]; then
    printf 'Unexpected retained MQTT payload.\n' >&2
    exit 1
fi

for _ in {1..50}; do
    if /usr/bin/grep -Eq '^1\|mac_tower_test/[^/]+/notifications/active/[0-9a-f-]+\|' "$wire_log"; then
        break
    fi
    sleep 0.1
done

active_probe="$(docker exec "$container" mosquitto_sub \
    -h 127.0.0.1 \
    -t 'mac_tower_test/+/notifications/active/+' \
    -C 1 -W 5 -F '%r|%t|%p')"
if [[ ! "$active_probe" =~ ^1\|mac_tower_test/[^/]+/notifications/active/[0-9a-f-]+\|\{ ]]; then
    printf 'Active notification was not available as retained state.\n' >&2
    exit 1
fi

event_count="$(/usr/bin/awk -F'|' \
    '$1 == "0" && $2 ~ "^mac_tower_test/[^/]+/notifications/events$" { count++ } END { print count + 0 }' \
    "$wire_log")"
if [[ "$event_count" -ne 2 ]]; then
    printf 'Retained inbox/ack produced an unexpected outbound event count: %s.\n' \
        "$event_count" >&2
    exit 1
fi
if /usr/bin/awk -F'|' \
    '$1 == "1" && $2 ~ "^mac_tower_test/[^/]+/notifications/events$" { found=1 } END { exit !found }' \
    "$wire_log"
then
    printf 'A notification event was incorrectly published as retained.\n' >&2
    exit 1
fi

if docker exec "$container" mosquitto_sub \
    -h 127.0.0.1 \
    -t 'mac_tower_test/+/notifications/events' \
    -C 1 -W 1 >/dev/null 2>&1
then
    printf 'A fresh subscriber received an old non-retained notification event.\n' >&2
    exit 1
fi

printf 'PASS: MQTTNIO sensor state, fresh sessions, nonreplayed window commands, retained active notifications, live-only events, and retained inbox/ack rejection through Docker Mosquitto.\n'
