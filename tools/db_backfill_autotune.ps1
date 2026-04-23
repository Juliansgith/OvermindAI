param(
    [string]$RunRoot = '',
    [switch]$StartDb,
    [switch]$InitSchema,
    [string]$ComposeFile = '',
    [string]$EnvFile = '',
    [string]$ProjectName = 'overmind-autotune'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-JsonSessionId {
    param([string]$Path)

    try {
        $summary = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        return [string]$summary.Session
    } catch {
        return $null
    }
}

$repoRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($RunRoot)) {
    $RunRoot = Join-Path $repoRoot 'autotune\runs'
}
if (-not (Test-Path -LiteralPath $RunRoot)) {
    throw "Run root not found: $RunRoot"
}

$sessionSummaries = @(Get-ChildItem -LiteralPath $RunRoot -Recurse -Filter 'session-summary.json' -ErrorAction SilentlyContinue |
    Sort-Object -Property FullName)
$overnightSummaries = @(Get-ChildItem -LiteralPath $RunRoot -Recurse -Filter 'overnight-summary.json' -ErrorAction SilentlyContinue |
    Sort-Object -Property FullName)

$sessionSummaries = @($sessionSummaries |
    Group-Object { Get-JsonSessionId -Path $_.FullName } |
    ForEach-Object { $_.Group | Select-Object -First 1 } |
    Sort-Object -Property FullName)
$overnightSummaries = @($overnightSummaries |
    Group-Object { Get-JsonSessionId -Path $_.FullName } |
    ForEach-Object { $_.Group | Select-Object -First 1 } |
    Sort-Object -Property FullName)

Write-Host ("Backfilling {0} economy session(s) and {1} overnight session(s) from {2}" -f $sessionSummaries.Count, $overnightSummaries.Count, $RunRoot)

$first = $true
foreach ($file in $sessionSummaries) {
    $args = @(
        '-ExecutionPolicy', 'Bypass',
        '-File', (Join-Path $PSScriptRoot 'db_ingest_autotune.ps1'),
        '-SessionSummaryPath', $file.FullName,
        '-ProjectName', $ProjectName
    )
    if (-not [string]::IsNullOrWhiteSpace($ComposeFile)) { $args += @('-ComposeFile', $ComposeFile) }
    if (-not [string]::IsNullOrWhiteSpace($EnvFile)) { $args += @('-EnvFile', $EnvFile) }
    if ($first -and $StartDb) { $args += '-StartDb' }
    if ($first -and $InitSchema) { $args += '-InitSchema' }
    & powershell @args
    if ($LASTEXITCODE -ne 0) {
        throw "Failed ingesting session summary: $($file.FullName)"
    }
    $first = $false
}

foreach ($file in $overnightSummaries) {
    $args = @(
        '-ExecutionPolicy', 'Bypass',
        '-File', (Join-Path $PSScriptRoot 'db_ingest_autotune.ps1'),
        '-OvernightSummaryPath', $file.FullName,
        '-ProjectName', $ProjectName
    )
    if (-not [string]::IsNullOrWhiteSpace($ComposeFile)) { $args += @('-ComposeFile', $ComposeFile) }
    if (-not [string]::IsNullOrWhiteSpace($EnvFile)) { $args += @('-EnvFile', $EnvFile) }
    & powershell @args
    if ($LASTEXITCODE -ne 0) {
        throw "Failed ingesting overnight summary: $($file.FullName)"
    }
}

Write-Host 'Backfill complete.'
