# Maintenance Window

Scheduled "quiet mode" for Home Assistant. At a configured time the add-on
gracefully stops Home Assistant Core (and, optionally, a list of other add-ons),
holds them down for a short maintenance window, and then restarts everything
automatically.

## How it works

The add-on runs as a long-running service (independent of Home Assistant Core,
so it can start Core back up). On a schedule you define, it:

1. Starts any add-ons listed in `start_addons` that are not already running.
2. Stops the add-ons listed in `stop_addons`.
3. Stops Home Assistant Core (if `restart_core` is enabled).
4. Waits for the window `duration_minutes`.
5. Starts Home Assistant Core and previously stopped add-ons again.
6. Stops add-ons it temporarily started, leaving already-running add-ons alone.

It talks to the [Supervisor API](https://developers.home-assistant.io/docs/api/supervisor/endpoints)
using the add-on's `SUPERVISOR_TOKEN`. This requires `hassio_api: true` and
`hassio_role: manager` (already set in the add-on configuration).

This early prototype currently disables its custom AppArmor profile to avoid an
installation-time profile loading issue on HAOS. It still runs as a normal
Supervisor-managed add-on container and keeps the safe default configuration
described below.

> ⚠️ **Important:** While Core is stopped, your automations, dashboards, and
> integrations are unavailable. Choose a window time when this is acceptable
> (e.g. the middle of the night). The add-on is what brings Core back, so do not
> stop this add-on during a maintenance window.

## Configuration

Example add-on options:

```yaml
log_level: info
dry_run: true
restart_core: false
core_stop_confirmation: ""
startup_grace_seconds: 300
max_core_stop_minutes: 60
stop_addons:
  - core_mosquitto
  - a0d7b954_nodered
start_addons: []
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

For safety, this option is not enough on its own. Core is only stopped when
`restart_core` is `true`, `core_stop_confirmation` is set exactly to
`STOP_CORE`, the add-on has been running longer than `startup_grace_seconds`,
and the window duration is no greater than `max_core_stop_minutes`.

### Option: `core_stop_confirmation`

Extra arming value required before the add-on may stop Home Assistant Core. Set
it exactly to `STOP_CORE` only after you have validated the schedule in
`dry_run` mode. Leave it empty to guarantee Core will not be stopped.

### Option: `startup_grace_seconds`

Number of seconds after the add-on starts during which Core stops are blocked.
The default is `300` seconds. This protects against a bad schedule firing
immediately after installing, booting, or watchdog-restarting the add-on.

### Option: `max_core_stop_minutes`

Maximum maintenance window duration allowed to stop Core. The default is `60`
minutes. If a window is longer than this, the add-on can still start/stop other
add-ons, but Core is left running.

### Option: `stop_addons`

A list of add-on **slugs** to stop during the window. Find an add-on's slug in
its page URL or via the Supervisor `GET /addons` endpoint. Leave empty to only
affect Core.

### Option: `start_addons`

A list of add-on **slugs** to start temporarily during the window. The add-on
checks each listed add-on first: if it was already running, it is left running
after the window; if Maintenance Window started it, Maintenance Window stops it
again when the window ends.

Example: temporarily open the official SSH add-on for 30 minutes after 01:00,
without restarting Home Assistant Core:

```yaml
log_level: info
dry_run: false
restart_core: false
core_stop_confirmation: ""
startup_grace_seconds: 300
max_core_stop_minutes: 60
stop_addons: []
start_addons:
  - core_ssh
windows:
  - name: Temporary SSH access
    start_time: "01:00"
    duration_minutes: 30
    days:
      - mon
      - tue
      - wed
      - thu
      - fri
      - sat
      - sun
```

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

This is an early prototype. The add-on calculates the next configured
`start_time`/`days` occurrence, sleeps until then, runs the maintenance window,
and repeats. Start with `dry_run: true` and a short test window before allowing
it to stop Home Assistant Core.
