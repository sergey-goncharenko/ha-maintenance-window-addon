# Security Policy

Maintenance Window can stop and start Home Assistant Core and Supervisor apps. Please treat reports that could cause unexpected Core downtime, failure to restore Core, privilege escalation, or exposure of Supervisor tokens as security-sensitive.

## Supported versions

Only the latest published version is supported for security fixes.

## Reporting a vulnerability

If GitHub Security Advisories are enabled for this repository, use the **Report a vulnerability** button on the repository's Security page.

If the issue is not sensitive, open a normal GitHub issue and include logs/config snippets with secrets removed. Do not post Supervisor tokens, private URLs, hostnames, device names, or full Home Assistant diagnostics publicly unless you have reviewed them.

## Safe disclosure expectations

- Share the minimum details needed to reproduce the issue.
- Redact `SUPERVISOR_TOKEN`, secrets, private URLs, and personal Home Assistant data.
- Include the app version, Home Assistant Core version, Supervisor version, and HAOS version when possible.
