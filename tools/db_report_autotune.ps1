param(
    [string]$OutputDir = '',
    [string]$ComposeFile = '',
    [string]$EnvFile = '',
    [string]$ProjectName = 'overmind-autotune'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib\AutotuneDb.ps1')

function Query-AsCsvRows {
    param(
        $Settings,
        [string]$Query
    )

    $lines = Invoke-AutotuneSqlQuery -Settings $Settings -Query ("copy ({0}) to stdout with csv header" -f $Query) -Quiet
    if ($lines.Count -le 0) {
        return @()
    }
    return @($lines | ConvertFrom-Csv)
}

$repoRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Join-Path $repoRoot 'autotune\db-reports'
}
if (-not (Test-Path -LiteralPath $OutputDir)) {
    $null = New-Item -ItemType Directory -Path $OutputDir -Force
}

$settings = Get-AutotuneDbSettings -RepoRoot $repoRoot -ComposeFile $ComposeFile -EnvFile $EnvFile -ProjectName $ProjectName

$champions = Query-AsCsvRows -Settings $settings -Query @"
select map_name, opponent_key, session_id, candidate_id, score, avg_mass_ratio, avg_game_time, version, fingerprint, promoted_at
from autotune.v_current_champions
order by promoted_at desc
limit 20
"@

$profiles = Query-AsCsvRows -Settings $settings -Query @"
select map_name, opponent_key, ai_matchup, sessions, avg_best_score, avg_best_mass_ratio, avg_best_game_time, promotion_rate
from autotune.v_map_opponent_profiles
order by sessions desc, map_name, opponent_key
limit 20
"@

$hotspots = Query-AsCsvRows -Settings $settings -Query @"
select map_name, opponent_key, primary_failure_class, candidates, avg_mass_ratio, avg_game_time, avg_score
from autotune.v_failure_hotspots
order by candidates desc, avg_score asc
limit 20
"@

$params = Query-AsCsvRows -Settings $settings -Query @"
select param_name, samples, avg_value, avg_score, avg_mass_ratio, avg_game_time, score_corr, mass_ratio_corr, game_time_corr
from autotune.v_param_effects
order by score_corr desc nulls last
limit 20
"@

$lines = @()
$lines += '# Autotune DB Report'
$lines += ''
$lines += "- Generated: $((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))"
$lines += "- Database: $($settings.Database)"
$lines += "- Project: $($settings.ProjectName)"
$lines += ''
$lines += '## Current Champions'
$lines += ''
$lines += '| Map | Opponent | Session | Candidate | Score | Mass Ratio | Avg Time | Version | Fingerprint | Promoted At |'
$lines += '| --- | --- | --- | --- | ---: | ---: | ---: | ---: | --- | --- |'
foreach ($row in $champions) {
    $lines += "| $($row.map_name) | $($row.opponent_key) | $($row.session_id) | $($row.candidate_id) | $($row.score) | $($row.avg_mass_ratio) | $($row.avg_game_time) | $($row.version) | $($row.fingerprint) | $($row.promoted_at) |"
}
$lines += ''
$lines += '## Map/Opponent Profiles'
$lines += ''
$lines += '| Map | Opponent | Matchup | Sessions | Avg Best Score | Avg Best Mass Ratio | Avg Best Time | Promotion Rate |'
$lines += '| --- | --- | --- | ---: | ---: | ---: | ---: | ---: |'
foreach ($row in $profiles) {
    $lines += "| $($row.map_name) | $($row.opponent_key) | $($row.ai_matchup) | $($row.sessions) | $($row.avg_best_score) | $($row.avg_best_mass_ratio) | $($row.avg_best_game_time) | $($row.promotion_rate) |"
}
$lines += ''
$lines += '## Failure Hotspots'
$lines += ''
$lines += '| Map | Opponent | Failure | Candidates | Avg Mass Ratio | Avg Time | Avg Score |'
$lines += '| --- | --- | --- | ---: | ---: | ---: | ---: |'
foreach ($row in $hotspots) {
    $lines += "| $($row.map_name) | $($row.opponent_key) | $($row.primary_failure_class) | $($row.candidates) | $($row.avg_mass_ratio) | $($row.avg_game_time) | $($row.avg_score) |"
}
$lines += ''
$lines += '## Top Parameter Signals'
$lines += ''
$lines += '| Param | Samples | Avg Value | Avg Score | Avg Mass Ratio | Avg Time | Score Corr | Mass Corr | Time Corr |'
$lines += '| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |'
foreach ($row in $params) {
    $lines += "| $($row.param_name) | $($row.samples) | $($row.avg_value) | $($row.avg_score) | $($row.avg_mass_ratio) | $($row.avg_game_time) | $($row.score_corr) | $($row.mass_ratio_corr) | $($row.game_time_corr) |"
}

$reportPath = Join-Path $OutputDir ("autotune-db-report-{0}.md" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
Set-Content -LiteralPath $reportPath -Value ($lines -join [Environment]::NewLine) -Encoding UTF8
Write-Host "DB report written: $reportPath"
