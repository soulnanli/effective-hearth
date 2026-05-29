# Effective Hearth

> A Stonehearth performance mod focused on pathfinding optimization.
> **Reduces A\* CPU usage by ~75%** with zero behavior changes.

**Version**: 0.1.0 (Alpha)
**Tested on**: Stonehearth 1.1.0.949 (x64, single-player)

---

## What it does

Late-game Stonehearth (30+ hearthlings) chokes on pathfinding. This mod targets the two worst offenders:

1. **Unbounded A\* searches** — Vanilla pathfinder can scan 14,000+ nodes when proving "unreachable", crashing 32-bit builds with OOM.
2. **Repeated identical pathfinding** — 10 hearthlings each computing "from kitchen to storage" from scratch, while the result is identical.

After installing:

- A\* searches **capped at 4000 steps** — no more memory-blowing dead-end scans.
- A\* results **cached and reused** when start/end regions repeat — typical hit rate **40-55%**.

**Net result**: ~75% reduction in A\* CPU time, no visible AI behavior change.

---

## Installation

1. Locate your Stonehearth `mods/` folder:
   - **Steam**: `<Steam>/steamapps/common/Stonehearth/mods/`
2. Copy or extract the `effective_hearth/` folder there. Final layout:

   ```
   mods/
   ├── radiant.smod
   ├── stonehearth.smod
   └── effective_hearth/
       ├── manifest.json
       ├── effective_hearth_server.lua
       ├── lib/
       └── patches/
   ```

3. Launch the game. The mod auto-loads. No menu changes, no save game compatibility issues.

---

## Verifying it works

After loading any save, open `<Stonehearth>/stonehearth.log` and search for `effective_hearth`:

```
[effective_hearth] booting v0.1.0
[effective_hearth.astar_max_steps] installed: max_steps=4000
[effective_hearth.astar_cache] mode=live ... installed (mode=live)
[effective_hearth] 2/2 patches active
```

If you see `2/2 patches active`, you're good.

Every 5 minutes, the mod prints a stats report:

```
==== astar_cache live report (last 300s) ====
  hit_rate         : 40.7%
  hit_direct       : 6601
  evict_abort      : 0
  shortcut_found   : 70
==== end report ====
```

- **`hit_rate`** = % of pathfinding requests served from cache. Typical 30-55%.
- **`evict_abort`** = times a cached path turned out to be invalid. **Should always be 0**.
- **`shortcut_found`** = times a re-computed path was shorter than the cached one (cache self-corrected).

---

## Configuration

Edit `<Stonehearth>/stonehearth.json`. Add (or merge into existing) `mods` section:

```json
{
   "mods": {
      "effective_hearth": {
         "log_level": "info",
         "patches": {
            "astar_max_steps": {
               "enabled": true,
               "max_steps": 4000
            },
            "astar_cache": {
               "enabled": true,
               "mode": "live",
               "max_entries": 1000,
               "ttl_ms": 60000,
               "explore_rate": 0.05,
               "chunk_size": 16
            }
         }
      }
   }
}
```

### Key options

| Option | Default | Range | What it does |
|---|---|---|---|
| `astar_cache.mode` | `"live"` | `"live"`/`"shadow"`/`"disabled"` | `shadow` = observe-only (no behavior change, still collects stats); useful for verifying cache safety on your save before going live. |
| `astar_cache.max_entries` | 1000 | 256 - 10000 | Max cached paths. Higher = more memory, possibly higher hit rate. |
| `astar_cache.ttl_ms` | 60000 | 0 = no TTL | How long a cached path stays "fresh". Lower = picks up terrain changes faster, lower hit rate. |
| `astar_cache.explore_rate` | 0.05 | 0.0 - 1.0 | Probability of skipping cache to recompute. Detects shortcuts after terrain changes. Set 0 to disable. |
| `astar_max_steps.max_steps` | 4000 | 100 - 50000 | A\* will give up after this many nodes. Lower = faster but more "no path found" responses. |

### Disabling individual patches

```json
"patches": {
   "astar_cache":     { "enabled": false }
}
```

Or just `"mode": "disabled"` for cache.

---

## Compatibility

- ✅ **Single-player**: tested 13.5+ hours stable.
- ✅ **x64 build**: required (the hidden `x64/Stonehearth.exe`). 32-bit works but inherits all 32-bit memory limits.
- ⚠️ **ACE / other AI mods**: not tested. Likely safe but expect to test individually.
- ⚠️ **Multiplayer**: not tested.
- ❌ **Save format**: no changes. Save/load works the same.

---

## Reporting issues

When something breaks, the relevant info to include:

1. **`stonehearth.log`** — last ~500 lines, especially anything containing `effective_hearth`, `assertion`, or `CHECK failed`.
2. **Reproduction steps** — what were the hearthlings doing?
3. **Save file size + hearthling count** — pacing matters.

---

## TODO List

- No in-game UI. All config via `stonehearth.json`.
- No Lua GC performance optimization.

---

License: MIT
