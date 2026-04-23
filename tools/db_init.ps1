param(
    [string]$ComposeFile = '',
    [string]$EnvFile = '',
    [string]$ProjectName = 'overmind-autotune'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib\AutotuneDb.ps1')

$repoRoot = Split-Path -Parent $PSScriptRoot
$settings = Get-AutotuneDbSettings -RepoRoot $repoRoot -ComposeFile $ComposeFile -EnvFile $EnvFile -ProjectName $ProjectName

Start-AutotuneDb -Settings $settings -IncludeAdminer
Invoke-AutotunePsqlFile -Settings $settings -Path (Join-Path $repoRoot 'sql\autotune-db\001_schema.sql')
Invoke-AutotunePsqlFile -Settings $settings -Path (Join-Path $repoRoot 'sql\autotune-db\002_views.sql')

Write-Host 'Autotune DB schema initialized.'
