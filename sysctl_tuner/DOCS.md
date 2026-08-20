# Kernel VM Tuner

Applies kernel virtual-memory sysctls at boot. Intended for small Home Assistant OS hosts
(1–2 GB RAM) where the kernel OOM-kills add-ons under memory pressure.

Home Assistant OS has a read-only root filesystem and no supported place for `sysctl.conf`
entries, and `vm.*` sysctls are not namespaced so ordinary add-ons cannot write them. This
add-on runs privileged (`full_access`) at the `initialize` startup stage and writes the values
before other add-ons come up.

**Protection mode must be disabled** for this add-on, otherwise the writes are refused. The log
will say so explicitly.

The add-on applies its values and then exits, so `stopped` is the normal state after a run.
Keep **Start on boot** enabled — the settings are reapplied on every boot, not stored on disk.

## Options

| Option | Default | Range | Description |
|---|---|---|---|
| `log_level` | `info` | trace…fatal | Verbosity. |
| `dry_run` | `true` | bool | Report intended changes without applying them. **Start here.** |
| `swappiness` | `60` | 0–200 | Weight of reclaiming anonymous memory vs page cache. Low values make the kernel prefer OOM-killing over swapping; 60 is the upstream default. |
| `watermark_scale_factor` | `200` | 10–3000 | How early and how aggressively `kswapd` reclaims. Raising it keeps more free headroom, which is what prevents allocation spikes from outrunning reclaim. |
| `min_free_kbytes` | `16384` | 1024–262144 | Emergency free reserve for kernel/atomic allocations. Raising it makes kernel slab exhaustion less likely. |
| `vfs_cache_pressure` | `100` | 1–1000 | Reclaim pressure on dentry/inode caches. 100 is the kernel default. |
| `keep_running` | `false` | bool | Stay resident after applying instead of exiting. Costs a few MiB. |

Omit any tunable to leave the kernel default untouched. Every write is verified by reading the
value back; a mismatch is logged as an error and the add-on exits non-zero.

## Trade-offs

- If swap is on an SD card, raising `swappiness` increases writes to limited-endurance media and
  adds latency when swapped-out processes wake.
- `min_free_kbytes` and `watermark_scale_factor` deliberately hold RAM back — you trade a little
  usable memory for reclaim headroom.
- These settings widen the margin; they do not fix a host whose working set exceeds its RAM.

## Rollback

Set `dry_run: true` or uninstall, then reboot — nothing persists on disk. To revert without a
reboot, restore the previous values in the options and restart the add-on.

## Verifying it worked

```bash
cat /proc/sys/vm/swappiness
dmesg | grep -c "Out of memory: Killed process"
cat /proc/pressure/memory
```

Swap usage rising is expected and desirable. Judge the result by OOM-kill count and memory
pressure, not by how much swap is in use.
