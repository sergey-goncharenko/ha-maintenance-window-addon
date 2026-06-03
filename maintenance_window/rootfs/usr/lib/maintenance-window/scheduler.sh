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
# The functions below are intentionally written as PLACEHOLDERS with clearly
# marked TODO sections. The structure, Supervisor API calls, and safety guards
# are in place; refine the scheduling math and edge-case handling to taste.
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
# Stop a single add-on by slug.
# -----------------------------------------------------------------------------
stop_addon() {
    local slug="${1}"

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
    local -a addons=()

    # Collect configured add-on slugs into an array.
    for slug in $(bashio::config 'stop_addons'); do
        addons+=("${slug}")
    done

    bashio::log.info "=== Entering maintenance window (${duration_minutes} min) ==="

    # 1 + 2: shut things down.
    for slug in "${addons[@]}"; do
        stop_addon "${slug}"
    done
    stop_core

    # 3: hold the window open.
    # TODO: consider checking for an early-abort signal during this sleep.
    sleep "$(( duration_minutes * 60 ))"

    # 4 + 5: bring things back. Start Core first, then add-ons.
    start_core
    for slug in "${addons[@]}"; do
        start_addon "${slug}"
    done

    bashio::log.info "=== Maintenance window complete; everything restarted ==="
}

# -----------------------------------------------------------------------------
# Compute the number of seconds to sleep until the next scheduled window.
#
# TODO: implement real scheduling. This should:
#   * iterate over each entry in the 'windows' config list
#   * parse start_time (HH:MM) and the 'days' list
#   * find the soonest matching future occurrence (respecting the container TZ)
#   * echo the number of seconds until that occurrence and which window index
#
# For now this is a placeholder that returns a fixed interval so the loop runs.
# -----------------------------------------------------------------------------
seconds_until_next_window() {
    # Placeholder: re-evaluate every 60 seconds.
    echo 60
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
        local wait_seconds
        wait_seconds="$(seconds_until_next_window)"

        bashio::log.debug "Sleeping ${wait_seconds}s until next scheduling check/window."
        sleep "${wait_seconds}"

        # TODO: only fire when an actual window is due. Until the scheduler is
        # implemented, the call below is gated so the placeholder doesn't keep
        # restarting Core every minute.
        #
        # run_maintenance_window "$(window_duration_for_now)"
    done
}
