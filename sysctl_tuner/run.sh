#!/bin/sh
# ==============================================================================
# Kernel VM Tuner - POSIX sh, no bashio, plain Alpine base.
#
# Deliberately dependency-free. The Home Assistant base images bundle bashio and
# are ~25 MB extracted; on a 1 GB Pi already swapping to SD, pulling and
# unpacking that during an add-on build was itself enough to stall the host and
# trip the hardware watchdog (case 2026-08-18, 12:56 watchdog reset). Alpine is
# ~8 MB extracted and needs no apk step, so the build stays cheap enough to
# survive.
#
# Options are read straight from /data/options.json. The schema is flat scalars
# only, so a small sed extractor is sufficient and avoids installing jq.
#
# Needs full_access (privileged) because vm.* sysctls are not namespaced, which
# means Protection mode must be DISABLED for this add-on.
# ==============================================================================

set -u

OPTIONS_FILE="/data/options.json"
SYSCTL_DIR="/proc/sys/vm"
FAILURES=0
CHANGED=0

log() { printf '[%s] %-6s %s\n' "$(date '+%H:%M:%S')" "$1" "$2"; }

# Extract a scalar value for a key. Empty output means "not set".
get_opt() {
    [ -r "${OPTIONS_FILE}" ] || return 0
    tr -d '\n' < "${OPTIONS_FILE}" \
        | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\([^,}]*\).*/\1/p" \
        | tr -d '" ' \
        | head -n1
}

DRY_RUN="$(get_opt dry_run)"
[ -z "${DRY_RUN}" ] && DRY_RUN="true"

apply_tunable() {
    key="$1"
    path="${SYSCTL_DIR}/${key}"
    desired="$(get_opt "${key}")"

    if [ -z "${desired}" ]; then
        log INFO "${key}: not configured, leaving kernel default"
        return 0
    fi

    if [ ! -e "${path}" ]; then
        log WARN "${key}: ${path} absent on this kernel, skipping"
        return 0
    fi

    current="$(cat "${path}" 2>/dev/null || echo '?')"

    if [ "${current}" = "${desired}" ]; then
        log INFO "${key}: already ${current}"
        return 0
    fi

    if [ "${DRY_RUN}" = "true" ]; then
        log NOTICE "[dry_run] ${key}: ${current} -> ${desired}"
        return 0
    fi

    # The redirection fails before the command runs when /proc/sys is read-only,
    # so it has to be caught in a subshell or the raw error escapes to stderr.
    if ! ( printf '%s\n' "${desired}" > "${path}" ) 2>/dev/null; then
        log ERROR "${key}: cannot write ${path} (read-only)."
        log ERROR "  Protection mode must be DISABLED for this add-on."
        log ERROR "  Settings -> Add-ons -> Kernel VM Tuner -> Protection mode: off, then restart."
        FAILURES=$((FAILURES + 1))
        return 1
    fi

    readback="$(cat "${path}" 2>/dev/null || echo '?')"
    if [ "${readback}" != "${desired}" ]; then
        log ERROR "${key}: wrote ${desired} but kernel reports ${readback}"
        FAILURES=$((FAILURES + 1))
        return 1
    fi

    log INFO "${key}: ${current} -> ${readback}"
    CHANGED=$((CHANGED + 1))
    return 0
}

log INFO "Kernel VM Tuner starting."
[ "${DRY_RUN}" = "true" ] && log NOTICE "dry_run enabled - nothing will be applied."

avail="$(awk '/^MemAvailable:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null)"
total="$(awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null)"
log INFO "Memory: ${avail:-?} MiB available of ${total:-?} MiB"

# dirty_*_bytes are applied last: writing *_bytes zeroes the corresponding
# *_ratio and vice versa.
for tunable in swappiness watermark_scale_factor min_free_kbytes vfs_cache_pressure \
               dirty_background_bytes dirty_bytes; do
    apply_tunable "${tunable}" || true
done

if [ "${FAILURES}" -gt 0 ]; then
    log ERROR "Finished with ${FAILURES} failure(s); ${CHANGED} applied."
    exit 1
fi

if [ "${DRY_RUN}" = "true" ]; then
    log NOTICE "dry_run complete - set dry_run: false to apply."
else
    log INFO "Applied ${CHANGED} value(s) successfully."
fi

if [ "$(get_opt keep_running)" = "true" ]; then
    log INFO "keep_running set; staying resident."
    while true; do sleep 3600; done
fi

log INFO "Done. This add-on now exits; 'stopped' is the expected state."
exit 0
