param(
    [string]$MapName = '',
    [string]$OpponentKey = '',
    [string]$ComposeFile = '',
    [string]$EnvFile = '',
    [string]$ProjectName = 'overmind-autotune'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib\AutotuneDb.ps1')

$repoRoot = Split-Path -Parent $PSScriptRoot
$settings = Get-AutotuneDbSettings -RepoRoot $repoRoot -ComposeFile $ComposeFile -EnvFile $EnvFile -ProjectName $ProjectName

$where = @()
if (-not [string]::IsNullOrWhiteSpace($MapName)) {
    $where += ("map_name = {0}" -f (ConvertTo-AutotuneSqlLiteral $MapName))
}
if (-not [string]::IsNullOrWhiteSpace($OpponentKey)) {
    $where += ("opponent_key = {0}" -f (ConvertTo-AutotuneSqlLiteral $OpponentKey))
}
$whereSql = if ($where.Count -gt 0) { 'where ' + ($where -join ' and ') } else { '' }

$query = @"
select
    map_name,
    opponent_key,
    session_id,
    candidate_id,
    score,
    avg_mass_ratio,
    avg_game_time,
    version,
    fingerprint,
    promoted_at
from autotune.v_current_champions
$whereSql
order by map_name, opponent_key, promoted_at desc;
"@

$rows = Invoke-AutotuneSqlQuery -Settings $settings -Query $query -Quiet
$rows | ForEach-Object { Write-Output $_ }
