# Maintenance Window HA Add-on Repository

A Home Assistant add-on repository containing the **Maintenance Window** add-on.

## What it does

Maintenance Window provides scheduled Home Assistant maintenance windows. At a
configured time it can gracefully **stop Home Assistant Core** and selected
add-ons, temporarily **start selected add-ons**, hold that state for a short
window, and then automatically restore everything when the window ends.

Typical use cases:

- Give the host a quiet period for backups, host updates, or database maintenance.
- Reduce automation noise / device polling during the night.
- Force a clean, scheduled restart of Core on a regular cadence.
- Temporarily open an add-on such as SSH for a short break-glass access window.

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

> ⚠️ This add-on can stop Home Assistant Core. While Core is stopped, automations,
> the UI, and integrations are unavailable. The add-on itself runs independently
> of Core and is responsible for starting Core again at the end of the window.
