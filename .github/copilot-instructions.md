# Copilot instructions — Maintenance Window (Home Assistant add-on)

These instructions orient an AI agent working in this repository. Read them
fully before making changes.

## What this project is

A Home Assistant **add-on repository** containing one add-on: **Maintenance
Window**. The add-on provides a scheduled "quiet mode": at configured times it
gracefully **stops Home Assistant Core** (and, optionally, a user-selected list
of other add-ons), holds them down for a short window, then **restarts
everything automatically**.

The add-on runs as a long-running service that is independent of Home Assistant
Core — that independence is essential, because the add-on is what brings Core
back up after the window.

## Repository layout

```
maintenance-window-addon/
├─ repository.yaml              # add-on repository metadata
├─ README.md                   # repo-level overview
├─ .github/copilot-instructions.md
└─ maintenance_window/         # THE add-on (slug: maintenance_window)
   ├─ config.json              # add-on manifest: arch, options, schema, API perms
   ├─ build.yaml               # per-arch base images
   ├─ Dockerfile               # Alpine HA base; installs bash/jq/curl; copies rootfs/
   ├─ run.sh                   # standalone entrypoint (sources scheduler.sh)
   ├─ apparmor.txt             # AppArmor profile
   ├─ DOCS.md                  # user-facing docs
   ├─ CHANGELOG.md
   ├─ ASSETS.md                # reminder: icon.png / logo.png are still TODO
   ├─ translations/en.yaml     # option name/description translations
   └─ rootfs/
      ├─ etc/s6-overlay/s6-rc.d/
      │  ├─ maintenance_window/{type,run,finish}   # s6 v3 long-run service
      │  └─ user/contents.d/maintenance_window     # enables the service
      └─ usr/lib/maintenance-window/scheduler.sh   # CORE LOGIC lives here
```

**Most implementation work happens in
`maintenance_window/rootfs/usr/lib/maintenance-window/scheduler.sh`.**

## Conventions (follow these)

- **Base image / s6-overlay v3.** The add-on uses `init: false` and the modern
  `s6-rc.d` layout. Service scripts use the `#!/command/with-contenv bashio`
  shebang. Do not reintroduce a v2 `services.d` layout or set `init: true`.
- **bashio for everything.** Read config with `bashio::config '<key>'`,
  booleans with `bashio::config.true '<key>'`, and log with
  `bashio::log.info/notice/warning/error/debug`. Avoid hand-parsing
  `/data/options.json`.
- **Shell style.** Bash with `set -euo pipefail` in standalone scripts. Quote
  variables. Keep functions small and single-purpose. ShellCheck-clean
  (`timonwong.shellcheck` is a recommended extension).
- **config.json (not YAML).** This project intentionally uses `config.json`.
  Keep `options` and `schema` in sync — every option needs a schema entry and a
  default, and every schema key should have a translation in
  `translations/en.yaml`.
- **Bump `version` in `config.json` and add a `CHANGELOG.md` entry** for any
  user-visible change.

## Supervisor API (how Core/add-ons are controlled)

Authenticate every call with the add-on's `SUPERVISOR_TOKEN` as a bearer token
against `http://supervisor`. Use the `supervisor_api <METHOD> <PATH>` helper in
`scheduler.sh`.

| Action | Endpoint |
| ------ | -------- |
| Stop Core | `POST /core/stop` |
| Start Core | `POST /core/start` |
| Stop add-on | `POST /addons/<slug>/stop` |
| Start add-on | `POST /addons/<slug>/start` |
| Inspect add-on | `GET /addons/<slug>/info` |
| List add-ons | `GET /addons` |

This requires `"hassio_api": true` and `"hassio_role": "manager"` in
`config.json` (already set). If you add Home Assistant notifications/events,
also set `"homeassistant_api": true` and call via `http://supervisor/core/api`.

Reference docs:
- Add-on config: https://developers.home-assistant.io/docs/add-ons/configuration
- Supervisor API: https://developers.home-assistant.io/docs/api/supervisor/endpoints
- Add-on services (s6): https://developers.home-assistant.io/docs/add-ons/service
- Example add-ons: https://github.com/home-assistant/addons/tree/master/example

## Current implementation status

- ✅ Stop/start helpers for Core and add-ons, with `dry_run` and `restart_core`
  guards (`scheduler.sh`).
- ✅ s6 service wiring and standalone `run.sh`.
- ⛔ **Scheduling is a placeholder.** `seconds_until_next_window()` returns a
  fixed interval and the `run_maintenance_window` call in `main` is commented
  out so it does not fire. Implementing real time/day matching is the main
  remaining task.

When implementing the scheduler:
1. Iterate `windows` from config; parse `start_time` (`HH:MM`) and `days`.
2. Compute the soonest future occurrence in the **host timezone**.
3. Sleep until then, run the window for `duration_minutes`, then loop.
4. Respect `dry_run` (log only) and `restart_core` (skip Core).

## Safety rules — do not violate

- The add-on must **never stop itself**, and must always attempt to **start Core
  again** even if an add-on start/stop fails (log the failure, keep going).
- Treat `dry_run: true` as authoritative: in dry-run mode, make **no** mutating
  Supervisor API calls.
- Stop add-ons before Core; start Core before add-ons.
- Do not commit secrets or the `SUPERVISOR_TOKEN`.

## Validation

There is no compiler. Validate changes by:
- Running ShellCheck on shell scripts.
- Confirming `config.json` is valid JSON and `options`/`schema`/translations
  stay aligned.
- Building locally with the HA builder or testing `run.sh` logic in isolation
  (use `dry_run: true`).

## Open design questions (resolve with the user before large changes)

1. **Scheduling model** — per-window `start_time`+`days`+`duration_minutes`
   (current) vs cron vs single nightly window.
2. **Add-on selection** — user-listed slugs (current) vs "stop all except self";
   whether to remember only the add-ons that were actually running and restore
   just those.
3. **Notifications** — HA notification/event before & after a window
   (adds `homeassistant_api: true`).
4. **Manual / abort controls** — on-demand trigger and abort of an in-progress
   window (MQTT discovery switch, HA switch, or ingress web UI).
5. **Safety guards** — skip if a backup is running, max-duration cap, minimum
   HA Core version pin.
6. **Architectures & timezone** — keep all 5 archs; follow host timezone via
   Supervisor info.
