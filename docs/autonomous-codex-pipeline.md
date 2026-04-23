# Autonomous Codex Patch Pipeline

## Purpose

Use the existing DB-backed learner for policy/config tuning.

Use the Codex patch pipeline only when the data shows a mechanic gap that config mutation cannot solve, for example:

- ACU emergency support exists but triggers too weakly
- engineer emergency repair is missing or under-prioritized
- platoon composition or escort logic needs a new rule
- zone/task ownership logic needs a code change

This keeps the system from blindly rewriting runtime code every night.

## Two-Layer Design

### 1. Policy learner

This is the safe, high-volume loop.

It should mutate:

- `AutoTuneConfig.lua`
- `MechanicTuneConfig.lua`
- tactic/module config tables

It should not patch Lua logic directly.

### 2. Offline patch worker

This is the low-volume, gated loop.

It should:

1. read DB failures, action priors, and candidate regressions
2. formulate a bounded patch task
3. create an isolated git worktree
4. invoke `codex exec`
5. run syntax and targeted validations
6. only apply the patch back if the generated change is coherent

## Mechanic Tune Surface

The first runtime mechanic surface now lives in:

- `lua/AI/Overmind/MechanicTune.lua`
- `lua/AI/Overmind/MechanicTuneConfig.lua`

It currently controls:

- side-cohort AA escort bias
- ACU emergency intercept pressure and stickiness
- indirect/heavy/AA escort posture thresholds
- engineer structure-repair safety thresholds
- engineer emergency ACU repair thresholds

This is the correct pattern for “one more SPAA” style adaptation: move the composition and escort thresholds into policy first, then let the learner mutate those before escalating to codegen.

## Example

Manual patch task:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\run_codex_patch_pipeline.ps1 `
  -Label platoon-spaa `
  -Prompt "Modify platoon generation and escort posture so land side cohorts keep one more SPAA when bomber pressure or unsupported AA posture is detected. Keep the change bounded to existing combat/force modules." `
  -ContextFiles lua/AI/Overmind/ForceDirector.lua,lua/AI/Overmind/CombatExecution.lua `
  -KeepWorktree
```

Manual mechanic-config write:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\write_mechanic_tune_config.ps1 `
  -ConfigJson '{"ProfileId":"aggressive-aa","ForceSideEscortAABias":1,"CombatAASupportBias":1}'
```

## What Must Improve In The World Model

The main remaining bottleneck is not only policy. It is world-model quality.

The runtime still needs stronger:

- persistent objective memory
- battle objects instead of scattered local heuristics
- ETA/race reasoning for save/retake/support decisions
- contested-zone state over time
- explicit opportunity objects for reclaim, exposed mexes, ACU threats, and rescue opportunities
- path/reachability confidence across land, water, hover, and transport options
- task interruption ownership so local crises override lower-priority plans

Without that substrate, autonomous tuning will keep optimizing symptoms.

## Promotion Rules

Never auto-merge a Codex-generated runtime patch just because syntax passed.

Minimum gate:

1. syntax pass
2. diff review artifact recorded
3. one validation game
4. short batch
5. no regression against current champion metrics

Use the patch worker for mechanic gaps.
Use the policy learner for everything else.
