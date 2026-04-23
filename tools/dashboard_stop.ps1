param(
    [string]$ComposeFile = '',
    [string]$EnvFile = '',
    [string]$ProjectName = 'overmind-autotune'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib\AutotuneDb.ps1')

$settings = Get-AutotuneDbSettings -ComposeFile $ComposeFile -EnvFile $EnvFile -ProjectName $ProjectName
Stop-AutotuneDashboard -Settings $settings

Write-Host 'Autotune dashboard stopped.'
