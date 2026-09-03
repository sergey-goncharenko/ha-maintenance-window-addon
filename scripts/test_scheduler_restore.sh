#!/usr/bin/env bash
set -euo pipefail

# shellcheck shell=bash

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
REPOSITORY_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
readonly REPOSITORY_ROOT
TEST_ROOT="$(mktemp -d)"
readonly TEST_ROOT
export WINDOW_STATE_FILE="${TEST_ROOT}/window-state.json"
export MEMINFO_FILE="${TEST_ROOT}/meminfo"

trap 'rm -rf "${TEST_ROOT}"' EXIT

# shellcheck source=../maintenance_window/rootfs/usr/lib/maintenance-window/scheduler.sh
# shellcheck disable=SC1091
source "${REPOSITORY_ROOT}/maintenance_window/rootfs/usr/lib/maintenance-window/scheduler.sh"

# jq.exe emits CRLF under Git Bash; the add-on's Linux jq emits LF.
jq() {
    command jq "$@" | tr -d '\r'
}

readonly ACTION_LOG="${TEST_ROOT}/actions.log"
readonly TEST_LOG="${TEST_ROOT}/scheduler.log"
readonly CORE_STATE_FILE="${TEST_ROOT}/core-state"
readonly WATCHDOG_STATE_FILE="${TEST_ROOT}/watchdog-state"
readonly FAIL_ONCE_MARKER="${TEST_ROOT}/fail-once"

DRY_RUN="false"
FAIL_START_SLUG_ONCE=""
ALWAYS_FAIL_START_SLUG=""
RESTORE_STAGGER_SECONDS="0"
FAIL_STATE_UPDATES="false"
ADDON_WATCHDOG_STATE="true"
WINDOW_RESTART_CORE="false"
STOP_ADDONS=""
START_ADDONS=""
NEVER_STOP_ADDONS=""
BLOCK_WINDOW_WAIT="false"
WINDOW_WAIT_MARKER=""
MIN_AVAILABLE_MEMORY_MB="256"
PAUSE_CORE_WATCHDOG="false"

fail() {
    printf 'FAIL: %s\n' "${1}" >&2
    exit 1
}

assert_equals() {
    local expected="${1}"
    local actual="${2}"
    local message="${3}"

    if [[ "${actual}" != "${expected}" ]]; then
        fail "${message}: expected '${expected}', got '${actual}'"
    fi
}

assert_state_cleared() {
    [[ ! -f "${WINDOW_STATE_FILE}" ]] || fail "recovery state was not cleared"
}

assert_no_action() {
    local action="${1}"

    if grep --fixed-strings --quiet -- "${action}" "${ACTION_LOG}"; then
        fail "unexpected Supervisor action: ${action}"
    fi
}

addon_state_file() {
    local slug="${1}"

    printf '%s/addon-%s\n' "${TEST_ROOT}" "${slug//\//_}"
}

set_addon_state() {
    local slug="${1}"
    local state="${2}"

    printf '%s\n' "${state}" > "$(addon_state_file "${slug}")"
}

get_addon_state() {
    local slug="${1}"
    local state_file

    state_file="$(addon_state_file "${slug}")"
    printf '%s\n' "$(< "${state_file}")"
}

reset_fixture() {
    rm -f "${WINDOW_STATE_FILE}" "${FAIL_ONCE_MARKER}" "${TEST_ROOT}"/addon-*
    : > "${ACTION_LOG}"
    : > "${TEST_LOG}"
    printf 'running\n' > "${CORE_STATE_FILE}"
    printf 'true\n' > "${WATCHDOG_STATE_FILE}"
    printf 'MemAvailable:    1048576 kB\n' > "${MEMINFO_FILE}"
    DRY_RUN="false"
    FAIL_START_SLUG_ONCE=""
    ALWAYS_FAIL_START_SLUG=""
    RESTORE_STAGGER_SECONDS="0"
    FAIL_STATE_UPDATES="false"
    ADDON_WATCHDOG_STATE="true"
    WINDOW_RESTART_CORE="false"
    STOP_ADDONS=""
    START_ADDONS=""
    NEVER_STOP_ADDONS=""
    BLOCK_WINDOW_WAIT="false"
    WINDOW_WAIT_MARKER=""
    MIN_AVAILABLE_MEMORY_MB="256"
    PAUSE_CORE_WATCHDOG="false"
}

write_state() {
    local window_end_epoch="${1}"
    local restart_core="${2}"
    local core_watchdog_restore="${3}"
    local addons_to_restart="${4}"
    local temporary_addons_to_stop="${5}"
    local attempts="${6:-0}"

    jq --null-input \
        --argjson window_end_epoch "${window_end_epoch}" \
        --argjson restart_core "${restart_core}" \
        --argjson core_watchdog_restore "${core_watchdog_restore}" \
        --argjson addons_to_restart "${addons_to_restart}" \
        --argjson temporary_addons_to_stop "${temporary_addons_to_stop}" \
        --argjson attempts "${attempts}" \
        '{window_end_epoch: $window_end_epoch, attempts: $attempts, window_name: "test window", restart_core: $restart_core, core_watchdog_restore: $core_watchdog_restore, addons_to_restart: $addons_to_restart, temporary_addons_to_stop: $temporary_addons_to_stop}' \
        > "${WINDOW_STATE_FILE}"
}

function bashio::config.true {
    case "${1}" in
        dry_run) [[ "${DRY_RUN}" == "true" ]] ;;
        pause_core_watchdog) [[ "${PAUSE_CORE_WATCHDOG}" == "true" ]] ;;
        *) return 1 ;;
    esac
}

function bashio::config {
    local key="${1}"
    local default_value="${2:-}"

    case "${key}" in
        core_start_timeout_seconds) printf '60\n' ;;
        restore_stagger_seconds) printf '%s\n' "${RESTORE_STAGGER_SECONDS}" ;;
        startup_grace_seconds) printf '0\n' ;;
        max_core_stop_minutes) printf '60\n' ;;
        min_available_memory_mb) printf '%s\n' "${MIN_AVAILABLE_MEMORY_MB}" ;;
        core_stop_confirmation) printf 'STOP_CORE\n' ;;
        windows\[0\].restart_core) printf '%s\n' "${WINDOW_RESTART_CORE}" ;;
        windows\[0\].stop_addons|windows\[0\].start_addons) printf '__missing__\n' ;;
        stop_addons) printf '%s' "${STOP_ADDONS}" ;;
        start_addons) printf '%s' "${START_ADDONS}" ;;
        never_stop_addons) printf '%s' "${NEVER_STOP_ADDONS}" ;;
        *) printf '%s\n' "${default_value}" ;;
    esac
}

log_message() {
    local level="${1}"
    shift

    printf '%s: %s\n' "${level}" "$*" >> "${TEST_LOG}"
}

function bashio::log.info { log_message INFO "$@"; }
function bashio::log.notice { log_message NOTICE "$@"; }
function bashio::log.warning { log_message WARNING "$@"; }
function bashio::log.error { log_message ERROR "$@"; }

sleep() {
    printf 'SLEEP %s\n' "${1}" >> "${ACTION_LOG}"
    return 0
}

eval "$(declare -f wait_until_epoch | sed '1s/wait_until_epoch/wait_until_epoch_real/')"
wait_until_epoch() {
    if [[ "${BLOCK_WINDOW_WAIT}" == "true" ]]; then
        : > "${WINDOW_WAIT_MARKER}"
        while true; do
            command sleep 1
        done
    fi

    wait_until_epoch_real "$@"
}

supervisor_api() {
    local method="${1}"
    local path="${2}"
    local slug
    local state_file

    case "${method} ${path}" in
        "GET /addons/self/info")
            printf '{"data":{"state":"started","watchdog":%s}}\n' "${ADDON_WATCHDOG_STATE}"
            return 0
            ;;
        "GET /core/info")
            printf '{"data":{"state":"%s","watchdog":%s}}\n' \
                "$(< "${CORE_STATE_FILE}")" "$(< "${WATCHDOG_STATE_FILE}")"
            return 0
            ;;
        "POST /core/start")
            printf '%s\n' "${method} ${path}" >> "${ACTION_LOG}"
            printf 'running\n' > "${CORE_STATE_FILE}"
            return 0
            ;;
        "POST /core/stop")
            printf '%s\n' "${method} ${path}" >> "${ACTION_LOG}"
            printf 'stopped\n' > "${CORE_STATE_FILE}"
            return 0
            ;;
    esac

    if [[ "${path}" =~ ^/addons/([^/]+)/(info|start|stop)$ ]]; then
        slug="${BASH_REMATCH[1]}"
        state_file="$(addon_state_file "${slug}")"
        case "${method} ${BASH_REMATCH[2]}" in
            "GET info")
                printf '{"data":{"state":"%s"}}\n' "$(< "${state_file}")"
                ;;
            "POST start")
                printf '%s\n' "${method} ${path}" >> "${ACTION_LOG}"
                printf 'started\n' > "${state_file}"
                ;;
            "POST stop")
                printf '%s\n' "${method} ${path}" >> "${ACTION_LOG}"
                printf 'stopped\n' > "${state_file}"
                ;;
            *)
                return 1
                ;;
        esac
        return 0
    fi

    return 1
}

supervisor_api_json() {
    local method="${1}"
    local path="${2}"
    local payload="${3}"

    printf '%s %s %s\n' "${method}" "${path}" "${payload}" >> "${ACTION_LOG}"
    if [[ "${payload}" == *true* ]]; then
        printf 'true\n' > "${WATCHDOG_STATE_FILE}"
    else
        printf 'false\n' > "${WATCHDOG_STATE_FILE}"
    fi
}

homeassistant_api() {
    [[ "$(< "${CORE_STATE_FILE}")" == "running" ]]
}

eval "$(declare -f restore_start_addon | sed '1s/restore_start_addon/restore_start_addon_real/')"
restore_start_addon() {
    local slug="${1}"

    if [[ "${slug}" == "${ALWAYS_FAIL_START_SLUG}" ]]; then
        return 1
    fi
    if [[ "${slug}" == "${FAIL_START_SLUG_ONCE}" && ! -f "${FAIL_ONCE_MARKER}" ]]; then
        : > "${FAIL_ONCE_MARKER}"
        return 1
    fi

    restore_start_addon_real "${slug}"
}

eval "$(declare -f update_window_state | sed '1s/update_window_state/update_window_state_real/')"
update_window_state() {
    if [[ "${FAIL_STATE_UPDATES}" == "true" ]]; then
        return 1
    fi

    update_window_state_real "$@"
}

test_legacy_state_does_not_replay_running_services() {
    reset_fixture
    set_addon_state "app_one" "started"
    set_addon_state "temporary" "started"
    printf '%s\n' \
        '{"restart_core":true,"core_watchdog_restore":true,"addons_to_restart":["app_one"],"temporary_addons_to_stop":["temporary"]}' \
        > "${WINDOW_STATE_FILE}"

    recover_window_from_state

    assert_state_cleared
    assert_equals "" "$(< "${ACTION_LOG}")" "legacy state replayed a mutation"
    assert_equals "started" "$(get_addon_state "temporary")" "restore-only cleanup stopped a temporary app"
}

test_expired_state_restores_without_stopping() {
    local now_epoch

    reset_fixture
    now_epoch="$(date +%s)"
    printf 'stopped\n' > "${CORE_STATE_FILE}"
    set_addon_state "app_one" "stopped"
    set_addon_state "temporary" "started"
    write_state "$(( now_epoch - 60 ))" true true '["app_one"]' '["temporary"]'

    recover_window_from_state

    assert_state_cleared
    grep --fixed-strings --quiet 'POST /core/start' "${ACTION_LOG}" || fail "expired state did not restore Core"
    grep --fixed-strings --quiet 'POST /addons/app_one/start' "${ACTION_LOG}" || fail "expired state did not restore app"
    assert_no_action 'POST /addons/temporary/stop'
    assert_equals "started" "$(get_addon_state "temporary")" "expired cleanup stopped a temporary app"
}

test_pending_running_core_is_not_restarted() {
    local now_epoch

    reset_fixture
    now_epoch="$(date +%s)"
    write_state "$(( now_epoch + 600 ))" true null '[]' '[]'

    restore_window_from_state false

    assert_state_cleared
    assert_no_action 'POST /core/start'
}

test_recovery_does_not_restart_addon_that_was_never_stopped() {
    local now_epoch

    reset_fixture
    now_epoch="$(date +%s)"
    set_addon_state "app_one" "started"
    write_state "$(( now_epoch - 60 ))" false null '["app_one"]' '[]'

    recover_window_from_state

    assert_state_cleared
    assert_no_action 'POST /addons/app_one/start'
    assert_equals "started" "$(get_addon_state "app_one")" "recovery changed an already-running app"
}

test_repeated_recovery_is_idempotent() {
    local now_epoch

    reset_fixture
    now_epoch="$(date +%s)"
    printf 'stopped\n' > "${CORE_STATE_FILE}"
    set_addon_state "app_one" "stopped"
    write_state "$(( now_epoch - 60 ))" true null '["app_one"]' '[]'

    recover_window_from_state
    recover_window_from_state

    assert_state_cleared
    assert_equals "1" "$(grep --count --fixed-strings 'POST /core/start' "${ACTION_LOG}" || true)" "recovery restarted Core twice"
    assert_equals "1" "$(grep --count --fixed-strings 'POST /addons/app_one/start' "${ACTION_LOG}" || true)" "recovery restarted an app twice"
}

test_core_watchdog_is_never_paused() {
    reset_fixture
    PAUSE_CORE_WATCHDOG="true"

    pause_core_watchdog_if_needed

    assert_equals "true" "$(< "${WATCHDOG_STATE_FILE}")" "maintenance window disabled the Core watchdog"
    assert_no_action 'POST /core/options {"watchdog":false}'
}

test_core_stop_requires_addon_watchdog() {
    reset_fixture
    WINDOW_RESTART_CORE="true"
    ADDON_WATCHDOG_STATE="false"

    if should_stop_core_for_window 7 0; then
        fail "Core stop was allowed while the Maintenance Window watchdog was disabled"
    fi

    grep --fixed-strings --quiet "Core stop blocked because the Maintenance Window app watchdog is disabled" "${TEST_LOG}" \
        || fail "disabled app watchdog did not produce the safety warning"
}

test_app_actions_require_addon_watchdog() {
    reset_fixture
    ADDON_WATCHDOG_STATE="false"
    STOP_ADDONS=$'ordinary_app\n'
    set_addon_state "ordinary_app" "started"

    if run_maintenance_window 0 "watchdog guard test" 0; then
        fail "app-only maintenance ran while the Maintenance Window watchdog was disabled"
    fi

    assert_no_action 'POST /addons/ordinary_app/stop'
    assert_equals "started" "$(get_addon_state "ordinary_app")" "app-only window stopped an app without crash recovery"
}

test_core_stop_requires_available_memory() {
    reset_fixture
    WINDOW_RESTART_CORE="true"
    printf 'MemAvailable:    65536 kB\n' > "${MEMINFO_FILE}"

    if should_stop_core_for_window 7 0; then
        fail "Core stop was allowed with insufficient available memory"
    fi

    grep --fixed-strings --quiet "only 64 MiB is available" "${TEST_LOG}" \
        || fail "low-memory Core stop did not produce the safety warning"
}

test_core_stops_before_apps_and_observability_stays_running() {
    local core_stop_line
    local app_stop_line

    reset_fixture
    WINDOW_RESTART_CORE="true"
    STOP_ADDONS=$'4f0066aa_syslog\nordinary_app\n'
    set_addon_state "4f0066aa_syslog" "started"
    set_addon_state "ordinary_app" "started"

    run_maintenance_window 0 "ordering test" 0

    assert_no_action 'POST /addons/4f0066aa_syslog/stop'
    assert_equals "started" "$(get_addon_state "4f0066aa_syslog")" "observability app was stopped"
    core_stop_line="$(grep --line-number --fixed-strings 'POST /core/stop' "${ACTION_LOG}" | cut -d: -f1)"
    app_stop_line="$(grep --line-number --fixed-strings 'POST /addons/ordinary_app/stop' "${ACTION_LOG}" | cut -d: -f1)"
    (( core_stop_line < app_stop_line )) || fail "ordinary app stopped before Core"
    grep --fixed-strings --quiet "preserve logs and metrics" "${TEST_LOG}" \
        || fail "observability protection was not logged"
}

test_never_stop_addons_are_protected() {
    reset_fixture
    STOP_ADDONS=$'protected_app\n'
    NEVER_STOP_ADDONS=$'protected_app\n'
    set_addon_state "protected_app" "started"

    run_maintenance_window 0 "protected app test" 0

    assert_no_action 'POST /addons/protected_app/stop'
    assert_equals "started" "$(get_addon_state "protected_app")" "never-stop app was stopped"
    grep --fixed-strings --quiet "listed in never_stop_addons" "${TEST_LOG}" \
        || fail "never-stop protection was not logged"
}

test_protected_temporary_addon_is_left_running() {
    reset_fixture
    START_ADDONS=$'protected_app\n4f0066aa_syslog\n'
    NEVER_STOP_ADDONS=$'protected_app\n'
    set_addon_state "protected_app" "stopped"
    set_addon_state "4f0066aa_syslog" "stopped"

    run_maintenance_window 0 "protected temporary app test" 0

    assert_equals "started" "$(get_addon_state "protected_app")" "never-stop temporary app was stopped"
    assert_equals "started" "$(get_addon_state "4f0066aa_syslog")" "observability temporary app was stopped"
    assert_no_action 'POST /addons/protected_app/stop'
    assert_no_action 'POST /addons/4f0066aa_syslog/stop'
}

run_sigkill_recovery_case() {
    local addon_watchdog="${1}"
    local wait_marker="${TEST_ROOT}/window-waiting"
    local child_pid
    local attempt

    reset_fixture
    rm -f "${wait_marker}"
    WINDOW_RESTART_CORE="true"
    ADDON_WATCHDOG_STATE="${addon_watchdog}"
    BLOCK_WINDOW_WAIT="true"
    WINDOW_WAIT_MARKER="${wait_marker}"

    (run_maintenance_window 0 "SIGKILL test" 0) &
    child_pid="$!"
    for (( attempt = 0; attempt < 100; attempt++ )); do
        [[ -f "${wait_marker}" ]] && break
        command sleep 0.05
    done
    [[ -f "${wait_marker}" ]] || fail "SIGKILL fixture did not enter its window"

    kill -KILL "${child_pid}"
    wait "${child_pid}" 2> /dev/null || true
    BLOCK_WINDOW_WAIT="false"

    recover_window_from_state

    assert_state_cleared
    assert_equals "running" "$(< "${CORE_STATE_FILE}")" "SIGKILL recovery left Core stopped"
    assert_equals "true" "$(< "${WATCHDOG_STATE_FILE}")" "SIGKILL recovery left the Core watchdog disabled"
    assert_no_action 'POST /core/options {"watchdog":false}'
}

test_sigkill_recovers_with_addon_watchdog_enabled() {
    run_sigkill_recovery_case true
    grep --fixed-strings --quiet 'POST /core/stop' "${ACTION_LOG}" \
        || fail "enabled-watchdog SIGKILL fixture did not stop Core"
}

test_sigkill_with_addon_watchdog_disabled_keeps_core_safe() {
    run_sigkill_recovery_case false
    assert_no_action 'POST /core/stop'
}

test_startup_reconciles_watchdog_before_retry_cutoff() {
    local now_epoch

    reset_fixture
    now_epoch="$(date +%s)"
    printf 'false\n' > "${WATCHDOG_STATE_FILE}"
    write_state "$(( now_epoch - 60 ))" false true '[]' '[]' "${MAX_RESTORE_ATTEMPTS}"

    recover_window_from_state

    assert_state_cleared
    assert_equals "true" "$(< "${WATCHDOG_STATE_FILE}")" "startup discarded the pending watchdog restore"
    grep --fixed-strings --quiet 'POST /core/options {"watchdog":true}' "${ACTION_LOG}" \
        || fail "startup did not reconcile the watchdog before the restore cutoff"
}

test_false_watchdog_target_is_restored_idempotently() {
    local now_epoch

    reset_fixture
    now_epoch="$(date +%s)"
    printf 'true\n' > "${WATCHDOG_STATE_FILE}"
    write_state "$(( now_epoch + 600 ))" false false '[]' '[]'

    restore_window_from_state false

    assert_state_cleared
    assert_equals "false" "$(< "${WATCHDOG_STATE_FILE}")" "false watchdog target was not restored"
    grep --fixed-strings --quiet 'POST /core/options {"watchdog":false}' "${ACTION_LOG}" \
        || fail "false watchdog restore did not update Supervisor"
}

test_restore_staggers_before_each_pending_app() {
    local now_epoch
    local actions

    reset_fixture
    now_epoch="$(date +%s)"
    RESTORE_STAGGER_SECONDS="15"
    set_addon_state "app_one" "stopped"
    set_addon_state "app_two" "stopped"
    write_state "$(( now_epoch + 600 ))" false null '["app_one","app_two"]' '[]'

    restore_window_from_state false

    assert_state_cleared
    actions="$(< "${ACTION_LOG}")"
    assert_equals \
        $'SLEEP 15\nPOST /addons/app_one/start\nSLEEP 15\nPOST /addons/app_two/start' \
        "${actions}" \
        "app restores were not staggered before each start"
}

test_state_update_failure_degrades_without_looping() {
    local now_epoch

    reset_fixture
    now_epoch="$(date +%s)"
    FAIL_STATE_UPDATES="true"
    printf 'stopped\n' > "${CORE_STATE_FILE}"
    set_addon_state "app_one" "stopped"
    set_addon_state "temporary" "started"
    write_state "$(( now_epoch + 600 ))" true null '["app_one"]' '["temporary"]'

    restore_window_until_complete false

    assert_state_cleared
    assert_equals "running" "$(< "${CORE_STATE_FILE}")" "state update failure left Core stopped"
    assert_equals "started" "$(get_addon_state "app_one")" "state update failure left an app stopped"
    assert_equals "started" "$(get_addon_state "temporary")" "degraded cleanup stopped a temporary app"
    grep --fixed-strings --quiet 'switching to one restore-only cleanup pass' "${TEST_LOG}" \
        || fail "state update failure did not log safe degradation"
}

test_interrupted_restore_resumes_pending_actions() {
    local now_epoch
    local pending_core
    local pending_addons
    local core_start_count

    reset_fixture
    now_epoch="$(date +%s)"
    printf 'stopped\n' > "${CORE_STATE_FILE}"
    printf 'false\n' > "${WATCHDOG_STATE_FILE}"
    set_addon_state "app_one" "stopped"
    set_addon_state "app_two" "stopped"
    set_addon_state "temporary" "stopped"
    write_state "$(( now_epoch + 600 ))" true true '["app_one","app_two"]' '["temporary"]'
    FAIL_START_SLUG_ONCE="app_two"

    if restore_window_from_state false; then
        fail "interrupted restore unexpectedly completed"
    fi

    pending_core="$(jq --raw-output '.restart_core' "${WINDOW_STATE_FILE}")"
    pending_addons="$(jq --compact-output '.addons_to_restart' "${WINDOW_STATE_FILE}")"
    assert_equals "false" "${pending_core}" "completed Core action remained pending"
    assert_equals '["app_two"]' "${pending_addons}" "completed app action remained pending"

    restore_window_from_state false

    assert_state_cleared
    core_start_count="$(grep --count --fixed-strings 'POST /core/start' "${ACTION_LOG}" || true)"
    assert_equals "1" "${core_start_count}" "Core start was replayed"
    assert_equals "started" "$(get_addon_state "app_one")" "first app was not restored"
    assert_equals "started" "$(get_addon_state "app_two")" "second app was not restored"
    assert_equals "stopped" "$(get_addon_state "temporary")" "stopped temporary app changed state"
    assert_equals "true" "$(< "${WATCHDOG_STATE_FILE}")" "watchdog was not restored"
}

test_restore_failures_are_bounded() {
    local now_epoch

    reset_fixture
    now_epoch="$(date +%s)"
    set_addon_state "broken" "stopped"
    write_state "$(( now_epoch + 600 ))" false null '["broken"]' '[]'
    ALWAYS_FAIL_START_SLUG="broken"

    if restore_window_until_complete false; then
        fail "bounded restore failure unexpectedly succeeded"
    fi

    assert_state_cleared
    grep --fixed-strings --quiet \
        "keeps failing after ${MAX_RESTORE_ATTEMPTS} attempts" "${TEST_LOG}" \
        || fail "bounded restore failure did not log the retry cutoff"
}

test_dry_run_never_mutates_supervisor() {
    local now_epoch

    reset_fixture
    now_epoch="$(date +%s)"
    DRY_RUN="true"
    printf 'stopped\n' > "${CORE_STATE_FILE}"
    printf 'false\n' > "${WATCHDOG_STATE_FILE}"
    set_addon_state "app_one" "stopped"
    set_addon_state "temporary" "started"
    write_state "$(( now_epoch - 60 ))" true true '["app_one"]' '["temporary"]'

    recover_window_from_state

    assert_state_cleared
    assert_equals "" "$(< "${ACTION_LOG}")" "dry run issued a Supervisor mutation"
    assert_equals "stopped" "$(< "${CORE_STATE_FILE}")" "dry run changed Core state"
    assert_equals "false" "$(< "${WATCHDOG_STATE_FILE}")" "dry run changed watchdog state"
    assert_equals "started" "$(get_addon_state "temporary")" "dry run changed temporary app state"
}

test_legacy_state_does_not_replay_running_services
test_expired_state_restores_without_stopping
test_pending_running_core_is_not_restarted
test_recovery_does_not_restart_addon_that_was_never_stopped
test_repeated_recovery_is_idempotent
test_core_watchdog_is_never_paused
test_core_stop_requires_addon_watchdog
test_app_actions_require_addon_watchdog
test_core_stop_requires_available_memory
test_core_stops_before_apps_and_observability_stays_running
test_never_stop_addons_are_protected
test_protected_temporary_addon_is_left_running
test_sigkill_recovers_with_addon_watchdog_enabled
test_sigkill_with_addon_watchdog_disabled_keeps_core_safe
test_startup_reconciles_watchdog_before_retry_cutoff
test_false_watchdog_target_is_restored_idempotently
test_restore_staggers_before_each_pending_app
test_state_update_failure_degrades_without_looping
test_interrupted_restore_resumes_pending_actions
test_restore_failures_are_bounded
test_dry_run_never_mutates_supervisor

printf 'Scheduler restore regression tests passed.\n'