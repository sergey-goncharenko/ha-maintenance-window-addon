# Changelog

All notable changes to the Maintenance Window add-on are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

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
- AppArmor profile, documentation, and English translations.
