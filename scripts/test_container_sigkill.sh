#!/usr/bin/env bash
set -euo pipefail

# Run the built add-on through its real s6 entrypoint against a minimal fake
# Supervisor, then kill the complete container during a scheduled window.

readonly IMAGE="${1:-maintenance-window-addon:test}"
TEST_ROOT="$(mktemp -d)"
readonly TEST_ROOT
readonly TEST_ID="${GITHUB_RUN_ID:-local}-$$"
readonly ENABLED_NETWORK="maintenance-window-enabled-${TEST_ID}"
readonly DISABLED_NETWORK="maintenance-window-disabled-${TEST_ID}"
readonly ENABLED_SUPERVISOR="maintenance-window-supervisor-enabled-${TEST_ID}"
readonly DISABLED_SUPERVISOR="maintenance-window-supervisor-disabled-${TEST_ID}"
readonly ENABLED_ADDON="maintenance-window-addon-enabled-${TEST_ID}"
readonly DISABLED_ADDON="maintenance-window-addon-disabled-${TEST_ID}"

cleanup() {
    docker rm --force \
        "${ENABLED_ADDON}" \
        "${DISABLED_ADDON}" \
        "${ENABLED_SUPERVISOR}" \
        "${DISABLED_SUPERVISOR}" \
        > /dev/null 2>&1 || true
    docker network rm "${ENABLED_NETWORK}" "${DISABLED_NETWORK}" > /dev/null 2>&1 || true
    rm -rf "${TEST_ROOT}"
}
trap cleanup EXIT

fail() {
    printf 'FAIL: %s\n' "${1}" >&2
    docker logs "${ENABLED_ADDON}" 2>&1 || true
    docker logs "${DISABLED_ADDON}" 2>&1 || true
    exit 1
}

write_options() {
    local path="${1}"
    local start_time="${2}"

    cat > "${path}" <<JSON
{
  "log_level": "info",
  "dry_run": false,
  "restart_core": false,
  "core_stop_confirmation": "STOP_CORE",
  "startup_grace_seconds": 0,
  "max_core_stop_minutes": 60,
  "min_available_memory_mb": 0,
  "core_start_timeout_seconds": 30,
  "restore_stagger_seconds": 0,
  "pause_core_watchdog": false,
  "list_addons_on_startup": false,
  "never_stop_addons": [],
  "stop_addons": [],
  "start_addons": [],
  "windows": [
    {
      "name": "Container SIGKILL test",
      "start_time": "${start_time}",
      "duration_minutes": 1,
      "restart_core": true
    }
  ]
}
JSON
}

start_supervisor() {
    local name="${1}"
    local network="${2}"
    local state_dir="${3}"
    local watchdog="${4}"

    docker run --detach \
        --name "${name}" \
        --network "${network}" \
        --network-alias supervisor \
        --env STATE_DIR=/state \
        --env ADDON_WATCHDOG="${watchdog}" \
        --volume "${PWD}/scripts/fake_supervisor.py:/fake_supervisor.py:ro" \
        --volume "${state_dir}:/state" \
        python:3.12-alpine \
        python /fake_supervisor.py > /dev/null

    for _ in {1..30}; do
        if docker exec "${name}" python -c \
            'import urllib.request; urllib.request.urlopen("http://127.0.0.1/ready")'; then
            return 0
        fi
        sleep 1
    done

    fail "fake Supervisor '${name}' did not become ready"
}

start_addon() {
    local name="${1}"
    local network="${2}"
    local data_dir="${3}"

    docker run --detach \
        --name "${name}" \
        --network "${network}" \
        --env SUPERVISOR_TOKEN=test-token \
        --env TZ=UTC \
        --volume "${data_dir}:/data" \
        "${IMAGE}" > /dev/null
}

mkdir -p \
    "${TEST_ROOT}/enabled/state" \
    "${TEST_ROOT}/enabled/data" \
    "${TEST_ROOT}/disabled/state" \
    "${TEST_ROOT}/disabled/data"

docker pull --quiet python:3.12-alpine > /dev/null

current_second="$(( 10#$(date -u +%S) ))"
if (( current_second > 45 )); then
    sleep "$(( 61 - current_second ))"
fi
start_time="$(date -u -d '+1 minute' +%H:%M)"
write_options "${TEST_ROOT}/enabled/state/options.json" "${start_time}"
write_options "${TEST_ROOT}/disabled/state/options.json" "${start_time}"

docker network create "${ENABLED_NETWORK}" > /dev/null
docker network create "${DISABLED_NETWORK}" > /dev/null
start_supervisor "${ENABLED_SUPERVISOR}" "${ENABLED_NETWORK}" "${TEST_ROOT}/enabled/state" true
start_supervisor "${DISABLED_SUPERVISOR}" "${DISABLED_NETWORK}" "${TEST_ROOT}/disabled/state" false
start_addon "${ENABLED_ADDON}" "${ENABLED_NETWORK}" "${TEST_ROOT}/enabled/data"
start_addon "${DISABLED_ADDON}" "${DISABLED_NETWORK}" "${TEST_ROOT}/disabled/data"

enabled_window_started="false"
disabled_window_blocked="false"
for _ in {1..100}; do
    if grep --fixed-strings --quiet 'POST /core/stop' "${TEST_ROOT}/enabled/state/actions.log"; then
        enabled_window_started="true"
    fi
    if docker logs "${DISABLED_ADDON}" 2>&1 \
        | grep --fixed-strings --quiet 'Core stop blocked because the Maintenance Window app watchdog is disabled'; then
        disabled_window_blocked="true"
    fi
    if [[ "${enabled_window_started}" == "true" && "${disabled_window_blocked}" == "true" ]]; then
        break
    fi
    sleep 1
done

[[ "${enabled_window_started}" == "true" ]] || fail "watchdog-enabled window did not stop Core"
[[ "${disabled_window_blocked}" == "true" ]] || fail "watchdog-disabled window was not blocked"
[[ "$(< "${TEST_ROOT}/enabled/state/core-state")" == "stopped" ]] || fail "enabled fixture Core is not stopped"
[[ "$(< "${TEST_ROOT}/disabled/state/core-state")" == "running" ]] || fail "disabled fixture stopped Core"

docker kill -s SIGKILL "${ENABLED_ADDON}" "${DISABLED_ADDON}" > /dev/null
docker start "${ENABLED_ADDON}" > /dev/null

enabled_core_recovered="false"
for _ in {1..100}; do
    if [[ "$(< "${TEST_ROOT}/enabled/state/core-state")" == "running" ]]; then
        enabled_core_recovered="true"
        break
    fi
    sleep 1
done

[[ "${enabled_core_recovered}" == "true" ]] || fail "Core did not recover after container SIGKILL"
[[ "$(< "${TEST_ROOT}/enabled/state/core-watchdog")" == "true" ]] || fail "enabled fixture Core watchdog is disabled"
[[ "$(< "${TEST_ROOT}/disabled/state/core-watchdog")" == "true" ]] || fail "disabled fixture Core watchdog is disabled"
[[ "$(< "${TEST_ROOT}/disabled/state/core-state")" == "running" ]] || fail "disabled fixture Core is not running"
[[ ! -f "${TEST_ROOT}/enabled/data/maintenance-window-state.json" ]] || fail "enabled recovery state was not cleared"

if grep --fixed-strings --quiet 'POST /core/options {"watchdog":false}' \
    "${TEST_ROOT}/enabled/state/actions.log" "${TEST_ROOT}/disabled/state/actions.log"; then
    fail "a container disabled the Core watchdog"
fi
if grep --fixed-strings --quiet 'POST /core/stop' "${TEST_ROOT}/disabled/state/actions.log"; then
    fail "watchdog-disabled container stopped Core"
fi

printf 'Container SIGKILL recovery tests passed.\n'