#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
container="mactower-mqtt-${PPID}-$$"
cleanup() {
    docker rm -f "$container" >/dev/null 2>&1 || true
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

MACTOWER_MQTT_TEST_PORT="$port" \
    "$project_root/src/scripts/test.sh" --filter mqttDockerRoundTrip

payload="$(docker exec "$container" mosquitto_sub \
    -h 127.0.0.1 -t mac_tower_test/integration/state -C 1 -W 5)"
if [[ "$payload" != '{"status":"ok"}' ]]; then
    printf 'Unexpected retained MQTT payload.\n' >&2
    exit 1
fi

printf 'PASS: MQTTNIO retained round trip through Docker Mosquitto.\n'
