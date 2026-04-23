param(
    [string]$OutputDir = '',
    [int]$WindowSeconds = 120,
    [int]$MinSamples = 10,
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

$bestChoices = Query-AsCsvRows -Settings $settings -Query @"
select subsystem, action_type, action_value, samples, avg_reward, avg_delta_mex_ready, avg_delta_factory_total,
       avg_delta_reclaim_mass, avg_delta_map_control, survival_rate, avg_final_mass_ratio
from autotune.v_action_value_by_choice
where window_seconds = $(ConvertTo-AutotuneSqlLiteral $WindowSeconds)
  and samples >= $(ConvertTo-AutotuneSqlLiteral $MinSamples)
order by avg_reward desc, samples desc
limit 20
"@

$worstChoices = Query-AsCsvRows -Settings $settings -Query @"
select subsystem, action_type, action_value, samples, avg_reward, avg_delta_mex_ready, avg_delta_factory_total,
       avg_delta_reclaim_mass, avg_delta_map_control, survival_rate, avg_final_mass_ratio
from autotune.v_action_value_by_choice
where window_seconds = $(ConvertTo-AutotuneSqlLiteral $WindowSeconds)
  and samples >= $(ConvertTo-AutotuneSqlLiteral $MinSamples)
order by avg_reward asc, samples desc
limit 20
"@

$subsystems = Query-AsCsvRows -Settings $settings -Query @"
select subsystem, action_type, samples, avg_reward, avg_delta_mex_ready, avg_delta_factory_total,
       avg_delta_reclaim_mass, avg_delta_map_control, survival_rate, avg_final_mass_ratio
from autotune.v_action_value_by_subsystem
where window_seconds = $(ConvertTo-AutotuneSqlLiteral $WindowSeconds)
  and samples >= $(ConvertTo-AutotuneSqlLiteral $MinSamples)
order by avg_reward desc, samples desc
limit 20
"@

$precursors = Query-AsCsvRows -Settings $settings -Query @"
select map_name, opponent_key, primary_failure_class, subsystem, action_type, action_value, samples,
       avg_event_time, avg_reward, avg_delta_mex_ready, avg_delta_factory_total, avg_delta_reclaim_mass,
       avg_delta_map_control, survival_rate, avg_final_mass_ratio
from autotune.v_action_failure_precursors
where window_seconds = $(ConvertTo-AutotuneSqlLiteral $WindowSeconds)
  and samples >= $(ConvertTo-AutotuneSqlLiteral $MinSamples)
order by avg_reward asc, samples desc
limit 20
"@

$lines = @()
$lines += '# Action Learning Report'
$lines += ''
$lines += "- Generated: $((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))"
$lines += "- Window Seconds: $WindowSeconds"
$lines += "- Min Samples: $MinSamples"
$lines += "- Database: $($settings.Database)"
$lines += ''
$lines += '## Best Action Choices'
$lines += ''
$lines += '| Subsystem | Action Type | Action Value | Samples | Avg Reward | dMex | dFac | dReclaim | dMap | Survival | Final Mass |'
$lines += '| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |'
foreach ($row in $bestChoices) {
    $lines += "| $($row.subsystem) | $($row.action_type) | $($row.action_value) | $($row.samples) | $($row.avg_reward) | $($row.avg_delta_mex_ready) | $($row.avg_delta_factory_total) | $($row.avg_delta_reclaim_mass) | $($row.avg_delta_map_control) | $($row.survival_rate) | $($row.avg_final_mass_ratio) |"
}
$lines += ''
$lines += '## Worst Action Choices'
$lines += ''
$lines += '| Subsystem | Action Type | Action Value | Samples | Avg Reward | dMex | dFac | dReclaim | dMap | Survival | Final Mass |'
$lines += '| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |'
foreach ($row in $worstChoices) {
    $lines += "| $($row.subsystem) | $($row.action_type) | $($row.action_value) | $($row.samples) | $($row.avg_reward) | $($row.avg_delta_mex_ready) | $($row.avg_delta_factory_total) | $($row.avg_delta_reclaim_mass) | $($row.avg_delta_map_control) | $($row.survival_rate) | $($row.avg_final_mass_ratio) |"
}
$lines += ''
$lines += '## Subsystem Summary'
$lines += ''
$lines += '| Subsystem | Action Type | Samples | Avg Reward | dMex | dFac | dReclaim | dMap | Survival | Final Mass |'
$lines += '| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |'
foreach ($row in $subsystems) {
    $lines += "| $($row.subsystem) | $($row.action_type) | $($row.samples) | $($row.avg_reward) | $($row.avg_delta_mex_ready) | $($row.avg_delta_factory_total) | $($row.avg_delta_reclaim_mass) | $($row.avg_delta_map_control) | $($row.survival_rate) | $($row.avg_final_mass_ratio) |"
}
$lines += ''
$lines += '## Failure Precursors'
$lines += ''
$lines += '| Map | Opponent | Failure | Subsystem | Action Type | Action Value | Samples | Avg t | Avg Reward | dMex | dFac | dReclaim | dMap | Survival | Final Mass |'
$lines += '| --- | --- | --- | --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |'
foreach ($row in $precursors) {
    $lines += "| $($row.map_name) | $($row.opponent_key) | $($row.primary_failure_class) | $($row.subsystem) | $($row.action_type) | $($row.action_value) | $($row.samples) | $($row.avg_event_time) | $($row.avg_reward) | $($row.avg_delta_mex_ready) | $($row.avg_delta_factory_total) | $($row.avg_delta_reclaim_mass) | $($row.avg_delta_map_control) | $($row.survival_rate) | $($row.avg_final_mass_ratio) |"
}

$reportPath = Join-Path $OutputDir ("action-learning-report-{0}.md" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
Set-Content -LiteralPath $reportPath -Value ($lines -join [Environment]::NewLine) -Encoding UTF8
Write-Host "Action learning report written: $reportPath"
