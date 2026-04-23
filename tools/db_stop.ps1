param(
    [string]$ComposeFile = '',
    [string]$EnvFile = '',
    [string]$ProjectName = 'overmind-autotune',
    [switch]$DestroyData
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib\AutotuneDb.ps1')

$settings = Get-AutotuneDbSettings -ComposeFile $ComposeFile -EnvFile $EnvFile -ProjectName $ProjectName
Stop-AutotuneDb -Settings $settings -DestroyData:$DestroyData

if ($DestroyData) {
    Write-Host 'Autotune DB stopped and volume destroyed.'
} else {
    Write-Host 'Autotune DB stopped.'
}
