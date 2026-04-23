param(
    [string]$OutputDir = '',
    [int]$WindowSeconds = 120,
    [string]$MapName = '',
    [string]$OpponentKey = '',
    [switch]$IncludeBaseline,
    [switch]$IncludeJson,
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
    $OutputDir = Join-Path $repoRoot 'autotune\action-datasets'
}
if (-not (Test-Path -LiteralPath $OutputDir)) {
    $null = New-Item -ItemType Directory -Path $OutputDir -Force
}

$settings = Get-AutotuneDbSettings -RepoRoot $repoRoot -ComposeFile $ComposeFile -EnvFile $EnvFile -ProjectName $ProjectName
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

$query = @"
select
    sr.session_id,
    sr.map_name,
    sr.opponent_key,
    sr.ai_matchup,
    cr.candidate_id,
    cr.primary_failure_class,
    cr.score as candidate_score,
    cr.avg_mass_ratio as candidate_avg_mass_ratio,
    cr.avg_game_time as candidate_avg_game_time,
    ae.log_name,
    ae.event_index,
    ae.event_time,
    ae.subsystem,
    ae.action_type,
    ae.action_key,
    ae.action_value,
    ae.mex_ready,
    ae.fac_total,
    ae.reclaim_mass,
    ae.map_control,
    ae.idle_factories,
    ae.engineer_count,
    ae.force_guard,
    ae.force_main,
    ae.force_outer,
    ae.force_raid,
    ae.strategy_dir,
    ae.production_mode,
    ao.window_seconds,
    ao.reward,
    ao.delta_mex_ready,
    ao.delta_factory_total,
    ao.delta_reclaim_mass,
    ao.delta_map_control,
    ao.delta_idle_factories,
    ao.delta_engineer_count,
    ao.delta_force_guard,
    ao.delta_force_main,
    ao.delta_force_outer,
    ao.delta_force_raid,
    ao.survived_window,
    ao.game_ended_within_window,
    ao.final_mass_ratio
from autotune.action_events ae
join autotune.action_outcomes ao
    on ao.session_id = ae.session_id
   and ao.candidate_id = ae.candidate_id
   and ao.log_name = ae.log_name
   and ao.event_index = ae.event_index
join autotune.candidate_results cr
    on cr.session_id = ae.session_id
   and cr.candidate_id = ae.candidate_id
join autotune.session_runs sr
    on sr.session_id = ae.session_id
where sr.session_kind = 'economy'
  and ao.window_seconds = $(ConvertTo-AutotuneSqlLiteral $WindowSeconds)
$(if (-not $IncludeBaseline) { "  and cr.candidate_id <> 'baseline'" } else { '' })
$(if (-not [string]::IsNullOrWhiteSpace($MapName)) { "  and sr.map_name = $(ConvertTo-AutotuneSqlLiteral $MapName)" } else { '' })
$(if (-not [string]::IsNullOrWhiteSpace($OpponentKey)) { "  and sr.opponent_key = $(ConvertTo-AutotuneSqlLiteral $OpponentKey)" } else { '' })
order by sr.session_id, cr.candidate_id, ae.log_name, ae.event_index
"@

$rows = Query-AsCsvRows -Settings $settings -Query $query
$csvPath = Join-Path $OutputDir ("action-dataset-{0}.csv" -f $stamp)
$rows | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8
Write-Host ("Action dataset CSV written: {0} ({1} rows)" -f $csvPath, $rows.Count)

if ($IncludeJson) {
    $jsonPath = Join-Path $OutputDir ("action-dataset-{0}.json" -f $stamp)
    $rows | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $jsonPath -Encoding UTF8
    Write-Host "Action dataset JSON written: $jsonPath"
}
