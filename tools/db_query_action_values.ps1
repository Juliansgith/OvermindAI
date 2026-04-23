param(
    [string]$Subsystem = '',
    [string]$ActionType = '',
    [string]$FailureClass = '',
    [int]$WindowSeconds = 120,
    [int]$MinSamples = 10,
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

if (-not [string]::IsNullOrWhiteSpace($FailureClass)) {
    $query = @"
select
    map_name,
    opponent_key,
    primary_failure_class,
    subsystem,
    action_type,
    action_value,
    window_seconds,
    samples,
    avg_event_time,
    avg_reward,
    avg_delta_mex_ready,
    avg_delta_factory_total,
    avg_delta_reclaim_mass,
    avg_delta_map_control,
    survival_rate,
    avg_final_mass_ratio
from autotune.v_action_failure_precursors
where primary_failure_class = $(ConvertTo-AutotuneSqlLiteral $FailureClass)
  and window_seconds = $(ConvertTo-AutotuneSqlLiteral $WindowSeconds)
  and samples >= $(ConvertTo-AutotuneSqlLiteral $MinSamples)
$(if (-not [string]::IsNullOrWhiteSpace($Subsystem)) { "  and subsystem = $(ConvertTo-AutotuneSqlLiteral $Subsystem)" } else { '' })
$(if (-not [string]::IsNullOrWhiteSpace($ActionType)) { "  and action_type = $(ConvertTo-AutotuneSqlLiteral $ActionType)" } else { '' })
$(if (-not [string]::IsNullOrWhiteSpace($MapName)) { "  and map_name = $(ConvertTo-AutotuneSqlLiteral $MapName)" } else { '' })
$(if (-not [string]::IsNullOrWhiteSpace($OpponentKey)) { "  and opponent_key = $(ConvertTo-AutotuneSqlLiteral $OpponentKey)" } else { '' })
order by avg_reward asc, samples desc, subsystem, action_type, action_value;
"@
} else {
    $query = @"
select
    subsystem,
    action_type,
    action_value,
    window_seconds,
    samples,
    avg_reward,
    reward_stddev,
    avg_delta_mex_ready,
    avg_delta_factory_total,
    avg_delta_reclaim_mass,
    avg_delta_map_control,
    avg_delta_idle_factories,
    avg_delta_engineer_count,
    avg_delta_force_guard,
    avg_delta_force_main,
    avg_delta_force_outer,
    avg_delta_force_raid,
    survival_rate,
    end_rate,
    avg_final_mass_ratio
from autotune.v_action_value_by_choice
where window_seconds = $(ConvertTo-AutotuneSqlLiteral $WindowSeconds)
  and samples >= $(ConvertTo-AutotuneSqlLiteral $MinSamples)
$(if (-not [string]::IsNullOrWhiteSpace($Subsystem)) { "  and subsystem = $(ConvertTo-AutotuneSqlLiteral $Subsystem)" } else { '' })
$(if (-not [string]::IsNullOrWhiteSpace($ActionType)) { "  and action_type = $(ConvertTo-AutotuneSqlLiteral $ActionType)" } else { '' })
order by avg_reward desc, samples desc, subsystem, action_type, action_value;
"@
}

$rows = Invoke-AutotuneSqlQuery -Settings $settings -Query $query -Quiet
$rows | ForEach-Object { Write-Output $_ }
