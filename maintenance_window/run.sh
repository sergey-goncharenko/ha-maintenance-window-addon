#!/usr/bin/env bash
# ==============================================================================
# Maintenance Window — standalone entrypoint
#
# This script is a convenience wrapper that simply hands control to the shared
# scheduler library. The add-on normally starts through the s6-overlay service
# at /etc/s6-overlay/s6-rc.d/maintenance_window/run, but this file lets you run
# the same logic directly (e.g. for local testing with `bash run.sh`).
# ==============================================================================
set -euo pipefail

# shellcheck source=maintenance_window/rootfs/usr/lib/maintenance-window/scheduler.sh
source /usr/lib/maintenance-window/scheduler.sh

main "$@"
