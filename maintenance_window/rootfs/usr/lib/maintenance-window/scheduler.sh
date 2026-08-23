#!/usr/bin/env bash
# ==============================================================================
# Maintenance Window — shared scheduler library
#
# This file contains the core logic for the app:
#   * read user configuration (via bashio / /data/options.json)
#   * wait until the next scheduled maintenance window
#   * temporarily start configured apps
#   * stop configured apps and (optionally) Home Assistant Core
#   * hold for the window duration
#   * start everything back up
#
# The scheduler computes the next configured day/time occurrence, sleeps until
# then, runs the requested maintenance window, and repeats.
#
# Supervisor API reference (authenticated with the SUPERVISOR_TOKEN bearer
# token against http://supervisor):
#   POST /core/stop                 Stop Home Assistant Core
#   POST /core/start                Start Home Assistant Core
#   GET  /core/info                 Inspect Core/Supervisor state
#   POST /core/options              Update Core options such as watchdog
#   POST /addons/<slug>/stop        Stop an app
#   POST /addons/<slug>/start       Start an app
#   GET  /addons/<slug>/info        Inspect an app (state, etc.)
# Requires config.json: "hassio_api": true and "hassio_role": "manager".
# ==============================================================================
# shellcheck shell=bash

readonly SUPERVISOR_API="http://supervisor"
readonly HOMEASSISTANT_API="${SUPERVISOR_API}/core/api"
readonly ADDON_SLUG="maintenance_window"
readonly NO_WINDOW_SLEEP_SECONDS="300"
readonly WINDOW_STATE_FILE="${WINDOW_STATE_FILE:-/data/maintenance-window-state.json}"
readonly ADDON_INVENTORY_FILE="/addon_config/available_addons.md"
readonly SUPERVISOR_CONNECT_TIMEOUT_SECONDS="5"
readonly SUPERVISOR_REQUEST_TIMEOUT_SECONDS="15"
readonly STATE_QUERY_MAX_ATTEMPTS="5"
readonly STATE_QUERY_INITIAL_BACKOFF_SECONDS="2"
readonly STATE_QUERY_MAX_BACKOFF_SECONDS="30"
readonly CORE_READY_POLL_SECONDS="5"
readonly ADDON_STATE_TIMEOUT_SECONDS="300"
readonly WINDOW_SLEEP_SLICE_SECONDS="15"
readonly MAX_RESTORE_ATTEMPTS="3"
readonly RESTORE_PASS_RETRY_SECONDS="15"
STARTED_AT_EPOCH="$(date +%s)"
readonly STARTED_AT_EPOCH

# -----------------------------------------------------------------------------
# Return true when the configured app slug points at this app.
# -----------------------------------------------------------------------------
addon_is_self() {
    local slug="${1}"

    [[ "${slug}" == "${ADDON_SLUG}" ]] && return 0
    [[ -n "${HOSTNAME:-}" && "${slug}" == "${HOSTNAME}" ]] && return 0

    return 1
}

# -----------------------------------------------------------------------------
# Helper: perform an authenticated Supervisor API call.
# Usage: supervisor_api <METHOD> <PATH>
# -----------------------------------------------------------------------------
supervisor_api() {
    local method="${1}"
    local path="${2}"

    curl --silent --show-error --fail \
        --connect-timeout "${SUPERVISOR_CONNECT_TIMEOUT_SECONDS}" \
        --max-time "${SUPERVISOR_REQUEST_TIMEOUT_SECONDS}" \
        --request "${method}" \
        --header "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
        --header "Content-Type: application/json" \
        "${SUPERVISOR_API}${path}"
}

# -----------------------------------------------------------------------------
# Helper: perform an authenticated Supervisor API call with a JSON body.
# Usage: supervisor_api_json <METHOD> <PATH> <JSON>
# -----------------------------------------------------------------------------
supervisor_api_json() {
    local method="${1}"
    local path="${2}"
    local payload="${3}"

    curl --silent --show-error --fail \
        --connect-timeout "${SUPERVISOR_CONNECT_TIMEOUT_SECONDS}" \
        --max-time "${SUPERVISOR_REQUEST_TIMEOUT_SECONDS}" \
        --request "${method}" \
        --header "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
        --header "Content-Type: application/json" \
        --data "${payload}" \
        "${SUPERVISOR_API}${path}"
}

# -----------------------------------------------------------------------------
# Helper: perform an authenticated Home Assistant Core API call through the
# Supervisor proxy. This works after Core has started and requires
# config.json: "homeassistant_api": true.
# -----------------------------------------------------------------------------
homeassistant_api() {
    local method="${1}"
    local path="${2}"

    curl --silent --fail --output /dev/null \
        --connect-timeout "${SUPERVISOR_CONNECT_TIMEOUT_SECONDS}" \
        --max-time "${SUPERVISOR_REQUEST_TIMEOUT_SECONDS}" \
        --request "${method}" \
        --header "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
        --header "Content-Type: application/json" \
        "${HOMEASSISTANT_API}${path}"
}

# -----------------------------------------------------------------------------
# Return the Supervisor state for an app slug, such as "started" or "stopped".
# -----------------------------------------------------------------------------
addon_state() {
    local slug="${1}"
    local response

    response="$(supervisor_api "GET" "/addons/${slug}/info")"
    jq --raw-output '.data.state // empty' <<< "${response}"
}

# -----------------------------------------------------------------------------
# Return the Supervisor state for Home Assistant Core, such as "running".
# -----------------------------------------------------------------------------
core_state() {
    local response

    response="$(supervisor_api "GET" "/core/info")"
    jq --raw-output '.data.state // empty' <<< "${response}"
}

# -----------------------------------------------------------------------------
# Retry a Supervisor state query with bounded exponential backoff.
# Query functions must print the state to stdout.
# -----------------------------------------------------------------------------
supervisor_state_with_backoff() {
    local description="${1}"
    local query_function="${2}"
    shift 2

    local attempt=1
    local backoff_seconds="${STATE_QUERY_INITIAL_BACKOFF_SECONDS}"
    local state

    while (( attempt <= STATE_QUERY_MAX_ATTEMPTS )); do
        if state="$("${query_function}" "$@")" && [[ -n "${state}" ]]; then
            printf '%s\n' "${state}"
            return 0
        fi

        if (( attempt < STATE_QUERY_MAX_ATTEMPTS )); then
            bashio::log.warning "Supervisor did not answer the ${description} query; retrying in ${backoff_seconds}s (attempt ${attempt}/${STATE_QUERY_MAX_ATTEMPTS})." >&2
            sleep "${backoff_seconds}"
            backoff_seconds="$(( backoff_seconds * 2 ))"
            if (( backoff_seconds > STATE_QUERY_MAX_BACKOFF_SECONDS )); then
                backoff_seconds="${STATE_QUERY_MAX_BACKOFF_SECONDS}"
            fi
        fi

        attempt="$(( attempt + 1 ))"
    done

    bashio::log.error "Supervisor did not answer the ${description} query after ${STATE_QUERY_MAX_ATTEMPTS} attempts." >&2
    return 1
}

# -----------------------------------------------------------------------------
# Write and log installed Supervisor apps so users can copy slugs into config.
# -----------------------------------------------------------------------------
write_addon_inventory() {
    local response
    local count
    local slug
    local name
    local state

    if ! bashio::config.true 'list_addons_on_startup'; then
        return 0
    fi

    if ! response="$(supervisor_api "GET" "/addons")"; then
        bashio::log.warning "Could not list Supervisor apps for inventory."
        return 0
    fi

    mkdir -p "$(dirname "${ADDON_INVENTORY_FILE}")"

    {
        echo "# Available Supervisor apps"
        echo
        echo "Copy slugs from this table into Maintenance Window's stop_addons or start_addons options."
        echo
        echo "| Name | Slug | State |"
        echo "| ---- | ---- | ----- |"
        jq --raw-output '
            .data.addons[]
            | [.name, .slug, (.state // "unknown")]
            | @tsv
        ' <<< "${response}" |
            while IFS=$'\t' read -r name slug state; do
                [[ -z "${slug}" ]] && continue
                if addon_is_self "${slug}"; then
                    continue
                fi
                printf "| %s | \`%s\` | %s |\n" "${name}" "${slug}" "${state}"
            done
    } > "${ADDON_INVENTORY_FILE}"

    count="$(jq '.data.addons | length' <<< "${response}")"
    bashio::log.info "Wrote Supervisor app inventory (${count} apps) to ${ADDON_INVENTORY_FILE}"
    bashio::log.info "Installed apps available for Maintenance Window actions:"

    jq --raw-output '
        .data.addons[]
        | [.name, .slug, (.state // "unknown")]
        | @tsv
    ' <<< "${response}" |
        while IFS=$'\t' read -r name slug state; do
            [[ -z "${slug}" ]] && continue
            if addon_is_self "${slug}"; then
                continue
            fi
            bashio::log.info "  ${slug} — ${name} (${state})"
        done
}

# -----------------------------------------------------------------------------
# Build a JSON array from shell arguments.
# -----------------------------------------------------------------------------
json_array() {
    if (( $# == 0 )); then
        echo '[]'
        return 0
    fi

    printf '%s\n' "$@" | jq --raw-input . | jq --slurp .
}

# -----------------------------------------------------------------------------
# Read an integer config value, falling back to a safe default if malformed.
# -----------------------------------------------------------------------------
config_int() {
    local key="${1}"
    local default_value="${2}"
    local value

    value="$(bashio::config "${key}" "${default_value}")"
    if [[ "${value}" =~ ^[0-9]+$ ]]; then
        echo "${value}"
        return 0
    fi

    bashio::log.warning "Config value '${key}' is not a valid integer: ${value}; using ${default_value}." >&2
    echo "${default_value}"
}

# -----------------------------------------------------------------------------
# Return true when this window defines app action overrides.
# -----------------------------------------------------------------------------
window_has_app_action_override() {
    local window_index="${1}"
    local value

    value="$(bashio::config "windows[${window_index}].stop_addons" '__missing__')"
    if [[ "${value}" != "__missing__" ]]; then
        return 0
    fi

    value="$(bashio::config "windows[${window_index}].start_addons" '__missing__')"
    if [[ "${value}" != "__missing__" ]]; then
        return 0
    fi

    return 1
}

# -----------------------------------------------------------------------------
# Return true when this window should stop Core.
# -----------------------------------------------------------------------------
window_restart_core_enabled() {
    local window_index="${1}"
    local value

    value="$(bashio::config "windows[${window_index}].restart_core" '__missing__')"
    case "${value}" in
        true)
            return 0
            ;;
        false|"")
            return 1
            ;;
        __missing__)
            bashio::log.info "Window restart_core is not set; leaving Core running."
            return 1
            ;;
        *)
            bashio::log.warning "Window restart_core has unexpected value '${value}'; leaving Core running."
            return 1
            ;;
    esac
}

# -----------------------------------------------------------------------------
# Emit a window list option, falling back to the global list when absent.
# -----------------------------------------------------------------------------
config_list_with_fallback() {
    local window_key="${1}"
    local global_key="${2}"
    local value

    value="$(bashio::config "${window_key}" '__missing__')"
    if [[ "${value}" == "__missing__" ]]; then
        bashio::config "${global_key}"
        return 0
    fi

    printf '%s\n' "${value}"
}

# -----------------------------------------------------------------------------
# Return true when stopping Core is deliberately armed and safe for this window.
# -----------------------------------------------------------------------------
should_stop_core_for_window() {
    local duration_minutes="${1}"
    local window_index="${2}"
    local confirmation
    local startup_grace_seconds
    local max_core_stop_minutes
    local uptime_seconds

    if ! window_restart_core_enabled "${window_index}"; then
        bashio::log.info "restart_core is disabled; leaving Core running."
        return 1
    fi

    confirmation="$(bashio::config 'core_stop_confirmation' '')"
    if [[ "${confirmation}" != "STOP_CORE" ]]; then
        bashio::log.warning "Core stop is not armed. Set core_stop_confirmation to STOP_CORE to allow stopping Home Assistant Core."
        return 1
    fi

    startup_grace_seconds="$(config_int 'startup_grace_seconds' 300)"
    uptime_seconds="$(( $(date +%s) - STARTED_AT_EPOCH ))"
    if (( uptime_seconds < startup_grace_seconds )); then
        bashio::log.warning "Core stop blocked by startup grace period (${uptime_seconds}/${startup_grace_seconds}s since app start)."
        return 1
    fi

    max_core_stop_minutes="$(config_int 'max_core_stop_minutes' 60)"
    if (( duration_minutes > max_core_stop_minutes )); then
        bashio::log.warning "Core stop blocked because window duration (${duration_minutes} min) exceeds max_core_stop_minutes (${max_core_stop_minutes} min)."
        return 1
    fi

    return 0
}

# -----------------------------------------------------------------------------
# Stop a single app by slug.
# -----------------------------------------------------------------------------
stop_addon() {
    local slug="${1}"

    if addon_is_self "${slug}"; then
        bashio::log.warning "Skipping configured app '${slug}' because Maintenance Window must not stop itself."
        return 1
    fi

    if bashio::config.true 'dry_run'; then
        bashio::log.notice "[dry_run] Would stop app: ${slug}"
        return 0
    fi

    bashio::log.info "Stopping app: ${slug}"
    if ! supervisor_api "POST" "/addons/${slug}/stop"; then
        bashio::log.warning "Failed to stop app: ${slug}"
        return 1
    fi

    return 0
}

# -----------------------------------------------------------------------------
# Stop an app only if it is currently running.
# Returns 0 when the app should be restarted at the end of the window.
# -----------------------------------------------------------------------------
stop_addon_if_running() {
    local slug="${1}"
    local state

    if addon_is_self "${slug}"; then
        bashio::log.warning "Skipping configured app '${slug}' because Maintenance Window must not stop itself."
        return 1
    fi

    if bashio::config.true 'dry_run'; then
        bashio::log.notice "[dry_run] Would inspect and stop app if running: ${slug}"
        return 0
    fi

    if ! state="$(addon_state "${slug}")"; then
        bashio::log.warning "Could not inspect app '${slug}'; will try to stop it and restart it later."
        stop_addon "${slug}" || true
        return 0
    fi

    if [[ "${state}" != "started" ]]; then
        bashio::log.info "App '${slug}' is '${state:-unknown}', so it will not be stopped or restarted."
        return 1
    fi

    stop_addon "${slug}" || true
    return 0
}

# -----------------------------------------------------------------------------
# Start a single app by slug.
# -----------------------------------------------------------------------------
start_addon() {
    local slug="${1}"

    if bashio::config.true 'dry_run'; then
        bashio::log.notice "[dry_run] Would start app: ${slug}"
        return 0
    fi

    bashio::log.info "Starting app: ${slug}"
    if ! supervisor_api "POST" "/addons/${slug}/start"; then
        bashio::log.warning "Failed to start app: ${slug}"
        return 1
    fi

    return 0
}

# -----------------------------------------------------------------------------
# Wait for an app to reach a desired state without hammering Supervisor during
# host-wide I/O stalls.
# -----------------------------------------------------------------------------
wait_for_addon_state() {
    local slug="${1}"
    local desired_state="${2}"
    local deadline="$(( $(date +%s) + ADDON_STATE_TIMEOUT_SECONDS ))"
    local backoff_seconds="${STATE_QUERY_INITIAL_BACKOFF_SECONDS}"
    local state

    while (( $(date +%s) < deadline )); do
        if state="$(addon_state "${slug}")" && [[ -n "${state}" ]]; then
            if [[ "${state,,}" == "${desired_state,,}" ]]; then
                bashio::log.info "App '${slug}' reached state '${desired_state}'."
                return 0
            fi
        else
            bashio::log.warning "Supervisor did not answer while waiting for app '${slug}' to become '${desired_state}'; retrying in ${backoff_seconds}s."
        fi

        sleep "${backoff_seconds}"
        backoff_seconds="$(( backoff_seconds * 2 ))"
        if (( backoff_seconds > STATE_QUERY_MAX_BACKOFF_SECONDS )); then
            backoff_seconds="${STATE_QUERY_MAX_BACKOFF_SECONDS}"
        fi
    done

    bashio::log.error "App '${slug}' did not reach state '${desired_state}' within ${ADDON_STATE_TIMEOUT_SECONDS}s."
    return 1
}

# -----------------------------------------------------------------------------
# Idempotent app actions used only by the persisted restore state machine.
# -----------------------------------------------------------------------------
restore_start_addon() {
    local slug="${1}"
    local state

    if addon_is_self "${slug}"; then
        bashio::log.info "Skipping restore start for '${slug}' because Maintenance Window is already running."
        return 0
    fi

    if bashio::config.true 'dry_run'; then
        bashio::log.notice "[dry_run] Would inspect and start app if needed: ${slug}"
        return 0
    fi

    if ! state="$(supervisor_state_with_backoff "state for app '${slug}'" addon_state "${slug}")"; then
        return 1
    fi

    if [[ "${state,,}" == "started" ]]; then
        bashio::log.info "App '${slug}' is already started; skipping start."
        return 0
    fi

    start_addon "${slug}" || bashio::log.warning "Start request for app '${slug}' was not acknowledged; checking its state before retrying."
    wait_for_addon_state "${slug}" "started"
}

restore_stop_addon() {
    local slug="${1}"
    local state

    if addon_is_self "${slug}"; then
        bashio::log.warning "Skipping restore stop for '${slug}' because Maintenance Window must not stop itself."
        return 0
    fi

    if bashio::config.true 'dry_run'; then
        bashio::log.notice "[dry_run] Would inspect and stop app if needed: ${slug}"
        return 0
    fi

    if ! state="$(supervisor_state_with_backoff "state for app '${slug}'" addon_state "${slug}")"; then
        return 1
    fi

    if [[ "${state,,}" == "stopped" ]]; then
        bashio::log.info "App '${slug}' is already stopped; skipping stop."
        return 0
    fi

    stop_addon "${slug}" || bashio::log.warning "Stop request for app '${slug}' was not acknowledged; checking its state before retrying."
    wait_for_addon_state "${slug}" "stopped"
}

# -----------------------------------------------------------------------------
# Start an app only if it is currently stopped.
# Returns 0 when the app should be stopped at the end of the window.
# -----------------------------------------------------------------------------
start_addon_if_stopped() {
    local slug="${1}"
    local state

    if addon_is_self "${slug}"; then
        bashio::log.info "App '${slug}' is already running because it is Maintenance Window."
        return 1
    fi

    if bashio::config.true 'dry_run'; then
        bashio::log.notice "[dry_run] Would inspect and start app if stopped: ${slug}"
        return 0
    fi

    if ! state="$(addon_state "${slug}")"; then
        bashio::log.warning "Could not inspect app '${slug}'; will try to start it and stop it later."
        start_addon "${slug}" || true
        return 0
    fi

    if [[ "${state}" == "started" ]]; then
        bashio::log.info "App '${slug}' is already started, so it will not be stopped at the end of the window."
        return 1
    fi

    start_addon "${slug}" || true
    return 0
}

# -----------------------------------------------------------------------------
# Stop Home Assistant Core.
# -----------------------------------------------------------------------------
stop_core() {
    if bashio::config.true 'dry_run'; then
        bashio::log.notice "[dry_run] Would stop Home Assistant Core"
        return 0
    fi

    bashio::log.info "Stopping Home Assistant Core..."
    if ! supervisor_api "POST" "/core/stop"; then
        bashio::log.error "Failed to stop Home Assistant Core"
        return 1
    fi

    return 0
}

# -----------------------------------------------------------------------------
# Inspect and update Home Assistant Core watchdog through Supervisor.
# -----------------------------------------------------------------------------
core_watchdog_state() {
    local response

    response="$(supervisor_api "GET" "/core/info")"
    jq --raw-output 'if .data.watchdog == null then empty else .data.watchdog end' <<< "${response}"
}

set_core_watchdog() {
    local desired_state="${1}"

    if bashio::config.true 'dry_run'; then
        bashio::log.notice "[dry_run] Would set Home Assistant Core watchdog to ${desired_state}."
        return 0
    fi

    supervisor_api_json "POST" "/core/options" "{\"watchdog\":${desired_state}}" > /dev/null
}

core_watchdog_restore_value() {
    local state

    if ! bashio::config.true 'pause_core_watchdog'; then
        echo 'null'
        return 0
    fi

    if ! state="$(core_watchdog_state)"; then
        bashio::log.warning "Could not inspect Home Assistant Core watchdog state; leaving it unchanged." >&2
        echo 'null'
        return 0
    fi

    case "${state}" in
        true|false)
            echo "${state}"
            ;;
        *)
            bashio::log.warning "Home Assistant Core watchdog state is unknown; leaving it unchanged." >&2
            echo 'null'
            ;;
    esac
}

pause_core_watchdog_if_needed() {
    local restore_value="${1}"

    if [[ "${restore_value}" != "true" ]]; then
        return 0
    fi

    bashio::log.info "Pausing Home Assistant Core watchdog during the maintenance window."
    if ! set_core_watchdog false; then
        bashio::log.warning "Could not pause Home Assistant Core watchdog; continuing with watchdog unchanged."
    fi
}

restore_core_watchdog_if_needed() {
    local restore_value="${1}"
    local current_value

    case "${restore_value}" in
        true|false)
            if bashio::config.true 'dry_run'; then
                bashio::log.notice "[dry_run] Would restore Home Assistant Core watchdog to ${restore_value}."
                return 0
            fi

            if ! current_value="$(supervisor_state_with_backoff "Home Assistant Core watchdog state" core_watchdog_state)"; then
                return 1
            fi

            if [[ "${current_value}" == "${restore_value}" ]]; then
                bashio::log.info "Home Assistant Core watchdog is already ${restore_value}; skipping update."
                return 0
            fi

            bashio::log.info "Restoring Home Assistant Core watchdog to ${restore_value}."
            if ! set_core_watchdog "${restore_value}"; then
                bashio::log.warning "Watchdog update was not acknowledged; checking its state before retrying."
            fi

            if ! current_value="$(supervisor_state_with_backoff "Home Assistant Core watchdog state" core_watchdog_state)" \
                || [[ "${current_value}" != "${restore_value}" ]]; then
                bashio::log.error "Could not confirm that the Home Assistant Core watchdog was restored to ${restore_value}."
                return 1
            fi
            ;;
    esac

    return 0
}

# -----------------------------------------------------------------------------
# Start Home Assistant Core.
# -----------------------------------------------------------------------------
wait_for_core_api() {
    local timeout_seconds
    local deadline
    local elapsed_seconds
    local poll_seconds="${CORE_READY_POLL_SECONDS}"

    timeout_seconds="$(config_int 'core_start_timeout_seconds' 600)"
    if (( timeout_seconds == 0 )); then
        bashio::log.info "Core API readiness wait is disabled."
        return 0
    fi

    bashio::log.info "Waiting up to ${timeout_seconds}s for Home Assistant Core API to become ready..."
    deadline="$(( $(date +%s) + timeout_seconds ))"

    while (( $(date +%s) < deadline )); do
        if homeassistant_api "GET" "/"; then
            elapsed_seconds="$(( timeout_seconds - (deadline - $(date +%s)) ))"
            bashio::log.info "Home Assistant Core API is ready after ${elapsed_seconds}s."
            return 0
        fi

        sleep "${poll_seconds}"
        poll_seconds="$(( poll_seconds * 2 ))"
        if (( poll_seconds > STATE_QUERY_MAX_BACKOFF_SECONDS )); then
            poll_seconds="${STATE_QUERY_MAX_BACKOFF_SECONDS}"
        fi
    done

    bashio::log.warning "Home Assistant Core API did not become ready within ${timeout_seconds}s; continuing restore anyway."
    return 1
}

start_core() {
    local force="${1:-false}"
    local state

    if [[ "${force}" != "true" ]] && ! bashio::config.true 'restart_core'; then
        return 0
    fi

    if bashio::config.true 'dry_run'; then
        bashio::log.notice "[dry_run] Would start Home Assistant Core"
        return 0
    fi

    if ! state="$(supervisor_state_with_backoff "Home Assistant Core state" core_state)"; then
        return 1
    fi

    case "${state,,}" in
        running|started)
            bashio::log.info "Home Assistant Core is already running; skipping start."
            ;;
        starting)
            bashio::log.info "Home Assistant Core is already starting; waiting for its API."
            ;;
        *)
            bashio::log.info "Starting Home Assistant Core..."
            if ! supervisor_api "POST" "/core/start"; then
                bashio::log.warning "Core start request was not acknowledged; checking API readiness before retrying."
            fi
            ;;
    esac

    if wait_for_core_api; then
        return 0
    fi

    bashio::log.error "Home Assistant Core could not be confirmed ready."
    return 1
}

# -----------------------------------------------------------------------------
# Persist the restore actions for the active window.
# -----------------------------------------------------------------------------
write_window_state() {
    local addons_to_restart_json="${1}"
    local temporary_addons_to_stop_json="${2}"
    local restart_core_json="${3}"
    local core_watchdog_restore_json="${4}"
    local window_end_epoch="${5}"
    local window_name="${6}"
    local temporary_state_file="${WINDOW_STATE_FILE}.tmp.$$"

    if bashio::config.true 'dry_run'; then
        return 0
    fi

    if ! jq --null-input \
        --argjson restart_core "${restart_core_json}" \
        --argjson core_watchdog_restore "${core_watchdog_restore_json}" \
        --argjson addons_to_restart "${addons_to_restart_json}" \
        --argjson temporary_addons_to_stop "${temporary_addons_to_stop_json}" \
        --argjson window_end_epoch "${window_end_epoch}" \
        --arg window_name "${window_name}" \
        '{window_end_epoch: $window_end_epoch, attempts: 0, window_name: $window_name, restart_core: $restart_core, core_watchdog_restore: $core_watchdog_restore, addons_to_restart: $addons_to_restart, temporary_addons_to_stop: $temporary_addons_to_stop}' \
        > "${temporary_state_file}" || ! mv -f "${temporary_state_file}" "${WINDOW_STATE_FILE}"; then
        rm -f "${temporary_state_file}"
        bashio::log.error "Failed to write active-window recovery state; refusing to stop Home Assistant Core."
        return 1
    fi
}

# -----------------------------------------------------------------------------
# Atomically update the active-window state in place.
# -----------------------------------------------------------------------------
update_window_state() {
    local temporary_state_file="${WINDOW_STATE_FILE}.tmp.$$"

    if [[ ! -f "${WINDOW_STATE_FILE}" ]]; then
        bashio::log.error "Cannot update active-window recovery state because it is missing."
        return 1
    fi

    if jq "$@" "${WINDOW_STATE_FILE}" > "${temporary_state_file}" \
        && mv -f "${temporary_state_file}" "${WINDOW_STATE_FILE}"; then
        return 0
    fi

    rm -f "${temporary_state_file}"
    bashio::log.error "Failed to atomically update active-window recovery state."
    return 1
}

# -----------------------------------------------------------------------------
# Sleep in short intervals so a restarted app can resume the same absolute end.
# -----------------------------------------------------------------------------
wait_until_epoch() {
    local target_epoch="${1}"
    local now_epoch
    local remaining_seconds
    local sleep_seconds

    while true; do
        now_epoch="$(date +%s)"
        if (( now_epoch >= target_epoch )); then
            return 0
        fi

        remaining_seconds="$(( target_epoch - now_epoch ))"
        sleep_seconds="${WINDOW_SLEEP_SLICE_SECONDS}"
        if (( remaining_seconds < sleep_seconds )); then
            sleep_seconds="${remaining_seconds}"
        fi
        sleep "${sleep_seconds}"
    done
}

# -----------------------------------------------------------------------------
# Restore Core/apps from persisted state. Completed actions are removed from the
# state atomically so a SIGKILL resumes at the first pending action.
# -----------------------------------------------------------------------------
restore_window_from_state() {
    local restore_only="${1:-auto}"
    local should_start_core
    local core_watchdog_restore
    local window_end_epoch
    local window_name
    local attempts
    local now_epoch
    local restore_stagger_seconds
    local restore_failed="false"
    local slug
    local index
    local -a addons_to_restart=()
    local -a temporary_addons_to_stop=()

    if [[ ! -f "${WINDOW_STATE_FILE}" ]]; then
        return 0
    fi

    if ! jq --exit-status 'type == "object"' "${WINDOW_STATE_FILE}" > /dev/null; then
        bashio::log.error "Active-window recovery state is invalid JSON; clearing it to prevent a restart loop."
        rm -f "${WINDOW_STATE_FILE}"
        return 1
    fi

    window_name="$(jq --raw-output '.window_name // "unknown maintenance window"' "${WINDOW_STATE_FILE}")"
    window_end_epoch="$(jq --raw-output '.window_end_epoch // 0' "${WINDOW_STATE_FILE}")"
    now_epoch="$(date +%s)"

    if [[ "${restore_only}" == "auto" ]]; then
        if [[ ! "${window_end_epoch}" =~ ^[0-9]+$ ]] || (( window_end_epoch <= now_epoch )); then
            restore_only="true"
        else
            restore_only="false"
        fi
    fi

    attempts="$(jq --raw-output --argjson max_attempts "${MAX_RESTORE_ATTEMPTS}" '
        (.attempts // 0) as $attempts
        | if (($attempts | type) == "number")
            and ($attempts >= 0)
            and ($attempts <= $max_attempts)
            and ($attempts == ($attempts | floor))
          then $attempts + 1
          else $max_attempts + 1
          end
    ' "${WINDOW_STATE_FILE}")"
    if ! update_window_state --argjson attempts "${attempts}" ".attempts = \$attempts"; then
        bashio::log.error "Could not persist the restore attempt; switching to one restore-only cleanup pass so recovery cannot loop."
        restore_only="true"
        restore_failed="true"
    fi

    if (( attempts > MAX_RESTORE_ATTEMPTS )); then
        bashio::log.error "Restore for '${window_name}' keeps failing after ${MAX_RESTORE_ATTEMPTS} attempts; clearing recovery state and returning to normal scheduling."
        rm -f "${WINDOW_STATE_FILE}"
        return 1
    fi

    bashio::log.warning "Restoring '${window_name}' from persisted state (attempt ${attempts}/${MAX_RESTORE_ATTEMPTS})."

    should_start_core="$(jq --raw-output '.restart_core // false' "${WINDOW_STATE_FILE}")"
    core_watchdog_restore="$(jq --raw-output '
        if .core_watchdog_restore == true then "true"
        elif .core_watchdog_restore == false then "false"
        else "null"
        end
    ' "${WINDOW_STATE_FILE}")"
    if [[ "${should_start_core}" == "true" ]]; then
        if start_core true; then
            if ! update_window_state '.restart_core = false'; then
                if [[ "${restore_only}" != "true" ]]; then
                    return 1
                fi
                restore_failed="true"
            fi
        elif [[ "${restore_only}" == "true" ]]; then
            restore_failed="true"
        else
            return 1
        fi
    fi

    mapfile -t addons_to_restart < <(jq --raw-output '.addons_to_restart[]?' "${WINDOW_STATE_FILE}")
    restore_stagger_seconds="$(config_int 'restore_stagger_seconds' 15)"
    if (( restore_stagger_seconds > 300 )); then
        bashio::log.warning "Config value 'restore_stagger_seconds' exceeds 300; using 15."
        restore_stagger_seconds="15"
    fi

    for (( index = 0; index < ${#addons_to_restart[@]}; index++ )); do
        slug="${addons_to_restart[${index}]}"
        [[ -z "${slug}" ]] && continue

        if (( restore_stagger_seconds > 0 )); then
            bashio::log.info "Waiting ${restore_stagger_seconds}s before restoring app '${slug}'."
            sleep "${restore_stagger_seconds}"
        fi

        if restore_start_addon "${slug}"; then
            if ! update_window_state --arg slug "${slug}" \
                ".addons_to_restart = ((.addons_to_restart // []) | map(select(. != \$slug)))"; then
                if [[ "${restore_only}" != "true" ]]; then
                    return 1
                fi
                restore_failed="true"
            fi
        elif [[ "${restore_only}" == "true" ]]; then
            restore_failed="true"
        else
            return 1
        fi
    done

    mapfile -t temporary_addons_to_stop < <(jq --raw-output '.temporary_addons_to_stop[]?' "${WINDOW_STATE_FILE}")
    if [[ "${restore_only}" == "true" ]]; then
        if (( ${#temporary_addons_to_stop[@]} > 0 )); then
            bashio::log.warning "Expired recovery state lists temporary apps to stop; leaving them running during restore-only cleanup."
        fi
    else
        for slug in "${temporary_addons_to_stop[@]}"; do
            [[ -z "${slug}" ]] && continue
            if restore_stop_addon "${slug}"; then
                if ! update_window_state --arg slug "${slug}" \
                    ".temporary_addons_to_stop = ((.temporary_addons_to_stop // []) | map(select(. != \$slug)))"; then
                    return 1
                fi
            else
                return 1
            fi
        done
    fi

    if restore_core_watchdog_if_needed "${core_watchdog_restore}"; then
        if ! update_window_state '.core_watchdog_restore = null'; then
            if [[ "${restore_only}" != "true" ]]; then
                return 1
            fi
            restore_failed="true"
        fi
    elif [[ "${restore_only}" == "true" ]]; then
        restore_failed="true"
    else
        return 1
    fi

    if [[ "${restore_only}" == "true" ]]; then
        if ! rm -f "${WINDOW_STATE_FILE}"; then
            bashio::log.error "Could not clear stale recovery state for '${window_name}'."
            return 1
        fi
        if [[ "${restore_failed}" == "true" ]]; then
            bashio::log.error "Restore-only cleanup for '${window_name}' had failures; stale recovery state was cleared to prevent a loop."
        else
            bashio::log.info "Restore-only cleanup for '${window_name}' completed; stale recovery state was cleared."
        fi
        return 0
    fi

    if jq --exit-status \
        '(.restart_core // false) == false
        and ((.addons_to_restart // []) | length) == 0
        and ((.temporary_addons_to_stop // []) | length) == 0
        and (.core_watchdog_restore // null) == null' \
        "${WINDOW_STATE_FILE}" > /dev/null; then
        rm -f "${WINDOW_STATE_FILE}"
        return 0
    fi

    bashio::log.error "Restore state for '${window_name}' still contains pending actions."
    return 1
}

# -----------------------------------------------------------------------------
# Retry incomplete restore passes until state is complete or the persisted
# attempt limit clears it.
# -----------------------------------------------------------------------------
restore_window_until_complete() {
    local restore_only="${1:-false}"
    local failed_passes=0

    while [[ -f "${WINDOW_STATE_FILE}" ]]; do
        if restore_window_from_state "${restore_only}"; then
            return 0
        fi

        if [[ ! -f "${WINDOW_STATE_FILE}" ]]; then
            return 1
        fi

        failed_passes="$(( failed_passes + 1 ))"
        if (( failed_passes > MAX_RESTORE_ATTEMPTS )); then
            bashio::log.error "Restore could not make durable progress after ${MAX_RESTORE_ATTEMPTS} attempts; clearing recovery state and returning to normal scheduling."
            rm -f "${WINDOW_STATE_FILE}"
            return 1
        fi

        bashio::log.warning "Restore remains incomplete; retrying in ${RESTORE_PASS_RETRY_SECONDS}s."
        sleep "${RESTORE_PASS_RETRY_SECONDS}"
    done

    return 0
}

# -----------------------------------------------------------------------------
# Resume an interrupted active window, or safely clean up an expired/legacy
# state file without stopping anything.
# -----------------------------------------------------------------------------
recover_window_from_state() {
    local window_end_epoch
    local window_name
    local now_epoch
    local remaining_seconds

    if [[ ! -f "${WINDOW_STATE_FILE}" ]]; then
        return 0
    fi

    if ! jq --exit-status 'type == "object"' "${WINDOW_STATE_FILE}" > /dev/null; then
        bashio::log.error "Active-window recovery state is invalid JSON; clearing it to prevent a restart loop."
        rm -f "${WINDOW_STATE_FILE}"
        return 0
    fi

    window_end_epoch="$(jq --raw-output '.window_end_epoch // 0' "${WINDOW_STATE_FILE}")"
    window_name="$(jq --raw-output '.window_name // "unknown maintenance window"' "${WINDOW_STATE_FILE}")"
    now_epoch="$(date +%s)"

    if [[ ! "${window_end_epoch}" =~ ^[0-9]+$ ]] || (( window_end_epoch <= 0 )); then
        bashio::log.warning "Found recovery state for '${window_name}' with no valid end time; the window is long over or predates this state format. Running restore-only cleanup."
        restore_window_until_complete true || true
        return 0
    fi

    if (( now_epoch >= window_end_epoch )); then
        bashio::log.warning "Found recovery state for '${window_name}', but the window is long over. Running restore-only cleanup without stopping services."
        restore_window_until_complete true || true
        return 0
    fi

    remaining_seconds="$(( window_end_epoch - now_epoch ))"
    bashio::log.warning "Found active maintenance window state for '${window_name}'; resuming the remaining ${remaining_seconds}s."
    wait_until_epoch "${window_end_epoch}"
    if ! restore_window_until_complete false; then
        bashio::log.error "Restore for '${window_name}' did not complete before its retry limit."
    fi
}

# -----------------------------------------------------------------------------
# Restore services if the app is terminated during an active window.
# -----------------------------------------------------------------------------
handle_shutdown() {
    local signal_name="${1:-signal}"

    bashio::log.warning "Maintenance Window app received ${signal_name}; checking for active restore state."
    restore_window_until_complete auto || true
    exit 0
}

# -----------------------------------------------------------------------------
# Enter the maintenance window: start/stop apps + Core, hold, then restore.
# Argument: window duration in minutes.
#
# Order of operations:
#   1. Start temporary apps that should be available during the window.
#   2. Stop selected apps first (they may depend on Core).
#   3. Stop Core.
#   4. Sleep for the window duration.
#   5. Start Core and stopped apps, then stop temporary apps.
# -----------------------------------------------------------------------------
run_maintenance_window() {
    local duration_minutes="${1}"
    local name="${2:-Scheduled maintenance}"
    local window_index="${3}"
    local slug
    local -a addons_to_restart=()
    local -a temporary_addons_to_stop=()
    local core_will_stop="false"
    local core_watchdog_restore="null"
    local window_end_epoch

    bashio::log.notice "=== Entering maintenance window: ${name} (${duration_minutes} min) ==="
    window_end_epoch="$(( $(date +%s) + duration_minutes * 60 ))"

    # 1: start apps that should be temporarily available during the window.
    while IFS= read -r slug; do
        [[ -z "${slug}" ]] && continue
        if start_addon_if_stopped "${slug}"; then
            temporary_addons_to_stop+=("${slug}")
        fi
    done < <(config_list_with_fallback "windows[${window_index}].start_addons" 'start_addons')

    # 2 + 3: shut things down.
    while IFS= read -r slug; do
        [[ -z "${slug}" ]] && continue
        if stop_addon_if_running "${slug}"; then
            addons_to_restart+=("${slug}")
        fi
    done < <(config_list_with_fallback "windows[${window_index}].stop_addons" 'stop_addons')

    if should_stop_core_for_window "${duration_minutes}" "${window_index}"; then
        core_will_stop="true"
        if ! bashio::config.true 'dry_run'; then
            core_watchdog_restore="$(core_watchdog_restore_value)"
        fi
    fi

    if ! bashio::config.true 'dry_run'; then
        if ! write_window_state \
            "$(json_array "${addons_to_restart[@]}")" \
            "$(json_array "${temporary_addons_to_stop[@]}")" \
            "${core_will_stop}" \
            "${core_watchdog_restore}" \
            "${window_end_epoch}" \
            "${name}"; then
            core_will_stop="false"
            core_watchdog_restore="null"
        fi
    fi

    if [[ "${core_will_stop}" == "true" ]]; then
        pause_core_watchdog_if_needed "${core_watchdog_restore}"
        if ! stop_core; then
            bashio::log.warning "Core stop was not acknowledged; keeping the recovery state and continuing the window."
        fi
    fi

    # 4: hold the window open until the persisted absolute end time.
    wait_until_epoch "${window_end_epoch}"

    # 5: bring things back using the same path as crash/watchdog recovery.
    if bashio::config.true 'dry_run'; then
        if [[ "${core_will_stop}" == "true" ]]; then
            start_core true
        fi
        for slug in "${addons_to_restart[@]}"; do
            start_addon "${slug}"
        done
        for slug in "${temporary_addons_to_stop[@]}"; do
            stop_addon "${slug}"
        done
        bashio::log.info "=== Maintenance window complete; everything restarted ==="
    else
        if restore_window_until_complete false; then
            bashio::log.info "=== Maintenance window complete; everything restarted ==="
        else
            bashio::log.error "Maintenance window ended, but restore did not complete before its retry limit."
        fi
    fi
}

# -----------------------------------------------------------------------------
# Convert ISO weekday number to config day name.
# -----------------------------------------------------------------------------
weekday_name() {
    local weekday_number="${1}"

    case "${weekday_number}" in
        1) echo "mon" ;;
        2) echo "tue" ;;
        3) echo "wed" ;;
        4) echo "thu" ;;
        5) echo "fri" ;;
        6) echo "sat" ;;
        7) echo "sun" ;;
        *) return 1 ;;
    esac
}

# -----------------------------------------------------------------------------
# Return true when a window is configured for the given day name.
# -----------------------------------------------------------------------------
window_runs_on_day() {
    local window_index="${1}"
    local day_name="${2}"
    local configured_day
    local configured_days

    configured_days="$(bashio::config "windows[${window_index}].days" '__all__')"
    if [[ "${configured_days}" == "__all__" || -z "${configured_days}" ]]; then
        return 0
    fi

    while IFS= read -r configured_day; do
        [[ "${configured_day}" == "${day_name}" ]] && return 0
    done <<< "${configured_days}"

    return 1
}

# -----------------------------------------------------------------------------
# Return the number of configured windows.
# -----------------------------------------------------------------------------
window_count() {
    local count

    count="$(bashio::config 'windows | length' 0)"
    if [[ "${count}" =~ ^[0-9]+$ ]]; then
        echo "${count}"
        return 0
    fi

    echo 0
}

# -----------------------------------------------------------------------------
# Find the next configured maintenance window.
# Output fields: wait_seconds, duration_minutes, name, formatted_start, window_index.
# -----------------------------------------------------------------------------
next_window() {
    local now_epoch
    local count
    local window_index
    local day_offset
    local start_time
    local duration_minutes
    local name
    local candidate_date
    local candidate_day_number
    local candidate_day_name
    local candidate_epoch
    local best_epoch=0
    local best_duration_minutes=""
    local best_name=""
    local best_start=""
    local best_window_index=""

    now_epoch="$(date +%s)"
    count="$(window_count)"

    if (( count == 0 )); then
        return 1
    fi

    for (( window_index = 0; window_index < count; window_index++ )); do
        start_time="$(bashio::config "windows[${window_index}].start_time")"
        duration_minutes="$(bashio::config "windows[${window_index}].duration_minutes")"
        name="$(bashio::config "windows[${window_index}].name" "Window $(( window_index + 1 ))")"

        if [[ ! "${duration_minutes}" =~ ^[0-9]+$ ]]; then
            bashio::log.warning "Skipping window '${name}' because duration_minutes is invalid: ${duration_minutes}"
            continue
        fi

        for day_offset in 0 1 2 3 4 5 6 7; do
            candidate_date="$(date -d "today + ${day_offset} days" +%F)"
            candidate_day_number="$(date -d "${candidate_date}" +%u)"
            candidate_day_name="$(weekday_name "${candidate_day_number}")"

            if ! window_runs_on_day "${window_index}" "${candidate_day_name}"; then
                continue
            fi

            candidate_epoch="$(date -d "${candidate_date} ${start_time}:00" +%s)"
            if (( candidate_epoch <= now_epoch )); then
                continue
            fi

            if (( best_epoch == 0 || candidate_epoch < best_epoch )); then
                best_epoch="${candidate_epoch}"
                best_duration_minutes="${duration_minutes}"
                best_name="${name}"
                best_start="$(date -d "@${candidate_epoch}" '+%Y-%m-%d %H:%M:%S %Z')"
                best_window_index="${window_index}"
            fi
        done
    done

    if (( best_epoch == 0 )); then
        return 1
    fi

    printf '%s\t%s\t%s\t%s\t%s\n' \
        "$(( best_epoch - now_epoch ))" \
        "${best_duration_minutes}" \
        "${best_name}" \
        "${best_start}" \
        "${best_window_index}"
}

# -----------------------------------------------------------------------------
# Main loop.
# -----------------------------------------------------------------------------
main() {
    bashio::log.info "Maintenance Window app started."
    bashio::log.info "dry_run=$(bashio::config 'dry_run'), restart_core=$(bashio::config 'restart_core')"

    trap 'handle_shutdown INT' INT
    trap 'handle_shutdown TERM' TERM

    if bashio::config.true 'dry_run'; then
        bashio::log.notice "DRY RUN mode is enabled — no apps or Core will actually be stopped."
    fi

    recover_window_from_state
    write_addon_inventory

    while true; do
        local next_window_details
        local wait_seconds
        local duration_minutes
        local window_name
        local starts_at
        local window_index

        if ! next_window_details="$(next_window)"; then
            bashio::log.warning "No future maintenance windows are configured; checking again in ${NO_WINDOW_SLEEP_SECONDS}s."
            sleep "${NO_WINDOW_SLEEP_SECONDS}"
            continue
        fi

        IFS=$'\t' read -r wait_seconds duration_minutes window_name starts_at window_index <<< "${next_window_details}"

        bashio::log.info "Next maintenance window: ${window_name} at ${starts_at} for ${duration_minutes} min."
        sleep "${wait_seconds}"

        run_maintenance_window "${duration_minutes}" "${window_name}" "${window_index}"
    done
}
