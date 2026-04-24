# External AI Research Workflow

This workflow compares Overmind against locally installed FA AI mods without copying their code into Overmind.

## Targets

- M28 from the game install mods folder.
- M27 from the game install mods folder.
- RNGAI from the user mods folder.
- Sorian Edit from the user mods folder.

## Run The Scan

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\compare_external_ai_repos.ps1 -IncludeOvermind
```

Outputs:

- `autotune\external-ai-research\external-ai-research.md`
- `autotune\external-ai-research\external-ai-file-scores.csv`
- `autotune\external-ai-research\external-ai-summary.json`

## Run The Overnight Watcher

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\watch_autotune_nightly.ps1
```

The watcher writes:

- `autotune\nightly-watch\latest.md`
- timestamped snapshots under `autotune\nightly-watch`

It does not mutate runtime AI code or learner config. It only reads the DB, the launch log, and process state.

## Lessons To Port Into Overmind

- Couple engineer, factory, mex, reclaim, and upgrade decisions through a single economic view. Independent builders can still execute work, but they should not independently decide what the economy can afford.
- Keep map labels, zones, paths, and threat attached to economy choices. Economic velocity is not just income and storage; it is whether new spend increases map ownership, reclaim conversion, and survivable production.
- Treat anti-idle as a hard invariant. Factories and engineers can be temporarily blocked by economy or danger, but sustained idleness should become a measurable failure.
- Track live upgrade spend and concurrency directly. The learner can tune caps, but the code must expose current mex-upgrade mass drain, pause state, priority, and recovery behavior.
- Preserve tactic support in code. The learner can tune probabilities and weights, but it cannot discover missing mechanics if Overmind lacks routes for ACU rescue, engineer repair, escorted reclaim, safe expansion, and outer-map force retention.

## Safe Nightly Rule

When a long campaign is running, do not change live `lua\AI\Overmind` runtime files. Add analysis tooling, reports, and dashboards only. Runtime changes during a campaign contaminate the dataset because later games no longer match the candidate config being evaluated.
