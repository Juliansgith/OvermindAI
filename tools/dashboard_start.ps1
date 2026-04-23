param(
    [string]$ComposeFile = '',
    [string]$EnvFile = '',
    [string]$ProjectName = 'overmind-autotune',
    [switch]$DashboardOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib\AutotuneDb.ps1')

$settings = Get-AutotuneDbSettings -ComposeFile $ComposeFile -EnvFile $EnvFile -ProjectName $ProjectName
Start-AutotuneDashboard -Settings $settings -IncludeAdminer:(-not $DashboardOnly)

Write-Host ("Autotune DB ready: postgres=localhost:{0} db={1} user={2}" -f $settings.Port, $settings.Database, $settings.User)
if (-not $DashboardOnly) {
    Write-Host ("Adminer ready: http://localhost:{0}" -f $settings.AdminerPort)
}
Write-Host ("Dashboard ready: http://localhost:{0}" -f $settings.DashboardPort)
