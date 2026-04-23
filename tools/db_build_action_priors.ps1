param(
    [string]$OutputDir = '',
    [int]$WindowSeconds = 120,
    [int]$MinSamples = 15,
    [int]$TopChoicesPerAction = 5,
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
    $OutputDir = Join-Path $repoRoot 'autotune\action-priors'
}
if (-not (Test-Path -LiteralPath $OutputDir)) {
    $null = New-Item -ItemType Directory -Path $OutputDir -Force
}

$settings = Get-AutotuneDbSettings -RepoRoot $repoRoot -ComposeFile $ComposeFile -EnvFile $EnvFile -ProjectName $ProjectName
$rows = Query-AsCsvRows -Settings $settings -Query @"
select subsystem, action_type, action_value, samples, avg_reward, avg_delta_mex_ready, avg_delta_factory_total,
       avg_delta_reclaim_mass, avg_delta_map_control, survival_rate, avg_final_mass_ratio
from autotune.v_action_value_by_choice
where window_seconds = $(ConvertTo-AutotuneSqlLiteral $WindowSeconds)
  and samples >= $(ConvertTo-AutotuneSqlLiteral $MinSamples)
order by subsystem, action_type, avg_reward desc, samples desc
"@

$grouped = [ordered]@{}
foreach ($row in $rows) {
    $key = "{0}:{1}" -f $row.subsystem, $row.action_type
    if (-not $grouped.Contains($key)) {
        $grouped[$key] = [System.Collections.ArrayList]::new()
    }
    if ($grouped[$key].Count -ge $TopChoicesPerAction) {
        continue
    }
    $null = $grouped[$key].Add([ordered]@{
        action_value = $row.action_value
        samples = [int]$row.samples
        avg_reward = [double]$row.avg_reward
        avg_delta_mex_ready = [double]$row.avg_delta_mex_ready
        avg_delta_factory_total = [double]$row.avg_delta_factory_total
        avg_delta_reclaim_mass = [double]$row.avg_delta_reclaim_mass
        avg_delta_map_control = [double]$row.avg_delta_map_control
        survival_rate = [double]$row.survival_rate
        avg_final_mass_ratio = [double]$row.avg_final_mass_ratio
    })
}

$subsystems = [ordered]@{}
foreach ($entry in $grouped.GetEnumerator()) {
    $parts = $entry.Key.Split(':', 2)
    $subsystem = $parts[0]
    $actionType = $parts[1]
    if (-not $subsystems.Contains($subsystem)) {
        $subsystems[$subsystem] = [ordered]@{}
    }
    $subsystems[$subsystem][$actionType] = @($entry.Value)
}

$payload = [ordered]@{
    generated_at = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    window_seconds = $WindowSeconds
    min_samples = $MinSamples
    top_choices_per_action = $TopChoicesPerAction
    source_database = $settings.Database
    priors = $subsystems
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$jsonPath = Join-Path $OutputDir ("action-priors-{0}.json" -f $stamp)
$latestPath = Join-Path $OutputDir 'action-priors-latest.json'
$payload | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $jsonPath -Encoding UTF8
$payload | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $latestPath -Encoding UTF8
Write-Host "Action priors written: $jsonPath"
Write-Host "Latest action priors updated: $latestPath"
