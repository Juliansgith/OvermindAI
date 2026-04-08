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

## Optional But Recommended
- Archive standout run logs under:
  - `C:\Users\Sepgi\AppData\Roaming\Forged Alliance Forever\logs\archived_runs`
- Keep one short notes file for any "best so far" run.
