param(
    [string]$ParamName = '',
    [string]$FailureClass = '',
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
    primary_failure_class,
    param_name,
    samples,
    avg_value,
    avg_score,
    avg_mass_ratio,
    avg_game_time
from autotune.v_failure_param_effects
where primary_failure_class = $(ConvertTo-AutotuneSqlLiteral $FailureClass)
$(if (-not [string]::IsNullOrWhiteSpace($ParamName)) { "and param_name = $(ConvertTo-AutotuneSqlLiteral $ParamName)" } else { '' })
order by avg_score desc, param_name;
"@
} else {
    $query = @"
select
    param_name,
    samples,
    avg_value,
    avg_score,
    avg_mass_ratio,
    avg_game_time,
    score_corr,
    mass_ratio_corr,
    game_time_corr
from autotune.v_param_effects
$(if (-not [string]::IsNullOrWhiteSpace($ParamName)) { "where param_name = $(ConvertTo-AutotuneSqlLiteral $ParamName)" } else { '' })
order by score_corr desc nulls last, param_name;
"@
}

$rows = Invoke-AutotuneSqlQuery -Settings $settings -Query $query -Quiet
$rows | ForEach-Object { Write-Output $_ }
