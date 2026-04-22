# Overmind AI (Initialization Build)

This mod initializes a new skirmish AI personality for Forged Alliance:

- `AI: Overmind`
- `AIx: Overmind`

## What this build includes

- Mod metadata and activation via `mod_info.lua`
- Lobby registration via `hook/lua/ui/lobby/aitypes.lua`
- Tooltip registration via `hook/lua/ui/help/tooltips.lua`
- Personality-aware brain hook via `hook/lua/aibrain.lua`
- Unit event bridge via `hook/lua/sim/Unit.lua`
- New AI base templates:
  - `OvermindMain`
  - `OvermindExpansion`
  - `OvermindNavalExpansion`
- Original modular runtime (inspired by top AI architecture patterns, not copied):
  - `lua/AI/Overmind/Bootstrap.lua`
  - `lua/AI/Overmind/Scheduler.lua`
  - `lua/AI/Overmind/Memory.lua`
  - `lua/AI/Overmind/Economy.lua`
  - `lua/AI/Overmind/Combat.lua`
  - `lua/AI/Overmind/Budget.lua`
  - `lua/AI/Overmind/ZoneModel.lua`
  - `lua/AI/Overmind/OpponentModel.lua`
  - `lua/AI/Overmind/GoalSelector.lua`
  - `lua/AI/Overmind/EconomyOptimizer.lua`
  - `lua/AI/Overmind/Tactical.lua`
  - `lua/AI/Overmind/Telemetry.lua`
  - `lua/AI/Overmind/Watchdog.lua`
  - `lua/AI/Overmind/FactoryHeartbeat.lua`
  - `lua/AI/Overmind/ACURole.lua`
  - `lua/AI/Overmind/ScoutManager.lua`
  - `lua/AI/Overmind/EngineerDirector.lua`
  - `lua/AI/Overmind/AutoTune.lua`
  - `lua/AI/Overmind/AutoTuneConfig.lua`
- Overmind eco policy layer:
  - `lua/editor/OvermindBuildConditions.lua`
  - `lua/AI/Overmind/BuilderGroupsEconomy.lua`
- Automated benchmark harness hooks:
  - `hook/lua/SinglePlayerLaunch.lua` (AI-vs-AI session override for benchmark runs)
  - `hook/lua/ui/menus/main.lua` (auto-start benchmark match from command line)
  - `hook/lua/ui/uimain.lua` (auto-exit after game over)
  - `hook/lua/victory.lua` (structured benchmark result logging)
- Auto-tune pipeline:
  - `tools/autotune_overmind.ps1` (parses latest FAF log and regenerates `AutoTuneConfig.lua`)

## Design intent

This is a strong baseline focused on:

- Fast production scaling
- Continuous scouting and expansion pressure
- Combined-arms land/air/navy throughput
- Earlier late-game transitions (experimentals and strategic pressure)
- Adaptive runtime cadence based on unit count (load shedding)
- Event-fed memory (kills, losses, reclaim, build throughput)
- Momentum-aware pressure waves that attack or defend based on state
- Overmind-specific economy builders and conditions:
  - aggressive mex claim/upgrade when safe
  - overflow spending to reduce mass float
  - tighter energy gating to avoid wasteful overbuild
  - factory growth tied to economy health and spend pressure
- Six-layer intelligence stack:
  - strategic zone model and map-control scoring
  - opponent posture inference (`air_rush`, `eco_greed`, `turtle`, etc.)
  - utility-driven goal selection (`hold`, `expand`, `raid`, `tech`, `all_in`)
  - economy policy optimization tied to goal and pressure
  - tactical engage/retreat controller for idle mobile forces
  - telemetry capture with automatic weight nudging over time
  - runtime watchdog + factory heartbeat recovery for anti-stall production
  - ACU role state machine (`anchor`, `assist`, `push`, `retreat`)
  - recon wave planner with lost-contact recovery
  - expansion route-risk memory and blackspot avoidance for engineers

## Next iteration targets

To push this toward top-tier competitive behavior against mods like M27/RNGAI/Sorian:

1. Add dedicated builder conditions that consume Overmind memory and aggression state directly.
2. Add custom platoon plans (raider, anchor, skirmisher) with per-role micro budgets.
3. Add map-zone scoring (choke/mex/control pressure) to choose expansion and timing windows.
4. Add replay-driven tuning loops (mass curves, factory splits, scout cadence, timing windows).

## Automated Benchmarks

Use the scripts in `tools/overmind-bench`:

1. `run_bench.ps1` runs AI-vs-AI batches end-to-end.
2. `analyze_bench.ps1` computes per-AI win rates and Elo-style rankings.

The benchmark mode is activated with command-line flag `/overmindbench`.
During benchmark mode the mod will:

- auto-start a skirmish from `/benchmap`
- force all playable slots to AI personalities from `/bench_ai`
- emit parseable lines into `SupCom.sclog` and, if provided, append them to `/benchout`:
  - `*OVERMIND_BENCH_META|...`
  - `*OVERMIND_BENCH_RESULT|...`
- auto-exit the game client after match end.

## Recommended Local Run Path (Stable)

For local AI-vs-AI iteration, use the Softles-style `autorun` launcher from the FA root.

### Preconditions

1. Work from FA root:
   - `C:\Program Files (x86)\Steam\steamapps\common\Supreme Commander Forged Alliance`
2. Enable multi-instance support in `Game.prefs`:
   - `debug = { enable_debug_facilities = true }`

### Canonical Smoke Run (1 game)

```powershell
powershell -ExecutionPolicy Bypass -File .\autorun\bin\start_autorun_parallel.ps1 -Instances 1 -TargetSpeed 10 -ExitDelaySeconds 3 -MapName SCMP_004 -MaxRealSeconds 0 -MaxGameSeconds 0
```

Expected log markers:
- `Loading game configuration from: /lua/generated/...`
- `Autorun: no human army configured; local client should enter as observer.`
- `Autorun slot: 1 ... AIPersonality= overmind`
- `Autorun slot: 2 ... AIPersonality= m27ai`
- `Setting game speed to be: 10`

### Timed Smoke Variant (fast validation)

```powershell
powershell -ExecutionPolicy Bypass -File .\autorun\bin\start_autorun_parallel.ps1 -Instances 1 -TargetSpeed 10 -ExitDelaySeconds 3 -MapName SCMP_004 -MaxRealSeconds 45 -MaxGameSeconds 240
```

This intentionally ends with:
- `Maximum game or real time reached, exiting.`

### Parallel Runs

```powershell
powershell -ExecutionPolicy Bypass -File .\autorun\bin\start_autorun_parallel.ps1 -Instances 2 -TargetSpeed 10 -ExitDelaySeconds 3 -MapName SCMP_004 -MaxRealSeconds 0 -MaxGameSeconds 0
```

## Log Auto-Tuning

After a game finishes, regenerate tuning thresholds from logs:

```powershell
powershell -ExecutionPolicy Bypass -File "mods/OvermindAI/tools/autotune_overmind.ps1"
```

This updates `lua/AI/Overmind/AutoTuneConfig.lua` with new defaults for:

- factory floors and recovery trigger time
- scout minimum count
- ACU leash distances
- expansion risk bias and base engineer floor
