#!/usr/bin/env bash
# ==============================================================================
# Maintenance Window — shared scheduler library
#
# This file contains the core logic for the add-on:
#   * read user configuration (via bashio / /data/options.json)
#   * wait until the next scheduled maintenance window
#   * temporarily start configured add-ons
#   * stop configured add-ons and (optionally) Home Assistant Core
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
#   POST /addons/<slug>/stop        Stop an add-on
#   POST /addons/<slug>/start       Start an add-on
#   GET  /addons/<slug>/info        Inspect an add-on (state, etc.)
# Requires config.json: "hassio_api": true and "hassio_role": "manager".
# ==============================================================================
# shellcheck shell=bash

readonly SUPERVISOR_API="http://supervisor"
readonly HOMEASSISTANT_API="${SUPERVISOR_API}/core/api"
readonly ADDON_SLUG="maintenance_window"
readonly NO_WINDOW_SLEEP_SECONDS="300"
readonly WINDOW_STATE_FILE="/data/maintenance-window-state.json"
readonly ADDON_INVENTORY_FILE="/addon_config/available_addons.md"
readonly CORE_READY_POLL_SECONDS="5"
STARTED_AT_EPOCH="$(date +%s)"
readonly STARTED_AT_EPOCH

# -----------------------------------------------------------------------------
# Return true when the configured add-on slug points at this add-on.
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
        --request "${method}" \
        --header "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
        --header "Content-Type: application/json" \
        "${HOMEASSISTANT_API}${path}"
}

# -----------------------------------------------------------------------------
# Return the Supervisor state for an add-on slug, such as "started" or "stopped".
# -----------------------------------------------------------------------------
addon_state() {
    local slug="${1}"
    local response

    response="$(supervisor_api "GET" "/addons/${slug}/info")"
    jq --raw-output '.data.state // empty' <<< "${response}"
}

# -----------------------------------------------------------------------------
# Write and log installed Supervisor add-ons so users can copy slugs into config.
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
        bashio::log.warning "Could not list Supervisor add-ons for inventory."
        return 0
    fi

    mkdir -p "$(dirname "${ADDON_INVENTORY_FILE}")"

    {
        echo "# Available Supervisor add-ons"
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
    bashio::log.info "Wrote Supervisor add-on inventory (${count} add-ons) to ${ADDON_INVENTORY_FILE}"
    bashio::log.info "Installed add-ons available for Maintenance Window actions:"

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
# Read a boolean config value that can fall back from a window field to a global.
# -----------------------------------------------------------------------------
config_true_with_fallback() {
    local window_key="${1}"
    local global_key="${2}"
    local value

    value="$(bashio::config "${window_key}" '__missing__')"
    if [[ "${value}" == "__missing__" ]]; then
        bashio::config.true "${global_key}"
        return $?
    fi

    [[ "${value}" == "true" ]]
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

    if ! config_true_with_fallback "windows[${window_index}].restart_core" 'restart_core'; then
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
        bashio::log.warning "Core stop blocked by startup grace period (${uptime_seconds}/${startup_grace_seconds}s since add-on start)."
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
# Stop a single add-on by slug.
# -----------------------------------------------------------------------------
stop_addon() {
    local slug="${1}"

    if addon_is_self "${slug}"; then
        bashio::log.warning "Skipping configured add-on '${slug}' because the add-on must not stop itself."
        return 1
    fi

    if bashio::config.true 'dry_run'; then
        bashio::log.notice "[dry_run] Would stop add-on: ${slug}"
        return 0
    fi

    bashio::log.info "Stopping add-on: ${slug}"
    if ! supervisor_api "POST" "/addons/${slug}/stop"; then
        bashio::log.warning "Failed to stop add-on: ${slug}"
    fi
}

# -----------------------------------------------------------------------------
# Stop an add-on only if it is currently running.
# Returns 0 when the add-on should be restarted at the end of the window.
# -----------------------------------------------------------------------------
stop_addon_if_running() {
    local slug="${1}"
    local state

    if addon_is_self "${slug}"; then
        bashio::log.warning "Skipping configured add-on '${slug}' because the add-on must not stop itself."
        return 1
    fi

    if bashio::config.true 'dry_run'; then
        bashio::log.notice "[dry_run] Would inspect and stop add-on if running: ${slug}"
        return 0
    fi

    if ! state="$(addon_state "${slug}")"; then
        bashio::log.warning "Could not inspect add-on '${slug}'; will try to stop it and restart it later."
        stop_addon "${slug}" || true
        return 0
    fi

    if [[ "${state}" != "started" ]]; then
        bashio::log.info "Add-on '${slug}' is '${state:-unknown}', so it will not be stopped or restarted."
        return 1
    fi

    stop_addon "${slug}" || true
    return 0
}

# -----------------------------------------------------------------------------
# Start a single add-on by slug.
# -----------------------------------------------------------------------------
start_addon() {
    local slug="${1}"

    if bashio::config.true 'dry_run'; then
        bashio::log.notice "[dry_run] Would start add-on: ${slug}"
        return 0
    fi

    bashio::log.info "Starting add-on: ${slug}"
    if ! supervisor_api "POST" "/addons/${slug}/start"; then
        bashio::log.warning "Failed to start add-on: ${slug}"
    fi
}

# -----------------------------------------------------------------------------
# Start an add-on only if it is currently stopped.
# Returns 0 when the add-on should be stopped at the end of the window.
# -----------------------------------------------------------------------------
start_addon_if_stopped() {
    local slug="${1}"
    local state

    if addon_is_self "${slug}"; then
        bashio::log.info "Add-on '${slug}' is already running because it is this add-on."
        return 1
    fi

    if bashio::config.true 'dry_run'; then
        bashio::log.notice "[dry_run] Would inspect and start add-on if stopped: ${slug}"
        return 0
    fi

    if ! state="$(addon_state "${slug}")"; then
        bashio::log.warning "Could not inspect add-on '${slug}'; will try to start it and stop it later."
        start_addon "${slug}" || true
        return 0
    fi

    if [[ "${state}" == "started" ]]; then
        bashio::log.info "Add-on '${slug}' is already started, so it will not be stopped at the end of the window."
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
    fi
}

# -----------------------------------------------------------------------------
# Inspect and update Home Assistant Core watchdog through Supervisor.
# -----------------------------------------------------------------------------
core_watchdog_state() {
    local response

    response="$(supervisor_api "GET" "/core/info")"
    jq --raw-output '.data.watchdog // empty' <<< "${response}"
}

set_core_watchdog() {
    local desired_state="${1}"

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

    case "${restore_value}" in
        true|false)
            bashio::log.info "Restoring Home Assistant Core watchdog to ${restore_value}."
            if ! set_core_watchdog "${restore_value}"; then
                bashio::log.warning "Could not restore Home Assistant Core watchdog to ${restore_value}."
            fi
            ;;
    esac
}

# -----------------------------------------------------------------------------
# Start Home Assistant Core.
# -----------------------------------------------------------------------------
wait_for_core_api() {
    local timeout_seconds
    local deadline
    local elapsed_seconds

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

        sleep "${CORE_READY_POLL_SECONDS}"
    done

    bashio::log.warning "Home Assistant Core API did not become ready within ${timeout_seconds}s; continuing restore anyway."
    return 1
}

start_core() {
    local force="${1:-false}"

    if [[ "${force}" != "true" ]] && ! bashio::config.true 'restart_core'; then
        return 0
    fi

    if bashio::config.true 'dry_run'; then
        bashio::log.notice "[dry_run] Would start Home Assistant Core"
        return 0
    fi

    bashio::log.info "Starting Home Assistant Core..."
    if ! supervisor_api "POST" "/core/start"; then
        bashio::log.error "Failed to start Home Assistant Core"
        return 0
    fi

    wait_for_core_api || true
}

# -----------------------------------------------------------------------------
# Persist the restore actions for the active window.
# -----------------------------------------------------------------------------
write_window_state() {
    local addons_to_restart_json="${1}"
    local temporary_addons_to_stop_json="${2}"
    local restart_core_json="${3}"
    local core_watchdog_restore_json="${4}"

    if bashio::config.true 'dry_run'; then
        return 0
    fi

    if ! jq --null-input \
        --argjson restart_core "${restart_core_json}" \
        --argjson core_watchdog_restore "${core_watchdog_restore_json}" \
        --argjson addons_to_restart "${addons_to_restart_json}" \
        --argjson temporary_addons_to_stop "${temporary_addons_to_stop_json}" \
        '{restart_core: $restart_core, core_watchdog_restore: $core_watchdog_restore, addons_to_restart: $addons_to_restart, temporary_addons_to_stop: $temporary_addons_to_stop}' \
        > "${WINDOW_STATE_FILE}"; then
        bashio::log.error "Failed to write active-window recovery state; refusing to stop Home Assistant Core."
        return 1
    fi
}

# -----------------------------------------------------------------------------
# Restore Core/add-ons from the persisted active-window state.
# -----------------------------------------------------------------------------
restore_window_from_state() {
    local should_start_core
    local core_watchdog_restore
    local slug

    if [[ ! -f "${WINDOW_STATE_FILE}" ]]; then
        return 0
    fi

    bashio::log.warning "Found active maintenance window state; restoring services."

    should_start_core="$(jq --raw-output '.restart_core // false' "${WINDOW_STATE_FILE}")"
    core_watchdog_restore="$(jq --raw-output '.core_watchdog_restore // "null"' "${WINDOW_STATE_FILE}")"
    if [[ "${should_start_core}" == "true" ]]; then
        start_core true
    fi

    while IFS= read -r slug; do
        [[ -z "${slug}" ]] && continue
        start_addon "${slug}"
    done < <(jq --raw-output '.addons_to_restart[]?' "${WINDOW_STATE_FILE}")

    while IFS= read -r slug; do
        [[ -z "${slug}" ]] && continue
        stop_addon "${slug}"
    done < <(jq --raw-output '.temporary_addons_to_stop[]?' "${WINDOW_STATE_FILE}")

    restore_core_watchdog_if_needed "${core_watchdog_restore}"

    rm -f "${WINDOW_STATE_FILE}"
}

# -----------------------------------------------------------------------------
# Restore services if the add-on is terminated during an active window.
# -----------------------------------------------------------------------------
handle_shutdown() {
    local signal_name="${1:-signal}"

    bashio::log.warning "Maintenance Window add-on received ${signal_name}; checking for active restore state."
    restore_window_from_state
    exit 0
}

# -----------------------------------------------------------------------------
# Enter the maintenance window: start/stop add-ons + core, hold, then restore.
# Argument: window duration in minutes.
#
# Order of operations:
#   1. Start temporary add-ons that should be available during the window.
#   2. Stop selected add-ons first (they may depend on Core).
#   3. Stop Core.
#   4. Sleep for the window duration.
#   5. Start Core and stopped add-ons, then stop temporary add-ons.
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

    bashio::log.notice "=== Entering maintenance window: ${name} (${duration_minutes} min) ==="

    # 1: start add-ons that should be temporarily available during the window.
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
            "${core_watchdog_restore}"; then
            core_will_stop="false"
            core_watchdog_restore="null"
        fi
    fi

    if [[ "${core_will_stop}" == "true" ]]; then
        pause_core_watchdog_if_needed "${core_watchdog_restore}"
        stop_core
    fi

    # 4: hold the window open.
    sleep "$(( duration_minutes * 60 ))"

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
    else
        restore_window_from_state
    fi

    bashio::log.info "=== Maintenance window complete; everything restarted ==="
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

    while IFS= read -r configured_day; do
        [[ "${configured_day}" == "${day_name}" ]] && return 0
    done < <(bashio::config "windows[${window_index}].days")

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
    bashio::log.info "Maintenance Window add-on started."
    bashio::log.info "dry_run=$(bashio::config 'dry_run'), restart_core=$(bashio::config 'restart_core')"

    trap 'handle_shutdown INT' INT
    trap 'handle_shutdown TERM' TERM

    if bashio::config.true 'dry_run'; then
        bashio::log.notice "DRY RUN mode is enabled — no add-ons or Core will actually be stopped."
    fi

    restore_window_from_state
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
