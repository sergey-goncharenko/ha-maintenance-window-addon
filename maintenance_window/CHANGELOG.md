# Changelog

All notable changes to the Maintenance Window add-on are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## 0.8.8

- Make per-window `restart_core` explicit so app-only windows such as temporary
  SSH access do not fall back to a global Core restart setting.
- Treat missing per-window `restart_core` as disabled when that window defines
  app action overrides.

## 0.8.7

- Update public-facing terminology from add-ons to apps while preserving legacy
  configuration keys such as `stop_addons` and `start_addons`.

## 0.8.6

- Allow window `days` to be empty or omitted; such windows now run every day.

## 0.8.5

- Add `pause_core_watchdog`, enabled by default, to temporarily pause the Home
  Assistant Core watchdog during intentional Core stop/start windows and restore
  the previous watchdog setting afterward.

## 0.8.4

- Wait for the Home Assistant Core API to become ready after starting Core,
  before declaring the maintenance window complete.
- Add `core_start_timeout_seconds` to control the Core startup readiness wait.

## 0.8.3

- Keep the s6 long-run service finish hook from halting the whole add-on
  container on ordinary scheduler exits, reducing misleading post-window add-on
  restarts.
- Log the shutdown signal received by the scheduler before running restore
  checks.

## 0.8.2

- Normalize the s6 service `type` file to LF-only `longrun` content and add
  validation to prevent CRLF service metadata from reaching images.

## 0.8.1

- Fix ShellCheck warning in add-on inventory Markdown generation.

## 0.8.0

- Add `list_addons_on_startup` to log installed Supervisor add-ons and write a
  copyable add-on slug inventory to `/addon_config/available_addons.md`.
- Refresh generated artwork to a plain Home Assistant-style home outline over a
  yellow/black maintenance tape pattern.

## 0.7.4

- Refresh generated artwork to a Home Assistant-style home mark over a full
  yellow/black maintenance tape pattern.

## 0.7.3

- Simplify generated artwork to a black/yellow Home Assistant-style house mark.

## 0.7.2

- Simplify generated artwork to a Home Assistant-style house mark in a
  yellow/black maintenance tape pattern.

## 0.7.1

- Refresh generated artwork with yellow/black maintenance tape and traffic cone
  visual cues.

## 0.7.0

- Add generated `icon.png` and `logo.png` artwork.
- Clarify positioning around external maintenance windows: host backups,
  network/router work, hardware maintenance, and sensor work.
- Document Core-independent add-on start use cases, including opening SSH during
  the same window that stops Core.
- Rename global action labels to make clear they are defaults for windows.

## 0.6.2

- Fix the s6 service runner so it calls the sourced `main` function instead of
  trying to execute it as an external command.

## 0.6.1

- Fix per-window action schema optional markers so Home Assistant can save
  windows that omit `restart_core`, `stop_addons`, or `start_addons`.

## 0.6.0

- Add per-window `restart_core`, `stop_addons`, and `start_addons` overrides.
- Keep global action options as defaults for windows that omit per-window
  actions.

## 0.5.0

- Publish and use a prebuilt GHCR image so HAOS does not need to build the add-on
  locally during installation.
- Remove deprecated architectures and keep support to `aarch64` and `amd64`.
- Remove deprecated `build.yaml` metadata.

## 0.4.3

- Re-enable AppArmor with a minimal profile based on current Home Assistant
  add-on profile patterns to avoid the stale-profile unload path.

## 0.4.2

- Disable the custom AppArmor profile for now to unblock installation on HAOS.

## 0.4.1

- Fix the AppArmor profile so Supervisor can load it during installation.

## 0.4.0

- Make the default configuration non-mutating with `dry_run: true` and
  `restart_core: false`.
- Require `core_stop_confirmation: STOP_CORE` before Home Assistant Core may be
  stopped.
- Add `startup_grace_seconds` and `max_core_stop_minutes` safeguards to prevent
  immediate or excessively long Core stop windows.

## 0.3.0

- Add `start_addons` for temporarily starting add-ons during a maintenance
  window, then stopping only the add-ons that were not already running.
- Persist active-window restore state so watchdog restarts can recover Core and
  add-on state after an interrupted window.

## 0.2.0

- Implement real day/time scheduling for configured maintenance windows.
- Skip the Maintenance Window add-on if it is accidentally listed in
  `stop_addons`.
- Restart only add-ons that were running when the window began.

## 0.1.1

- Update repository metadata to point to the public GitHub repository.

## 0.1.0

- Initial scaffold of the Maintenance Window add-on.
- Add-on structure: `config.json`, `Dockerfile`, `build.yaml`, `run.sh`.
- s6-overlay (v3) long-run service under `rootfs/etc/s6-overlay/s6-rc.d`.
- Shared scheduler library with Supervisor API helpers to stop/start Core and
  add-ons (`dry_run` and `restart_core` guards in place).
- Placeholder scheduling loop (time/day matching marked `TODO`).
- Documentation and English translations.
