# Economy Autotune

## Purpose

The economy autotune workflow is an offline tuning loop for Overmind economy policy.

It does not let the AI rewrite itself inside a live match. FAF Lua is not a safe place to do persistent self-modification, and live self-learning would make results hard to reproduce. Instead, the workflow runs controlled autorun batches, scores the results, mutates bounded economy knobs, and promotes a candidate only if it beats the current baseline without runtime errors.

## Runtime Contract

`AutoTuneConfig.lua` is the only promoted tuning artifact consumed by runtime code.

The runtime clamps all config values before use. Neutral values preserve the hand-authored economy policy, while nonzero values bias policy decisions such as:

- factory tempo and factory affordability
- base engineer floor and engineer-to-factory ratio
- safe expansion distance, risk cap, and enemy buffer
- reclaim-field thresholds and reclaim engineer quota
- reclaim risk tolerance, support requirements, and nearby opportunistic reclaim sensitivity
- expansion engineer quota
- strategic posture bias for expand, stabilize, tempo, tech, air response, and forward theater retention
- mex upgrade timing, risk, budget, and concurrency
- first land HQ timing and economy strictness
- early air timing
- radar timing
- power safety pressure

`EconomyOptimizer` applies economy values to the live policy, while `StrategicPlanner`, `EngineerDirector`, and `UpgradeDirector` consume the expanded policy surface. Other systems continue to consume normal runtime outputs; they do not read arbitrary candidate files directly.

## Harness

Run a dry check first:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\run_economy_autotune.ps1 -Candidates 1 -GamesPerCandidate 1 -ParallelInstances 1 -DryRun
```

Run a normal campaign:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\run_economy_autotune.ps1 -Candidates 6 -GamesPerCandidate 20 -ParallelInstances 20 -TargetSpeed 20 -MapName SCMP_036
```

The harness performs this loop:

- read the current `AutoTuneConfig.lua` as the baseline
- run the baseline unless `-SkipBaseline` is passed
- generate bounded mutated candidates
- bias mutations toward the current dominant failure class and historical high-performing directions
- sync each candidate to the live mounted mod copies
- launch autorun games in parallel
- run the existing autorun analyzer and KPI extractor
- score survival time, wins, mass ratio, spend ratio, mex timing, factory count, expansion orders, reclaim orders, reclaim mass, and runtime cleanliness
- promote the best candidate only if it beats baseline by `-PromoteScoreMargin`
- restore the baseline if no candidate qualifies

Generated campaign data is written under `autotune/runs/` and is intentionally ignored by git.

## Promotion Rules

A candidate is not promoted if it has runtime errors, modular engineer errors, or runtime fallback logs.

A candidate must beat the baseline by the configured score margin. The default margin is 3 percent, which avoids replacing the baseline with statistical noise from a single lucky run.

If a candidate is promoted, the harness writes the winning values back to `lua/AI/Overmind/AutoTuneConfig.lua` and syncs the live mounted copies.

## Practical Use

Use one map and opponent setup per campaign when tuning. Mixing maps inside one campaign makes the score harder to interpret.

Recommended initial campaigns:

- `SCMP_036` for the current M27 benchmark problem
- a 5x5 land map for opening mex/factory tempo
- a naval map after land economy is stable

After promotion, run one normal validation game before stacking more changes. If the promoted config improves score but creates obvious bad behavior, revert the config and narrow the tunable range instead of adding another special-case rule.
