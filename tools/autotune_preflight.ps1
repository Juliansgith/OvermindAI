param(
    [string]$ComposeFile = '',
    [string]$EnvFile = '',
    [string]$ProjectName = 'overmind-autotune',
    [switch]$StartDb,
    [switch]$StartDashboard
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib\AutotuneDb.ps1')

$settings = Get-AutotuneDbSettings -ComposeFile $ComposeFile -EnvFile $EnvFile -ProjectName $ProjectName
$repoRoot = Split-Path -Parent $PSScriptRoot
$configPath = Join-Path $repoRoot 'lua\AI\Overmind\AutoTuneConfig.lua'
$autorunRoot = 'C:\Program Files (x86)\Steam\steamapps\common\Supreme Commander Forged Alliance\autorun'
$autorunStartScript = Join-Path $autorunRoot 'bin\start_autorun_parallel.ps1'

$results = New-Object System.Collections.Generic.List[object]

function Add-CheckResult {
    param(
        [string]$Name,
        [bool]$Ok,
        [string]$Detail
    )

    $results.Add([pscustomobject]@{
        Check = $Name
        Ok = $Ok
        Detail = $Detail
    })
}

try {
    if ($StartDashboard) {
        Start-AutotuneDashboard -Settings $settings -IncludeAdminer
        Add-CheckResult -Name 'dashboard_start' -Ok $true -Detail "Started dashboard at http://localhost:$($settings.DashboardPort)"
    } elseif ($StartDb) {
        Start-AutotuneDb -Settings $settings -IncludeAdminer
        Add-CheckResult -Name 'db_start' -Ok $true -Detail "Started DB at localhost:$($settings.Port)"
    }
} catch {
    Add-CheckResult -Name 'db_start' -Ok $false -Detail $_.Exception.Message
}

try {
    Ensure-AutotuneDockerReady
    Add-CheckResult -Name 'docker' -Ok $true -Detail 'Docker daemon reachable'
} catch {
    Add-CheckResult -Name 'docker' -Ok $false -Detail $_.Exception.Message
}

try {
    $dbProbe = Invoke-AutotuneSqlQuery -Settings $settings -Query "select count(*) as sessions from autotune.session_runs;" -Quiet
    Add-CheckResult -Name 'database' -Ok $true -Detail (($dbProbe -join ' ').Trim())
} catch {
    Add-CheckResult -Name 'database' -Ok $false -Detail $_.Exception.Message
}

try {
    $schemaProbe = Invoke-AutotuneSqlQuery -Settings $settings -Query "select count(*) as tables from information_schema.tables where table_schema = 'autotune';" -Quiet
    Add-CheckResult -Name 'schema' -Ok $true -Detail (($schemaProbe -join ' ').Trim())
} catch {
    Add-CheckResult -Name 'schema' -Ok $false -Detail $_.Exception.Message
}

if (Test-Path -LiteralPath $configPath) {
    Add-CheckResult -Name 'config_path' -Ok $true -Detail $configPath
} else {
    Add-CheckResult -Name 'config_path' -Ok $false -Detail "Missing $configPath"
}

if (Test-Path -LiteralPath $autorunStartScript) {
    Add-CheckResult -Name 'autorun_script' -Ok $true -Detail $autorunStartScript
} else {
    Add-CheckResult -Name 'autorun_script' -Ok $false -Detail "Missing $autorunStartScript"
}

$runningFa = @(Get-Process -Name 'ForgedAlliance', 'SupremeCommander' -ErrorAction SilentlyContinue)
if ($runningFa.Count -eq 0) {
    Add-CheckResult -Name 'running_faf_processes' -Ok $true -Detail 'No active FAF game processes'
} else {
    $names = ($runningFa | Select-Object -ExpandProperty ProcessName | Sort-Object -Unique) -join ', '
    Add-CheckResult -Name 'running_faf_processes' -Ok $false -Detail "Active processes: $names"
}

try {
    $dashboardStatus = Invoke-WebRequest -UseBasicParsing -Uri ("http://localhost:{0}" -f $settings.DashboardPort) -TimeoutSec 5
    Add-CheckResult -Name 'dashboard_http' -Ok ($dashboardStatus.StatusCode -eq 200) -Detail ("HTTP {0}" -f $dashboardStatus.StatusCode)
} catch {
    Add-CheckResult -Name 'dashboard_http' -Ok $false -Detail $_.Exception.Message
}

try {
    $latest = Invoke-AutotuneSqlQuery -Settings $settings -Query @"
select
    coalesce(to_char(max(created_at), 'YYYY-MM-DD HH24:MI:SS TZ'), 'none') as latest_session,
    count(*) filter (where created_at >= now() - interval '24 hours') as sessions_last_24h
from autotune.session_runs
where session_kind = 'economy';
"@ -Quiet
    Add-CheckResult -Name 'recent_activity' -Ok $true -Detail (($latest -join ' ').Trim())
} catch {
    Add-CheckResult -Name 'recent_activity' -Ok $false -Detail $_.Exception.Message
}

$allOk = @($results | Where-Object { -not $_.Ok }).Count -eq 0
Write-Host ''
Write-Host 'Autotune Preflight'
Write-Host '------------------'
$results | ForEach-Object {
    $status = if ($_.Ok) { 'PASS' } else { 'FAIL' }
    Write-Host ("[{0}] {1}: {2}" -f $status, $_.Check, $_.Detail)
}
Write-Host ''
if ($allOk) {
    Write-Host 'Overall: PASS'
    exit 0
}

Write-Host 'Overall: FAIL'
exit 1
