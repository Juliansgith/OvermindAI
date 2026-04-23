# Autotune Database

## Purpose

This database layer turns the offline learner into a real experiment system instead of a pile of disconnected JSON and CSV files.

It stores:

- economy autotune sessions
- overnight campaign sessions
- candidate configs and lineage
- per-candidate aggregate results
- per-game results
- per-game player stats
- per-game KPIs
- promotions and champion configs

## Stack

- `Postgres 16` in Docker
- `Adminer` for lightweight browser inspection
- `Streamlit` dashboard for trend and KPI analysis
- PowerShell scripts in `tools/`
- SQL schema and views in `sql/autotune-db/`

## Files

- [docker-compose.autotune-db.yml](C:\Program Files (x86)\Steam\steamapps\common\Supreme Commander Forged Alliance\mods\OvermindAI\docker-compose.autotune-db.yml)
- [.env.autotune-db.example](C:\Program Files (x86)\Steam\steamapps\common\Supreme Commander Forged Alliance\mods\OvermindAI\.env.autotune-db.example)
- [001_schema.sql](C:\Program Files (x86)\Steam\steamapps\common\Supreme Commander Forged Alliance\mods\OvermindAI\sql\autotune-db\001_schema.sql)
- [002_views.sql](C:\Program Files (x86)\Steam\steamapps\common\Supreme Commander Forged Alliance\mods\OvermindAI\sql\autotune-db\002_views.sql)
- [AutotuneDb.ps1](C:\Program Files (x86)\Steam\steamapps\common\Supreme Commander Forged Alliance\mods\OvermindAI\tools\lib\AutotuneDb.ps1)
- [db_start.ps1](C:\Program Files (x86)\Steam\steamapps\common\Supreme Commander Forged Alliance\mods\OvermindAI\tools\db_start.ps1)
- [db_init.ps1](C:\Program Files (x86)\Steam\steamapps\common\Supreme Commander Forged Alliance\mods\OvermindAI\tools\db_init.ps1)
- [db_ingest_autotune.ps1](C:\Program Files (x86)\Steam\steamapps\common\Supreme Commander Forged Alliance\mods\OvermindAI\tools\db_ingest_autotune.ps1)
- [db_backfill_autotune.ps1](C:\Program Files (x86)\Steam\steamapps\common\Supreme Commander Forged Alliance\mods\OvermindAI\tools\db_backfill_autotune.ps1)
- [db_query_champions.ps1](C:\Program Files (x86)\Steam\steamapps\common\Supreme Commander Forged Alliance\mods\OvermindAI\tools\db_query_champions.ps1)
- [db_query_param_effects.ps1](C:\Program Files (x86)\Steam\steamapps\common\Supreme Commander Forged Alliance\mods\OvermindAI\tools\db_query_param_effects.ps1)
- [db_report_autotune.ps1](C:\Program Files (x86)\Steam\steamapps\common\Supreme Commander Forged Alliance\mods\OvermindAI\tools\db_report_autotune.ps1)
- [autotune-dashboard.md](C:\Program Files (x86)\Steam\steamapps\common\Supreme Commander Forged Alliance\mods\OvermindAI\docs\autotune-dashboard.md)

## One-Time Setup

1. Copy `.env.autotune-db.example` to `.env.autotune-db` if you want custom credentials or ports.
2. Start Docker Desktop.
3. Initialize the database:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\db_init.ps1
```

That starts Postgres and Adminer, then applies the schema and views.

Default endpoints:

- Postgres: `localhost:54329`
- Adminer: `http://localhost:18081`
- Dashboard: `http://localhost:18501`

## Basic Commands

Start the stack:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\db_start.ps1
```

Stop the stack:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\db_stop.ps1
```

Start the dashboard on top of the DB:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\dashboard_start.ps1
```

Stop and destroy DB data:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\db_stop.ps1 -DestroyData
```

## Ingest Data

Ingest a single autotune session:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\db_ingest_autotune.ps1 `
  -SessionSummaryPath .\autotune\runs\20260423-165155\session-summary.json `
  -StartDb `
  -InitSchema
```

Ingest a single overnight session:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\db_ingest_autotune.ps1 `
  -OvernightSummaryPath .\autotune\runs\overnight-20260423-165200\overnight-summary.json
```

Backfill everything under `autotune\runs`:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\db_backfill_autotune.ps1 -StartDb -InitSchema
```

## Queries

Current champions:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\db_query_champions.ps1
```

Parameter correlations:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\db_query_param_effects.ps1
```

Failure-class parameter patterns:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\db_query_param_effects.ps1 -FailureClass reclaim_failure
```

Generate a Markdown DB report:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\db_report_autotune.ps1
```

## Views

The database exposes these main views:

- `autotune.v_current_champions`
- `autotune.v_session_leaderboard`
- `autotune.v_param_effects`
- `autotune.v_failure_param_effects`
- `autotune.v_map_opponent_profiles`
- `autotune.v_failure_hotspots`

These give you:

- current best promoted config per map/opponent
- session-level promotion history
- knob correlations versus score, mass ratio, and survival
- failure-specific knob patterns
- matchup summaries
- dominant problem clusters

## Intended Workflow

1. Run autotune or overnight campaigns.
2. Ingest results automatically or backfill them.
3. Query champions and hotspot failures.
4. Let adaptive mutation target the dominant failure classes.
5. Promote only statistically stronger candidates.

The runtime AI still stays deterministic and bounded. The DB is only for offline learning, selection, and analysis.
