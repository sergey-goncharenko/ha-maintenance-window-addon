# Maintenance Window

Scheduled quiet windows for Home Assistant OS. At a configured time the app
gracefully stops Home Assistant Core (and, optionally, a list of other apps),
temporarily starts selected apps, holds that state for a short maintenance
window, and then restores everything automatically.

The main use case is external maintenance that Home Assistant should stay quiet
for: host or NAS backups, storage pressure, network maintenance, router restarts,
internet outages, attached hardware maintenance, and sensor work.

## How it works

The app runs as a long-running service (independent of Home Assistant Core,
so it can start Core back up). On a schedule you define, it:

1. Starts any apps listed in `start_addons` that are not already running.
2. Stops the apps listed in `stop_addons`.
3. Stops Home Assistant Core (if `restart_core` is enabled).
4. Waits for the window `duration_minutes`.
5. Starts Home Assistant Core and previously stopped apps again.
6. Stops apps it temporarily started, leaving already-running apps alone.

Home Assistant now generally calls Supervisor-managed packages **apps**. Some
legacy option names in this app still use `addons` (`stop_addons`,
`start_addons`, `list_addons_on_startup`) because those names are part of the
existing configuration contract and match Supervisor API paths.

The global `restart_core`, `stop_addons`, and `start_addons` options are defaults.
Each window can override them with its own values.

Windows are executed one at a time. If you need SSH available while Core is down,
put `restart_core: true` and `start_addons: [core_ssh]` on the same window rather
than creating a second overlapping window.

It talks to the [Supervisor API](https://developers.home-assistant.io/docs/api/supervisor/endpoints)
using the app's `SUPERVISOR_TOKEN`. This requires `hassio_api: true` and
`hassio_role: manager` (already set in the app configuration).

This app includes a minimal custom AppArmor profile. The profile is
kept intentionally small and exists partly so Supervisor can update/replace any
stale profile left by earlier failed prototype installs.

The app image is published to GHCR for `aarch64` and `amd64`, so normal
installation should pull a prebuilt image instead of building on the HAOS device.

> ⚠️ **Important:** While Core is stopped, your automations, dashboards, and
> integrations are unavailable. Choose a window time when this is acceptable
> (e.g. the middle of the night). Maintenance Window is what brings Core back,
> so do not stop it during a maintenance window.

## Development note

Maintenance Window was developed with AI assistance, with human review and
iterative testing throughout. It has been personally tested on a real Home
Assistant OS setup, including dry-run validation, real Core stop/start windows,
app stop/start restore, watchdog pause/restore, and recovery behavior. Even
so, test carefully on your own system before relying on it for unattended
maintenance.

## Configuration

Example app options:

```yaml
log_level: info
dry_run: true
restart_core: false
core_stop_confirmation: ""
startup_grace_seconds: 300
max_core_stop_minutes: 60
core_start_timeout_seconds: 600
restore_stagger_seconds: 15
pause_core_watchdog: true
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

When `true`, the app logs what it *would* do but never actually stops or
starts anything. Use this to validate your schedule safely before going live.

### Option: `restart_core`

When `true`, Home Assistant Core is stopped during the window and restarted
afterward. Set to `false` if you only want to cycle apps.

Set `restart_core` on each window that should stop Core. Leave it off or omit it
for app-only windows, such as temporary SSH access. For safe upgrades from older
configurations, missing per-window `restart_core` is treated as disabled.

For safety, this option is not enough on its own. Core is only stopped when
`restart_core` is `true`, `core_stop_confirmation` is set exactly to
`STOP_CORE`, the app has been running longer than `startup_grace_seconds`,
and the window duration is no greater than `max_core_stop_minutes`.

### Option: `core_stop_confirmation`

Extra arming value required before the app may stop Home Assistant Core. Set
it exactly to `STOP_CORE` only after you have validated the schedule in
`dry_run` mode. Leave it empty to guarantee Core will not be stopped.

### Option: `startup_grace_seconds`

Number of seconds after the app starts during which Core stops are blocked.
The default is `300` seconds. This protects against a bad schedule firing
immediately after installing, booting, or watchdog-restarting the app.

### Option: `max_core_stop_minutes`

Maximum maintenance window duration allowed to stop Core. The default is `60`
minutes. If a window is longer than this, the app can still start/stop other
apps, but Core is left running.

### Option: `core_start_timeout_seconds`

Maximum number of seconds to wait for the Home Assistant Core API to respond
after the app asks Supervisor to start Core. The default is `600` seconds.

This wait happens during restore, after Core has been started. It does not keep
Core stopped longer; it keeps Maintenance Window from declaring the restore
complete while Core is still booting or being restarted by Supervisor health
checks. Set to `0` to disable the readiness wait.

### Option: `restore_stagger_seconds`

Number of seconds to wait before each app is restored after Core is ready. The
default is `15`; accepted values are `0` through `300`. Apps are restored one
at a time and must report `started` before the next app begins. Waiting before
each pending app preserves the stagger even if Maintenance Window itself is
restarted. This reduces simultaneous memory allocation and storage I/O during
recovery.

Restore progress is saved after Core and after each app reaches its expected
state. If Maintenance Window is interrupted, it resumes with only the pending
actions. An active window waits until its original end time. An expired or
legacy state file gets one restore-only cleanup pass: Core and previously
stopped apps may be started, but nothing is stopped, and the stale file is then
removed even if an action fails.

Failed restore passes are limited to three attempts. After that, the app logs
an error, clears the recovery state to prevent a restart loop, and returns to
normal scheduling.

### Option: `pause_core_watchdog`

When `true`, the app temporarily disables the Home Assistant Core watchdog
while it intentionally stops and starts Core, then restores the watchdog to its
previous value after the restore phase completes.

This helps prevent Supervisor from treating the intentionally stopped or still
booting Core service as unhealthy and restarting it during the same maintenance
cycle. If Supervisor refuses the option on your installation, Maintenance Window
logs a warning and continues with the watchdog unchanged.

### Option: `list_addons_on_startup`

When `true`, the app queries Supervisor for installed apps on startup,
logs their names/slugs/states, and writes a copyable inventory file to:

```txt
/addon_config/available_addons.md
```

Use that file or the startup log to copy app slugs into `stop_addons` or
`start_addons`. This is a workaround for a Home Assistant UI limitation: the
built-in app configuration form is generated from a static schema and cannot
dynamically list installed Supervisor apps.

Startup log lines look like this:

```text
[04:12:05] INFO:   a0d7b954_ssh - Advanced SSH & Web Terminal (started)
[04:12:05] INFO:   0d869efa_prometheus_node_exporter - Prometheus Node Exporter (started)
```

Use the slug at the start of the line, for example `a0d7b954_ssh`, in
`stop_addons` or `start_addons`.

### Option: `stop_addons`

A list of app **slugs** to stop during the window. Copy slugs from the
startup log or `/addon_config/available_addons.md`. Leave empty to only affect
Core.

The global list is a default. A window can override it with its own
`stop_addons` list.

### Option: `start_addons`

A list of app **slugs** to start temporarily during the window. The app
checks each listed app first: if it was already running, it is left running
after the window; if Maintenance Window started it, Maintenance Window stops it
again when the window ends.

This is useful for Core-independent access patterns. For example, you can start
SSH during a hardware maintenance window even if Home Assistant Core is stopped
or unresponsive. The global list is a default; a window can override it with its
own `start_addons` list.

Example: temporarily open the official SSH app for 30 minutes after 01:00,
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
start_addons: []
windows:
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
| `duration_minutes` | How long Core/apps stay stopped (1–1440). |
| `restart_core` | Optional per-window Core stop/restart setting. Leave off or omit for app-only windows. |
| `stop_addons` | Optional per-window list of apps to stop. |
| `start_addons` | Optional per-window list of apps to start temporarily. |
| `days` | Optional days of week the window runs (`mon`–`sun`). Leave empty or omit it to run every day. |

If `days` is empty or omitted, the window runs every day.

If a window omits `stop_addons` or `start_addons`, the global setting with the
same name is used. If a window omits `restart_core`, Core is left running.

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

## Finding app slugs

The slug is the identifier in the app's URL, e.g. `core_mosquitto` or
`a0d7b954_nodered`. With `list_addons_on_startup: true`, Maintenance Window also
writes `/addon_config/available_addons.md` and logs installed app slugs on startup.
You can also list them all from a terminal. The Home Assistant CLI command is
still named `ha addons`:

```bash
ha addons --raw-json | jq '.data.addons[] | {name, slug}'
```

The built-in Home Assistant app configuration form is generated from this app's
static schema. It cannot dynamically list the apps installed on your
system inside the `start_addons` / `stop_addons` picker. The startup inventory is
the current lightweight workaround. A future ingress UI could provide a richer
selector by querying the Supervisor API directly.

## Recovery

If a real test behaves unexpectedly, disable Watchdog first if possible, then
stop the app from the HAOS console or SSH:

```bash
ha addons stop 5e912390_maintenance_window
ha supervisor restart
ha core restart
```

If your repository hash differs, list apps and use the displayed slug. The CLI
command is still named `ha addons`:

```bash
ha addons list
```

## Status

This is an early prototype. The app calculates the next configured
`start_time`/`days` occurrence, sleeps until then, runs the maintenance window,
and repeats. Start with `dry_run: true` and a short test window before allowing
it to stop Home Assistant Core.
