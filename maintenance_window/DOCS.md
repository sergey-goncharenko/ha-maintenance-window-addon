# Maintenance Window

Scheduled "quiet mode" for Home Assistant. At a configured time the add-on
gracefully stops Home Assistant Core (and, optionally, a list of other add-ons),
holds them down for a short maintenance window, and then restarts everything
automatically.

## How it works

The add-on runs as a long-running service (independent of Home Assistant Core,
so it can start Core back up). On a schedule you define, it:

1. Stops the add-ons listed in `stop_addons`.
2. Stops Home Assistant Core (if `restart_core` is enabled).
3. Waits for the window `duration_minutes`.
4. Starts Home Assistant Core again.
5. Starts the previously stopped add-ons again.

It talks to the [Supervisor API](https://developers.home-assistant.io/docs/api/supervisor/endpoints)
using the add-on's `SUPERVISOR_TOKEN`. This requires `hassio_api: true` and
`hassio_role: manager` (already set in the add-on configuration).

> ⚠️ **Important:** While Core is stopped, your automations, dashboards, and
> integrations are unavailable. Choose a window time when this is acceptable
> (e.g. the middle of the night). The add-on is what brings Core back, so do not
> stop this add-on during a maintenance window.

## Configuration

Example add-on options:

```yaml
log_level: info
dry_run: false
restart_core: true
stop_addons:
  - core_mosquitto
  - a0d7b954_nodered
windows:
  - name: Nightly maintenance
    start_time: "03:00"
    duration_minutes: 10
    days:
      - mon
      - tue
      - wed
      - thu
      - fri
      - sat
      - sun
```

### Option: `log_level`

Controls verbosity. One of `trace`, `debug`, `info`, `notice`, `warning`,
`error`, `fatal`.

### Option: `dry_run`

When `true`, the add-on logs what it *would* do but never actually stops or
starts anything. Use this to validate your schedule safely before going live.

### Option: `restart_core`

When `true`, Home Assistant Core is stopped during the window and restarted
afterward. Set to `false` if you only want to cycle add-ons.

### Option: `stop_addons`

A list of add-on **slugs** to stop during the window. Find an add-on's slug in
its page URL or via the Supervisor `GET /addons` endpoint. Leave empty to only
affect Core.

### Option: `windows`

A list of maintenance windows. Each entry has:

| Field | Description |
| ----- | ----------- |
| `name` | Friendly label used in logs. |
| `start_time` | 24-hour `HH:MM` local time the window begins. |
| `duration_minutes` | How long Core/add-ons stay stopped (1–1440). |
| `days` | Days of week the window runs (`mon`–`sun`). |

## Finding add-on slugs

The slug is the identifier in the add-on's URL, e.g. `core_mosquitto` or
`a0d7b954_nodered`. You can also list them all from a terminal:

```bash
ha addons --raw-json | jq '.data.addons[] | {name, slug}'
```

## Status

This is an early scaffold. The scheduling logic in
`rootfs/usr/lib/maintenance-window/scheduler.sh` is a documented placeholder —
the Supervisor API calls and safety guards are implemented, but the time/day
matching is marked `TODO`.
