# Autotune Dashboard

## Purpose

This dashboard gives a browser view over the Postgres autotune database so you can inspect whether the learner is actually improving and which failure patterns or action patterns are dominating.

It is built as a Dockerized `Streamlit` app and reads directly from the existing `autotune` schema.

## Main Views

- live monitor for recent sessions and overnight batch progress
- session improvement over time
- cumulative best-so-far trend
- baseline vs best-candidate KPI deltas
- failure-class frequency and hotspots
- current champions and leaderboard
- parameter effect summaries
- action-learning summaries and failure precursors
- per-session drill-down with candidate, KPI, parameter, and game-level tables

## Files

- [app.py](C:\Program Files (x86)\Steam\steamapps\common\Supreme Commander Forged Alliance\mods\OvermindAI\dashboard\app.py)
- [db.py](C:\Program Files (x86)\Steam\steamapps\common\Supreme Commander Forged Alliance\mods\OvermindAI\dashboard\db.py)
- [requirements.txt](C:\Program Files (x86)\Steam\steamapps\common\Supreme Commander Forged Alliance\mods\OvermindAI\dashboard\requirements.txt)
- [Dockerfile](C:\Program Files (x86)\Steam\steamapps\common\Supreme Commander Forged Alliance\mods\OvermindAI\dashboard\Dockerfile)
- [docker-compose.autotune-db.yml](C:\Program Files (x86)\Steam\steamapps\common\Supreme Commander Forged Alliance\mods\OvermindAI\docker-compose.autotune-db.yml)
- [dashboard_start.ps1](C:\Program Files (x86)\Steam\steamapps\common\Supreme Commander Forged Alliance\mods\OvermindAI\tools\dashboard_start.ps1)
- [dashboard_stop.ps1](C:\Program Files (x86)\Steam\steamapps\common\Supreme Commander Forged Alliance\mods\OvermindAI\tools\dashboard_stop.ps1)

## Start

If you want custom ports or DB credentials, copy `.env.autotune-db.example` to `.env.autotune-db` first and edit it.

Start the dashboard, Postgres, and Adminer:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\dashboard_start.ps1
```

Default endpoints:

- Postgres: `localhost:54329`
- Adminer: `http://localhost:18081`
- Dashboard: `http://localhost:18501`

If you only want the dashboard and DB without Adminer:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\dashboard_start.ps1 -DashboardOnly
```

## Stop

Stop only the dashboard:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\dashboard_stop.ps1
```

Stop the whole DB stack:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\db_stop.ps1
```

## Preflight

Before starting a long batch, run:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\autotune_preflight.ps1
```

That checks:

- Docker reachability
- Postgres reachability
- autotune schema presence
- dashboard HTTP health
- missing config or autorun paths
- lingering FAF game processes

## Notes

- The dashboard does not create a second metrics store. It queries the existing autotune database.
- The dashboard caches query results for a short period to keep the UI responsive while long runs are writing into the DB.
- It is intended for experiment analysis, not live in-game telemetry.
- Use the `Refresh Now` button in the sidebar before judging whether a run has stalled.
