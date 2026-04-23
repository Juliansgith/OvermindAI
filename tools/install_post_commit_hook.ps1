param(
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$hookDir = Join-Path $repoRoot '.git\hooks'
$hookPath = Join-Path $hookDir 'post-commit'

if (-not (Test-Path $hookDir)) {
    throw "Hook directory not found: $hookDir"
}

if ((Test-Path $hookPath) -and -not $Force) {
    $existing = Get-Content -LiteralPath $hookPath -Raw
    if ($existing -match 'release_checks\.ps1' -and $existing -match 'SkipSyntax') {
        Write-Host "HOOK_OK already installed: $hookPath"
        exit 0
    }
    throw "Hook already exists at $hookPath. Re-run with -Force to overwrite."
}

$hookScript = @'
#!/bin/sh
repo_root="$(git rev-parse --show-toplevel 2>/dev/null)"
if [ -z "$repo_root" ]; then
  exit 0
fi

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$repo_root/tools/release_checks.ps1" -SkipSyntax
exit 0
'@

Set-Content -LiteralPath $hookPath -Value $hookScript -Encoding Ascii
Write-Host "HOOK_INSTALLED $hookPath"
