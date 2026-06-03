#!/usr/bin/env bash
# ==============================================================================
# Maintenance Window — shared scheduler library
#
# This file contains the core logic for the add-on:
#   * read user configuration (via bashio / /data/options.json)
#   * wait until the next scheduled maintenance window
#   * stop the configured add-ons and (optionally) Home Assistant Core
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
#   POST /addons/<slug>/stop        Stop an add-on
#   POST /addons/<slug>/start       Start an add-on
#   GET  /addons/<slug>/info        Inspect an add-on (state, etc.)
# Requires config.json: "hassio_api": true and "hassio_role": "manager".
# ==============================================================================
# shellcheck shell=bash

readonly SUPERVISOR_API="http://supervisor"
readonly ADDON_SLUG="maintenance_window"
readonly NO_WINDOW_SLEEP_SECONDS="300"

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
# Return the Supervisor state for an add-on slug, such as "started" or "stopped".
# -----------------------------------------------------------------------------
addon_state() {
    local slug="${1}"
    local response

    response="$(supervisor_api "GET" "/addons/${slug}/info")"
    jq --raw-output '.data.state // empty' <<< "${response}"
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
# Stop Home Assistant Core.
# -----------------------------------------------------------------------------
stop_core() {
    if ! bashio::config.true 'restart_core'; then
        bashio::log.info "restart_core is disabled; leaving Core running."
        return 0
    fi

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
# Start Home Assistant Core.
# -----------------------------------------------------------------------------
start_core() {
    if ! bashio::config.true 'restart_core'; then
        return 0
    fi

    if bashio::config.true 'dry_run'; then
        bashio::log.notice "[dry_run] Would start Home Assistant Core"
        return 0
    fi

    bashio::log.info "Starting Home Assistant Core..."
    if ! supervisor_api "POST" "/core/start"; then
        bashio::log.error "Failed to start Home Assistant Core"
    fi
}

# -----------------------------------------------------------------------------
# Enter the maintenance window: stop add-ons + core, hold, then restore.
# Argument: window duration in minutes.
#
# Order of operations:
#   1. Stop selected add-ons first (they may depend on Core).
#   2. Stop Core.
#   3. Sleep for the window duration.
#   4. Start Core.
#   5. Start the add-ons back up.
# -----------------------------------------------------------------------------
run_maintenance_window() {
    local duration_minutes="${1}"
    local name="${2:-Scheduled maintenance}"
    local slug
    local -a addons_to_restart=()

    bashio::log.notice "=== Entering maintenance window: ${name} (${duration_minutes} min) ==="

    # 1 + 2: shut things down.
    while IFS= read -r slug; do
        [[ -z "${slug}" ]] && continue
        if stop_addon_if_running "${slug}"; then
            addons_to_restart+=("${slug}")
        fi
    done < <(bashio::config 'stop_addons')

    stop_core

    # 3: hold the window open.
    sleep "$(( duration_minutes * 60 ))"

    # 4 + 5: bring things back. Start Core first, then add-ons.
    start_core
    for slug in "${addons_to_restart[@]}"; do
        start_addon "${slug}"
    done

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
# Output fields: wait_seconds, duration_minutes, name, formatted_start.
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
            fi
        done
    done

    if (( best_epoch == 0 )); then
        return 1
    fi

    printf '%s\t%s\t%s\t%s\n' \
        "$(( best_epoch - now_epoch ))" \
        "${best_duration_minutes}" \
        "${best_name}" \
        "${best_start}"
}

# -----------------------------------------------------------------------------
# Main loop.
# -----------------------------------------------------------------------------
main() {
    bashio::log.info "Maintenance Window add-on started."
    bashio::log.info "dry_run=$(bashio::config 'dry_run'), restart_core=$(bashio::config 'restart_core')"

    if bashio::config.true 'dry_run'; then
        bashio::log.notice "DRY RUN mode is enabled — no add-ons or Core will actually be stopped."
    fi

    while true; do
        local next_window_details
        local wait_seconds
        local duration_minutes
        local window_name
        local starts_at

        if ! next_window_details="$(next_window)"; then
            bashio::log.warning "No future maintenance windows are configured; checking again in ${NO_WINDOW_SLEEP_SECONDS}s."
            sleep "${NO_WINDOW_SLEEP_SECONDS}"
            continue
        fi

        IFS=$'\t' read -r wait_seconds duration_minutes window_name starts_at <<< "${next_window_details}"

        bashio::log.info "Next maintenance window: ${window_name} at ${starts_at} for ${duration_minutes} min."
        sleep "${wait_seconds}"

        run_maintenance_window "${duration_minutes}" "${window_name}"
    done
}
