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
