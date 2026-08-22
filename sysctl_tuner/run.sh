#!/bin/sh
# ==============================================================================
# Kernel VM Tuner - POSIX sh, no bashio, plain Alpine base.
#
# Deliberately dependency-free. The Home Assistant base images bundle bashio and
# are ~25 MB extracted; on a 1 GB Pi already swapping to SD, pulling and
# unpacking that during an add-on build was itself enough to stall the host and
# trip the hardware watchdog. Alpine is ~8 MB extracted and needs no apk step.
#
# WHY THE REMOUNT:
#   Docker mounts /proc/sys read-only inside containers. That is a *mount* flag,
#   not a permission problem - writes fail with EROFS even as root with
#   full_access (verified on the target host: "read-only file system", and
#   Supervisor correctly reported protected=false, full_access=true,
#   apparmor=disable). A privileged container owns its mount namespace, so it
#   may remount /proc/sys read-write. The remount affects only this container's
#   view; vm.* sysctls themselves are NOT namespaced, so writing them still
#   changes the host kernel - which is the whole point.
#
# Needs full_access (privileged) because vm.* sysctls are not namespaced, which
# means Protection mode must be DISABLED for this add-on.
# ==============================================================================

set -u

OPTIONS_FILE="/data/options.json"
SYSCTL_DIR="/proc/sys/vm"
FAILURES=0
CHANGED=0
REMOUNTED="no"

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

# ---------------------------------------------------------------- diagnostics
# Printed every run: when this add-on cannot write, these three lines say why.
report_environment() {
    caps="$(awk '/^CapEff:/ {print $2}' /proc/self/status 2>/dev/null)"
    log INFO "Effective capabilities: ${caps:-unknown} (0000000000000000 = unprivileged)"

    procsys_opts="$(awk '$2 == "/proc/sys" {print $4}' /proc/self/mounts 2>/dev/null | head -n1)"
    if [ -n "${procsys_opts}" ]; then
        log INFO "/proc/sys mount options: ${procsys_opts}"
    else
        log INFO "/proc/sys has no separate mount entry (inherits /proc)"
    fi
}

# Docker mounts /proc/sys ro; a privileged container can flip it back.
ensure_writable() {
    probe="${SYSCTL_DIR}/swappiness"
    [ -e "${probe}" ] || return 0

    if ( : > "${probe}" ) 2>/dev/null; then
        return 0
    fi

    log INFO "/proc/sys is read-only; attempting remount rw (requires full_access)"
    if mount -o remount,rw /proc/sys 2>/dev/null; then
        REMOUNTED="yes"
        log INFO "remount succeeded"
        return 0
    fi

    # Some kernels require naming the source explicitly.
    if mount -t proc -o remount,rw proc /proc 2>/dev/null; then
        REMOUNTED="yes"
        log INFO "remount of /proc succeeded"
        return 0
    fi

    log WARN "remount failed - writes will very likely fail"
    return 1
}

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
        log ERROR "${key}: write to ${path} failed."
        log ERROR "  Check that Protection mode is OFF (add-on Info tab)."
        log ERROR "  Diagnostics above show capabilities and /proc/sys mount flags."
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

# ------------------------------------------------------------------- main ----
log INFO "Kernel VM Tuner starting."
[ "${DRY_RUN}" = "true" ] && log NOTICE "dry_run enabled - nothing will be applied."

avail="$(awk '/^MemAvailable:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null)"
total="$(awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null)"
log INFO "Memory: ${avail:-?} MiB available of ${total:-?} MiB"

report_environment
[ "${DRY_RUN}" = "true" ] || ensure_writable || true

# dirty_*_bytes are applied last: writing *_bytes zeroes the corresponding
# *_ratio and vice versa.
for tunable in swappiness watermark_scale_factor min_free_kbytes vfs_cache_pressure \
               dirty_background_bytes dirty_bytes; do
    apply_tunable "${tunable}" || true
done

[ "${REMOUNTED}" = "yes" ] && log INFO "(/proc/sys was remounted rw inside this container only)"

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
