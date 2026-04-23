# Autonomous Self-Improvement Design

## Purpose

This document describes the target design for making Overmind improve itself through automated overnight training.

The goal is not to put a fragile neural network directly inside FAF Lua. The goal is to make Overmind a deterministic, safe runtime policy engine whose behavior is controlled by learned configuration. The learning system runs outside the game, evaluates configs through autorun games, scores the results, and promotes only configs that beat the current champion under strict safety gates.

## Core Principle

FAF runtime should execute policy. Offline tooling should learn policy.

Runtime code should provide:

- safe actions
- fallback defaults
- sensor extraction
- hard constraints
- deterministic behavior
- readable logs

Learned config should provide:

- priorities
- thresholds
- timing biases
- risk tolerance
- branch preferences
- map-control posture
- economy/combat tradeoff weights

Offline trainer should provide:

- candidate generation
- game launching
- log analysis
- scoring
- champion/challenger comparison
- promotion or rollback
- historical result tracking

The AI should not become nonfunctional without a config. Missing or invalid configs should fall back to a safe baseline.

## Current State

The current autotune system can already:

- mutate bounded economy config values
- run multiple autorun games in parallel
- score each candidate
- reject candidates with runtime errors
- promote a candidate if it beats baseline score
- sync the promoted config into active install paths

The important runtime config loading bug is fixed as of v260. `AutoTuneConfig.lua` now exports `Config = { ... }`, and runtime logs confirm the active candidate is loaded through `*OVERMIND AUTOTUNE`.

What is not solved yet:

- scoring can still be made more matchup-specific as more logs accumulate
- the exposed policy genome is still hand-designed, not a learned neural model
- combat and pathing knobs are intentionally still narrower than economy/strategy knobs
- map-specific champion selection is not implemented yet

## Why Not Train A Neural Network Inside FAF

FAF Lua is the wrong place to train or run a real neural network.

Problems:

- slow execution environment
- limited tooling
- hard to debug
- hard to reproduce
- unsafe if the model produces invalid actions
- opaque behavior during live games
- difficult rollback

A neural network can still be useful outside FAF as a candidate generator or scoring surrogate. It should not directly control units in live simulation.

The better architecture is:

```text
game logs -> feature extractor -> offline optimizer/model -> candidate config -> autorun games -> score -> promote/reject
```

## Target Architecture

```text
                   +-------------------+
                   | Champion Config   |
                   +---------+---------+
                             |
                             v
                   +-------------------+
                   | Candidate Builder |
                   +---------+---------+
                             |
                             v
                   +-------------------+
                   | Autorun Campaign  |
                   +---------+---------+
                             |
                             v
                   +-------------------+
                   | Log/KPI Extractor |
                   +---------+---------+
                             |
                             v
                   +-------------------+
                   | Multi-Objective   |
                   | Scorer            |
                   +---------+---------+
                             |
                             v
                   +-------------------+
                   | Promotion Gates   |
                   +----+---------+----+
                        |         |
                        v         v
                  Promote       Reject
```

Runtime modules should not read arbitrary candidate files. They should read only the promoted runtime config.

## Policy Genome

Long term, Overmind should expose a policy genome instead of scattered local thresholds.

Example shape:

```lua
Config = {
    Economy = {
        ExpansionRisk = 0.0,
        ReclaimUrgency = 0.0,
        FactoryGreed = 0.0,
        EngineerFloor = 0,
        MexUpgradeDelay = 0,
        PowerSafety = 0.0,
    },

    Strategy = {
        OuterRetentionBias = 0.0,
        HomePanicThreshold = 0.0,
        AttackCommitment = 0.0,
        RetreatDiscipline = 0.0,
        TechGreed = 0.0,
    },

    Combat = {
        RaidBias = 0.0,
        MainForceBias = 0.0,
        ACURisk = 0.0,
        ForwardCohortReserve = 0.0,
        AntiRaidReserve = 0.0,
    },

    Map = {
        ContestDistance = 0.0,
        SafeMexRadius = 0.0,
        ExpansionClusterValue = 0.0,
        ReclaimFieldValue = 0.0,
    },
}
```

Each field must have:

- minimum value
- maximum value
- mutation step
- runtime clamp
- default value
- documented behavior

The runtime may add more fields over time, but every tunable must be bounded.

## Scoring Objectives

The scorer should not rely on one naive score. It should compute separate objective metrics first:

- survival time
- win rate
- mass income ratio versus opponent
- mass spend ratio versus opponent
- mex count at 2, 4, 6, 10 minutes
- factory count at 4, 6, 10 minutes
- reclaim orders
- reclaim mass
- expansion orders
- first expansion time
- ACU death time
- engineer count after 4 minutes
- runtime errors
- fallback events
- modular engineer errors

Then it can derive a ranking score from those metrics.

## Anti-Stall Rules

The current failure mode is that Overmind can sometimes survive longer while becoming poorer. That must not promote.

Promotion should heavily penalize:

- long survival with mass ratio below `0.22`
- no expansion orders
- no reclaim-field orders
- mex count below expected timing
- many factories with no mex growth
- low spend ratio
- ACU hiding while map control collapses

Recommended scoring shape:

```text
reward survival, but less than before
reward mass ratio strongly
reward spend ratio
reward early mex count
reward reclaim conversion
reward expansion orders
penalize low mass ratio
penalize long low-economy survival
penalize runtime errors hard
```

Long survival should only receive a major bonus if mass ratio is also acceptable.

## Promotion Gates

Promotion should require more than better score.

A candidate should promote only if:

- runtime is clean
- no modular engineer errors occurred
- no runtime fallback occurred
- score beats champion by configured margin
- mass ratio does not regress
- survival does not collapse
- mex timing does not regress badly
- factory timing does not regress badly
- promotion is confirmed on fresh retest seeds

Suggested economy-focused minimums:

```text
candidate.AvgMassRatio >= baseline.AvgMassRatio + 0.03
candidate.AvgGameTime >= baseline.AvgGameTime * 0.80
candidate.RuntimeClean == true
candidate.Errors == 0
```

For a broader all-purpose policy, require either:

```text
candidate wins more often
```

or:

```text
candidate improves mass ratio and does not collapse survival
```

or:

```text
candidate improves survival and does not regress mass ratio
```

Never promote a candidate that only survives longer while becoming poorer.

## Champion/Challenger Flow

The overnight system should use champion/challenger testing.

Recommended loop:

```text
1. Load current champion.
2. Generate a population of challengers.
3. Run each challenger over N games.
4. Rank by multi-objective score.
5. Select top 3.
6. Retest top 3 on fresh seeds.
7. Retest current champion on the same fresh seeds.
8. Promote only if a challenger still wins.
9. Archive all configs and summaries.
10. Repeat until stopped.
```

This avoids promoting lucky candidates from one seed set.

## Overnight Mode

The overnight runner should be separate from the base tuner.

Recommended command shape:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\run_overnight_autotune.ps1 `
    -Campaigns 20 `
    -Candidates 12 `
    -GamesPerCandidate 20 `
    -ParallelInstances 20 `
    -TargetSpeed 20 `
    -MapName SCMP_036 `
    -RequireMassRatioGain 0.03 `
    -RetestTop 3 `
    -RetestGames 20
```

Required overnight features:

- `-NoPromote`
- `-RequireMassRatioGain`
- `-MinMassRatioAbsolute`
- `-MinAvgGameTime`
- `-RequireNoRuntimeErrors`
- `-RetestTop`
- `-RetestMaps`
- `-ChampionDir`
- `-MaxCampaigns`
- `-StopOnPromotion`
- `-RestoreChampionOnExit`
- `-WriteDashboard`

The runner should be safe to stop at any time. On exit, it should restore the current champion config.

## Implemented Tooling

The current offline-learning tooling is split across:

- `tools/run_economy_autotune.ps1`
- `tools/run_overnight_autotune.ps1`

The base tuner now supports:

- report-only mode with `-NoPromote`
- explicit restore behavior with `-RestoreOriginalOnExit`
- absolute promotion gates with `-MinMassRatioAbsolute`
- minimum survival gates with `-MinAvgGameTime`
- mass-ratio gain gates with `-RequireMassRatioGain`
- bounded survival regression with `-MaxSurvivalRegression`
- multi-map retest packs with `-RetestMaps`
- top-candidate retesting with `-RetestTop` and `-RetestGames`
- adaptive mutation hints from previous `score.json` files
- failure-aware mutation from the current best candidate's dominant failure class
- failure classification per candidate
- JSON summaries and Markdown session reports
- champion archiving on promotion

The promoted runtime config now affects more than narrow economy thresholds. The learner can directly bias:

- strategic posture: expand, stabilize, tempo, tech, air-response, and forward theater preference
- reclaim behavior: field risk tolerance, required support, and nearby opportunistic reclaim sensitivity
- upgrade behavior: mex upgrade budget, mex upgrade risk, mex upgrade concurrency, first land HQ timing, and first land HQ eco strictness
- existing economy behavior: factory floors, factory tempo, expansion safety, reclaim quotas, radar/air timing, ACU distance, and power safety

The overnight runner now supports:

- repeated campaigns
- promotion-safe gates passed through to the base tuner
- optional report-only operation
- optional stop after first promotion
- optional original-config restore on abort
- overnight JSON and Markdown reports

Recommended safe overnight command:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\run_overnight_autotune.ps1 `
    -Campaigns 20 `
    -Candidates 12 `
    -GamesPerCandidate 20 `
    -ParallelInstances 20 `
    -TargetSpeed 20 `
    -MapName SCMP_036 `
    -RequireMassRatioGain 0.03 `
    -MinMassRatioAbsolute 0.25 `
    -MinAvgGameTime 700 `
    -RetestTop 3 `
    -RetestGames 20 `
    -RetestMaps "SCMP_036" `
    -StopOnPromotion
```

Recommended report-only exploration command:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\run_overnight_autotune.ps1 `
    -Campaigns 20 `
    -Candidates 12 `
    -GamesPerCandidate 20 `
    -ParallelInstances 20 `
    -TargetSpeed 20 `
    -MapName SCMP_036 `
    -RequireMassRatioGain 0.03 `
    -MinMassRatioAbsolute 0.25 `
    -MinAvgGameTime 700 `
    -RetestTop 3 `
    -RetestGames 20 `
    -NoPromote
```

Use `-DisableAdaptiveMutation` if historical results are suspected to bias the search in a bad direction.

## Config Archive

Every champion should be archived.

Suggested layout:

```text
autotune/
  champions/
    current.lua
    v260-candidate-4.lua
    best-mass-ratio.lua
    best-survival.lua
    best-balanced.lua
  runs/
    20260423-155140/
      baseline/
      candidate-1/
      candidate-2/
      session-summary.json
      candidate-scores.csv
```

Each promoted config should include:

```lua
CandidateId = 'candidate-1'
ParentCandidateId = 'v260-candidate-4'
TrainingSession = '20260423-155140'
Score = 3275.88
AvgGameTime = 852.85
AvgMassRatio = 0.2125
PromotionReason = 'mass-ratio gain with acceptable survival'
```

## Smarter Candidate Generation

Random mutation is useful but inefficient.

Better next methods:

- evolutionary strategy
- cross-entropy method
- CMA-ES
- Bayesian optimization
- population-based training
- surrogate model proposal

Recommended progression:

1. Continue bounded random mutation until metrics are stable.
2. Add champion/challenger retesting.
3. Add mutation range adaptation.
4. Add a simple Python optimizer that learns from previous run summaries.
5. Add model-guided proposals after enough campaign history exists.

## Neural Network Role

A neural network can be used as an offline advisor, not as live gameplay logic.

Useful neural-network roles:

- predict whether a config is promising before spending games on it
- cluster logs into failure types
- estimate which tunables matter most
- suggest candidate configs from historical training data
- classify whether losses were caused by economy, combat, pathing, or strategy

Not recommended:

- direct live unit control
- live training inside FAF
- opaque neural decisions without constraints
- generating arbitrary Lua code

The neural system should output config proposals only.

## Safety Rules

The trainer must never:

- promote configs with runtime errors
- promote configs that fail to load
- promote configs that reduce mass ratio without a compensating win-rate gain
- leave a candidate config active after abort
- mutate outside bounded ranges
- generate arbitrary Lua code
- overwrite champion history

The runtime must always:

- clamp all values
- support fallback defaults
- log active config ID
- stay deterministic
- reject invalid config shapes

## Immediate Implementation Plan

1. Add `-NoPromote` to `run_economy_autotune.ps1`.
2. Add promotion gates:
   - minimum mass-ratio gain
   - maximum allowed survival regression
   - no runtime errors
   - no fallback events
3. Add `-RetestTop` and `-RetestGames`.
4. Add champion archive output.
5. Add `run_overnight_autotune.ps1`.
6. Add scoring dashboard summaries.
7. Add a smarter optimizer that reads prior `session-summary.json` files.
8. Expand the genome from economy-only to strategy/combat/map-control policy.

## Success Criteria

Short-term success:

- overnight run completes without leaving dirty config state
- promoted configs always load correctly in runtime logs
- average mass ratio improves without catastrophic survival loss
- no runtime errors or fallback events

Medium-term success:

- Overmind reliably survives past 15 minutes versus M27 on `SCMP_036`
- mass ratio exceeds `0.30`
- mex count and reclaim conversion improve visibly
- promoted configs remain stable across fresh seed retests

Long-term success:

- Overmind survives 35+ minutes against M27
- Overmind contests map economy instead of only stalling
- champion configs generalize across multiple land maps
- offline optimizer can run unattended for thousands of games and produce useful candidates
