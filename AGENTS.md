# OvermindAI Workflow

## Canonical Repo
- Work in this directory only:
  - `C:\Program Files (x86)\Steam\steamapps\common\Supreme Commander Forged Alliance\mods\OvermindAI`
- Do not treat the live mod mirrors as source-of-truth.

## Live Mod Mirrors
- `C:\Users\Sepgi\Documents\My Games\Gas Powered Games\Supreme Commander Forged Alliance\Mods\OvermindAI`
- `C:\ProgramData\FAForever\user\My Games\Gas Powered Games\Supreme Commander Forged Alliance\mods\OvermindAI`

## Version Rules
- Every shipped AI version must update both:
  - `mod_info.lua`
  - `lua\AI\Overmind\Bootstrap.lua`
- Keep one git commit per shipped version.
- Commit message format:
  - `vNN: short-description`
  - example: `v84: mainline bomber transition`

## Required Release Steps
1. Make code changes in the canonical repo only.
2. Update version number and build fingerprint.
3. Run the release helper:
   - `powershell -ExecutionPolicy Bypass -File .\tools\release_checks.ps1`
4. Confirm the Lua syntax pass succeeded.
5. Confirm both live mirrors synced successfully.
6. Commit the version immediately in the same turn, before reporting the release as done:
   - `git add -A`
   - `git commit -m "vNN: short-description"`

## Git Hook Sync
- Install the post-commit mirror sync hook once per clone:
  - `powershell -ExecutionPolicy Bypass -File .\tools\install_post_commit_hook.ps1`
- What it does:
  - after every local commit, runs `tools\release_checks.ps1 -SkipSyntax`
  - mirrors canonical repo to both live mod copies (`Documents` and `ProgramData\FAForever`)
- If you need to reinstall or overwrite:
  - `powershell -ExecutionPolicy Bypass -File .\tools\install_post_commit_hook.ps1 -Force`

## Test Run Rules
- Primary objective is win rate versus M27.
- Always run exactly 1 validation game first after each version bump.
- Only run multi-instance batches when the single validation game is promising.
- Preferred batch mode after a promising single run:
  - 10 games total in `2 x 5` parallel instances.
- Keep autorun in FAF, `windowed`, and with explicit sim speed on every launch.
- For long campaigns (up to 100 games), archive analysis outputs per batch and do not rely on replay retention alone.
- Use log-based analysis as source of truth when replay count limits are reached.

## Autorun Commands
- Default run (FAF, windowed, default `25x` sim speed, 2 instances):
  - `powershell -ExecutionPolicy Bypass -File C:\Program Files (x86)\Steam\steamapps\common\Supreme Commander Forged Alliance\autorun\bin\start_autorun_parallel.ps1`
- Single validation run:
  - `powershell -ExecutionPolicy Bypass -File C:\Program Files (x86)\Steam\steamapps\common\Supreme Commander Forged Alliance\autorun\bin\start_autorun_parallel.ps1 -Instances 1`
- Preferred parallel batch (5 at once):
  - `powershell -ExecutionPolicy Bypass -File C:\Program Files (x86)\Steam\steamapps\common\Supreme Commander Forged Alliance\autorun\bin\start_autorun_parallel.ps1 -Instances 5`
- Full 10-game run as `2 x 5`:
  - run the same `-Instances 5` command twice with different `-BaseSeed` values.
- Override map:
  - add `-MapName SCMP_004`
- Override speed:
  - add `-TargetSpeed 25` (or another speed).
- Fixed seeds (reproducible):
  - add `-BaseSeed 123456`
- Time limits:
  - add `-MaxGameSeconds 3600 -MaxRealSeconds 900`
- Exit delay after Game Over:
  - add `-ExitDelaySeconds 4`
- Keep fullscreen prefs untouched:
  - add `-SkipForceWindowed`
- Show in-game log window:
  - add `-ShowLog`
- Dry run (print launch commands only):
  - add `-DryRun`
- Override executable/init/template/log paths:
  - `-ExePath ... -InitFile ... -TemplateConfigPath ... -GeneratedLuaDir ... -LogDir ...`

## Log Analysis Commands
- Analyze latest logs:
  - `powershell -ExecutionPolicy Bypass -File C:\Program Files (x86)\Steam\steamapps\common\Supreme Commander Forged Alliance\autorun\bin\analyze_autorun_logs.ps1 -Latest 10`
- Analyze specific run tag:
  - `powershell -ExecutionPolicy Bypass -File C:\Program Files (x86)\Steam\steamapps\common\Supreme Commander Forged Alliance\autorun\bin\analyze_autorun_logs.ps1 -LogsPath "C:\Program Files (x86)\Steam\steamapps\common\Supreme Commander Forged Alliance\autorun\logs\autorun-20260423-*.log" -OutputDir "C:\Program Files (x86)\Steam\steamapps\common\Supreme Commander Forged Alliance\autorun\analysis\session-20260423"`

## Advanced Analysis Tools
- Version-vs-version comparator:
  - `powershell -ExecutionPolicy Bypass -File C:\Program Files (x86)\Steam\steamapps\common\Supreme Commander Forged Alliance\autorun\bin\compare_autorun_versions.ps1 -BaselineDir "...\analysis\v200_batch1" -CandidateDir "...\analysis\v201_single" -BaselineLabel v200 -CandidateLabel v201 -OutputDir "...\analysis\comparisons\v201-vs-v200"`
- Early-game KPI extractor (mex/factory timings, expansion, reclaim-field, stagnation, mass ratio):
  - `powershell -ExecutionPolicy Bypass -File C:\Program Files (x86)\Steam\steamapps\common\Supreme Commander Forged Alliance\autorun\bin\extract_autorun_kpis.ps1 -LogsPath "...\autorun\logs\autorun-20260423-*.log" -OutputDir "...\autorun\analysis\kpis\session-20260423"`
- Parallel determinism/divergence checker:
  - `powershell -ExecutionPolicy Bypass -File C:\Program Files (x86)\Steam\steamapps\common\Supreme Commander Forged Alliance\autorun\bin\measure_autorun_divergence.ps1 -LogsPath "...\autorun\logs\autorun-20260423-090129-i*.log" -OutputDir "...\autorun\analysis\divergence\20260423-090129"`
- Failure classifier (root-cause grouped warning/error classes):
  - `powershell -ExecutionPolicy Bypass -File C:\Program Files (x86)\Steam\steamapps\common\Supreme Commander Forged Alliance\autorun\bin\classify_autorun_failures.ps1 -LogsPath "...\autorun\logs\autorun-20260423-*.log" -OutputDir "...\autorun\analysis\failures\session-20260423"`
- Campaign manager (validation-first, chunked batches, resume state, defaults to `25x`):
  - `powershell -ExecutionPolicy Bypass -File C:\Program Files (x86)\Steam\steamapps\common\Supreme Commander Forged Alliance\autorun\bin\run_autorun_campaign.ps1 -VersionTag v201 -TotalGames 100 -ParallelInstances 5`

## Replay Archiving
- Archive replays by version/run tag into `autorun\replay_archive\<version>\<runTag>\...`:
  - `powershell -ExecutionPolicy Bypass -File C:\Program Files (x86)\Steam\steamapps\common\Supreme Commander Forged Alliance\autorun\bin\archive_autorun_replays.ps1 -VersionTag v201 -RunTag 20260423-090129`
- The campaign manager calls replay archiving automatically after each batch unless `-NoReplayArchive` is set.

## Do Not Skip
- Do not ship a version without a passing Lua syntax check.
- Do not leave a completed version synced but uncommitted.
- Do not defer the commit to a later turn once a version has been synced.
- Do not edit the live mirror copies directly unless recovering from a broken sync.

## File Size Policy
- Target all new or actively refactored Lua files to stay under `800` lines.
- Treat `800` lines as the planning limit, not the emergency limit.
- If a file is trending past `800`, split it before adding more behavior.
- Avoid creating `1000+` line files going forward unless the engine forces a single-file shape.
- Prefer medium-sized responsibility modules over dozens of one-function files.

## Subsystem Structure Going Forward
- For large subsystems, use this shape:
  - `lua\AI\Overmind\SubsystemName.lua`
  - `lua\AI\Overmind\SubsystemNameLegacy.lua` when a stable fallback is needed
  - `lua\AI\Overmind\SubsystemNameModular.lua` when staging a refactor off the critical path
  - `lua\AI\Overmind\SubsystemName\*.lua` for responsibility-specific modules
- The active runtime entrypoint should stay thin.
- Put engine-facing exports in the top-level subsystem file.
- Put implementation details in the subsystem folder modules.

## Runtime Export Rules
- Keep the game-facing module shape compatible with existing callers.
- If `SubsystemContracts` or another loader expects a top-level `Update`, export a top-level `function Update(...)`.
- Do not silently switch a runtime-facing module from top-level exports to `return { Update = ... }` unless every caller is updated.

## Refactor Safety Rules
- Before refactoring a large subsystem, create a local backup or a committed legacy copy before switching the live runtime path.
- Do not destroy or overwrite the stable implementation before the new implementation has parity and has been validated in-game.
- During risky refactors, keep the runtime path conservative:
  - stable implementation live
  - modular implementation preserved nearby for continued work
- Prefer wrapper entrypoints over wholesale replacement when the new module graph is not battle-tested yet.

## Suggested Module Boundaries
- Split by responsibility, not by arbitrary line count.
- Good examples:
  - `Common`
  - `Policy`
  - `Threat`
  - `Recovery`
  - `Assignments`
  - `Expansion`
  - `Reclaim`
- Avoid circular imports.
- Prefer passing runtime/context explicitly instead of relying on large shared local state.

## Optional But Recommended
- Archive standout run logs under:
  - `C:\Users\Sepgi\AppData\Roaming\Forged Alliance Forever\logs\archived_runs`
- Keep one short notes file for any "best so far" run.
