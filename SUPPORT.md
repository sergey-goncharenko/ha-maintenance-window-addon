# Support

For help with Maintenance Window, open a GitHub issue using the most relevant template.

## Before opening an issue

1. Update to the latest app version.
2. Start with `dry_run: true` when testing a new schedule.
3. Check the Maintenance Window app log.
4. Check Supervisor logs for matching timestamps.
5. Check Home Assistant Core logs if Core was stopped or restarted.

## Useful information to include

- Maintenance Window app version.
- Home Assistant Core version.
- Supervisor version.
- Home Assistant OS version and hardware, for example Raspberry Pi 4 / aarch64.
- Whether the app Watchdog is enabled.
- Relevant Maintenance Window options with secrets removed.
- Maintenance Window log around the window.
- Supervisor log around the same timestamps.
- Core log around the same timestamps if Core was affected.

## Finding app slugs

Maintenance Window logs installed Supervisor apps on startup when `list_addons_on_startup` is enabled. Copy slugs from lines like:

```text
[04:12:05] INFO:   a0d7b954_ssh - Advanced SSH & Web Terminal (started)
[04:12:05] INFO:   0d869efa_prometheus_node_exporter - Prometheus Node Exporter (started)
```

Use the slug value, such as `a0d7b954_ssh`, in `stop_addons` or `start_addons`.

The app also writes a copyable table to:

```text
/addon_config/available_addons.md
```
