# Maintenance Window HA Add-on Repository

[![CI](https://github.com/sergey-goncharenko/ha-maintenance-window-addon/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/sergey-goncharenko/ha-maintenance-window-addon/actions/workflows/ci.yml?query=branch%3Amain)

A Home Assistant add-on repository containing the **Maintenance Window** add-on.

## What it does

Maintenance Window provides controlled quiet windows for Home Assistant OS. At a
configured time it can gracefully **stop Home Assistant Core** and selected
add-ons, temporarily **start selected add-ons**, hold that state for a short
window, and then automatically restore everything when the window ends.

It is designed for maintenance that happens around Home Assistant, not only
inside Home Assistant: host backups, storage pressure, network outages, router
restarts, attached hardware maintenance, sensor work, or short break-glass access
windows.

Typical use cases:

- Give the host a quiet period for backups, host updates, or database maintenance.
- Reduce automation noise / device polling during the night.
- Pause Core while internet, router, NAS, sensor, or attached hardware work is in progress.
- Force a clean, scheduled restart of Core on a regular cadence.
- Temporarily open an add-on such as SSH for a short break-glass access window.
- Use different Core/add-on actions for different scheduled windows.

Unlike Home Assistant automations, this add-on runs independently from Home
Assistant Core. That means it can still perform scheduled add-on actions when
Core is stopped, broken, overloaded, or unresponsive.

## Quick start

Start with `dry_run: true` and schedule a window a few minutes ahead. Confirm the
log says what it would do, then switch `dry_run` to `false` only after you trust
the schedule.

For a Core maintenance window that also opens SSH while Core is down, put both
actions in the same window:

```yaml
log_level: info
dry_run: true
restart_core: false
core_stop_confirmation: ""
startup_grace_seconds: 300
max_core_stop_minutes: 10
core_start_timeout_seconds: 600
pause_core_watchdog: true
stop_addons: []
start_addons: []
windows:
	- name: Core quiet window with SSH
		start_time: "04:00"
		duration_minutes: 3
		restart_core: true
		stop_addons: []
		start_addons:
			- core_ssh
		days:
			- mon
			- tue
			- wed
			- thu
			- fri
			- sat
			- sun
```

After dry-run testing, enable real Core stop with:

```yaml
dry_run: false
core_stop_confirmation: "STOP_CORE"
```

## Add-ons in this repository

| Add-on | Description |
| ------ | ----------- |
| [Maintenance Window](./maintenance_window) | Scheduled quiet mode that stops & restarts Core and selected add-ons. |

## Installation

1. In Home Assistant, go to **Settings → Add-ons → Add-on Store**.
2. Click the **⋮** menu (top right) → **Repositories**.
3. Add `https://github.com/sergey-goncharenko/ha-maintenance-window-addon`.
4. Find **Maintenance Window** in the store and install it.

See the add-on's [documentation](./maintenance_window/DOCS.md) for configuration.

The add-on uses a prebuilt multi-architecture image published to GHCR, so HAOS
should pull the image during installation instead of building it locally.

## Safety defaults

The default configuration is non-mutating: `dry_run` is enabled and Core restarts
are disabled. To allow Home Assistant Core to be stopped, you must explicitly set
`restart_core: true` and `core_stop_confirmation: STOP_CORE`. The add-on also
blocks Core stops during a startup grace period and blocks windows longer than
the configured maximum Core stop duration. During intentional Core stop/start
windows, it can temporarily pause the Home Assistant Core watchdog and restores
the previous watchdog setting after Core recovery.

> ⚠️ This add-on can stop Home Assistant Core. While Core is stopped, automations,
> the UI, and integrations are unavailable. The add-on itself runs independently
> of Core and is responsible for starting Core again at the end of the window.

## Recovery

If a test behaves unexpectedly, disable Watchdog first, then stop the add-on from
the HAOS console or SSH:

```bash
ha addons stop 5e912390_maintenance_window
ha supervisor restart
ha core restart
```

If your repository hash differs, find the slug with:

```bash
ha addons list
```
