# Maintenance Window

Scheduled quiet windows for Home Assistant OS. At a configured time the add-on
gracefully stops Home Assistant Core (and, optionally, a list of other add-ons),
temporarily starts selected add-ons, holds that state for a short maintenance
window, and then restores everything automatically.

The main use case is external maintenance that Home Assistant should stay quiet
for: host or NAS backups, storage pressure, network maintenance, router restarts,
internet outages, attached hardware maintenance, and sensor work.

## How it works

The add-on runs as a long-running service (independent of Home Assistant Core,
so it can start Core back up). On a schedule you define, it:

1. Starts any add-ons listed in `start_addons` that are not already running.
2. Stops the add-ons listed in `stop_addons`.
3. Stops Home Assistant Core (if `restart_core` is enabled).
4. Waits for the window `duration_minutes`.
5. Starts Home Assistant Core and previously stopped add-ons again.
6. Stops add-ons it temporarily started, leaving already-running add-ons alone.

The global `restart_core`, `stop_addons`, and `start_addons` options are defaults.
Each window can override them with its own values.

Windows are executed one at a time. If you need SSH available while Core is down,
put `restart_core: true` and `start_addons: [core_ssh]` on the same window rather
than creating a second overlapping window.

It talks to the [Supervisor API](https://developers.home-assistant.io/docs/api/supervisor/endpoints)
using the add-on's `SUPERVISOR_TOKEN`. This requires `hassio_api: true` and
`hassio_role: manager` (already set in the add-on configuration).

This early prototype includes a minimal custom AppArmor profile. The profile is
kept intentionally small and exists partly so Supervisor can update/replace any
stale profile left by earlier failed prototype installs.

The add-on image is published to GHCR for `aarch64` and `amd64`, so normal
installation should pull a prebuilt image instead of building on the HAOS device.

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
list_addons_on_startup: true
stop_addons:
  - core_mosquitto
  - a0d7b954_nodered
start_addons: []
windows:
  - name: Nightly maintenance
    start_time: "03:00"
    duration_minutes: 10
    restart_core: true
    stop_addons:
      - core_mosquitto
    start_addons: []
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

The global value is a default. A window can override it with its own
`restart_core` value.

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

### Option: `list_addons_on_startup`

When `true`, the add-on queries Supervisor for installed add-ons on startup,
logs their names/slugs/states, and writes a copyable inventory file to:

```txt
/addon_config/available_addons.md
```

Use that file or the startup log to copy add-on slugs into `stop_addons` or
`start_addons`. This is a workaround for a Home Assistant UI limitation: the
built-in add-on configuration form is generated from a static schema and cannot
dynamically list installed Supervisor add-ons.

### Option: `stop_addons`

A list of add-on **slugs** to stop during the window. Find an add-on's slug in
its page URL or via the Supervisor `GET /addons` endpoint. Leave empty to only
affect Core.

The global list is a default. A window can override it with its own
`stop_addons` list.

### Option: `start_addons`

A list of add-on **slugs** to start temporarily during the window. The add-on
checks each listed add-on first: if it was already running, it is left running
after the window; if Maintenance Window started it, Maintenance Window stops it
again when the window ends.

This is useful for Core-independent access patterns. For example, you can start
SSH during a hardware maintenance window even if Home Assistant Core is stopped
or unresponsive. The global list is a default; a window can override it with its
own `start_addons` list.

Example: temporarily open the official SSH add-on for 30 minutes after 01:00,
without restarting Home Assistant Core:

```yaml
log_level: info
dry_run: false
restart_core: false
core_stop_confirmation: ""
startup_grace_seconds: 300
max_core_stop_minutes: 60
list_addons_on_startup: true
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

Example with Core stopped and SSH temporarily opened during the same window:

```yaml
log_level: info
dry_run: true
restart_core: false
core_stop_confirmation: ""
startup_grace_seconds: 300
max_core_stop_minutes: 10
list_addons_on_startup: true
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

### Option: `windows`

A list of maintenance windows. Each entry has:

| Field | Description |
| ----- | ----------- |
| `name` | Friendly label used in logs. |
| `start_time` | 24-hour `HH:MM` local time the window begins. |
| `duration_minutes` | How long Core/add-ons stay stopped (1–1440). |
| `restart_core` | Optional per-window Core stop/restart override. |
| `stop_addons` | Optional per-window list of add-ons to stop. |
| `start_addons` | Optional per-window list of add-ons to start temporarily. |
| `days` | Days of week the window runs (`mon`–`sun`). |

If a window omits `restart_core`, `stop_addons`, or `start_addons`, the global
setting with the same name is used.

Example with two different window actions:

```yaml
log_level: info
dry_run: true
restart_core: false
core_stop_confirmation: ""
startup_grace_seconds: 300
max_core_stop_minutes: 60
list_addons_on_startup: true
stop_addons: []
start_addons: []
windows:
  - name: Core maintenance
    start_time: "03:00"
    duration_minutes: 10
    restart_core: true
    stop_addons:
      - core_mosquitto
    start_addons: []
    days:
      - sun
  - name: Temporary SSH access
    start_time: "01:00"
    duration_minutes: 30
    restart_core: false
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

## Finding add-on slugs

The slug is the identifier in the add-on's URL, e.g. `core_mosquitto` or
`a0d7b954_nodered`. With `list_addons_on_startup: true`, Maintenance Window also
writes `/addon_config/available_addons.md` and logs installed add-on slugs on startup.
You can also list them all from a terminal:

```bash
ha addons --raw-json | jq '.data.addons[] | {name, slug}'
```

The built-in Home Assistant add-on configuration form is generated from this
add-on's static schema. It cannot dynamically list the add-ons installed on your
system inside the `start_addons` / `stop_addons` picker. The startup inventory is
the current lightweight workaround. A future ingress UI could provide a richer
selector by querying the Supervisor API directly.

## Recovery

If a real test behaves unexpectedly, disable Watchdog first if possible, then
stop the add-on from the HAOS console or SSH:

```bash
ha addons stop 5e912390_maintenance_window
ha supervisor restart
ha core restart
```

If your repository hash differs, list add-ons and use the displayed slug:

```bash
ha addons list
```

## Status

This is an early prototype. The add-on calculates the next configured
`start_time`/`days` occurrence, sleeps until then, runs the maintenance window,
and repeats. Start with `dry_run: true` and a short test window before allowing
it to stop Home Assistant Core.
