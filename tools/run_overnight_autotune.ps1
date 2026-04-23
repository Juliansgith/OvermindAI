param(
    [int]$Campaigns = 10,
    [int]$Candidates = 12,
    [int]$GamesPerCandidate = 20,
    [int]$ParallelInstances = 20,
    [int]$TargetSpeed = 20,
    [string]$MapName = 'SCMP_036',
    [int]$BaseSeed = 0,
    [int]$MaxGameSeconds = 2400,
    [int]$MaxRealSeconds = 1200,
    [double]$PromoteScoreMargin = 0.03,
    [double]$MutationRate = 0.55,
    [double]$RequireMassRatioGain = 0.03,
    [double]$MinMassRatioAbsolute = 0,
    [double]$MaxMassRatioRegression = 0,
    [int]$MinAvgGameTime = 0,
    [double]$MaxSurvivalRegression = 0.25,
    [int]$RetestTop = 3,
    [int]$RetestGames = 20,
    [string]$RetestMaps = '',
    [string]$RunRoot = '',
    [string]$ChampionDir = '',
    [switch]$NoPromote,
    [switch]$StopOnPromotion,
    [switch]$RestoreOriginalOnExit,
    [switch]$DisableAdaptiveMutation,
    [switch]$UseDatabase,
    [switch]$DbInitSchema,
    [string]$DbComposeFile = '',
    [string]$DbEnvFile = '',
    [string]$DbProjectName = 'overmind-autotune',
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$ConfigPath = Join-Path $RepoRoot 'lua\AI\Overmind\AutoTuneConfig.lua'
$AutotuneScript = Join-Path $PSScriptRoot 'run_economy_autotune.ps1'
$ReleaseChecks = Join-Path $RepoRoot 'tools\release_checks.ps1'
$DbHelperPath = Join-Path $RepoRoot 'tools\lib\AutotuneDb.ps1'
$DbIngestScript = Join-Path $RepoRoot 'tools\db_ingest_autotune.ps1'

if (Test-Path -LiteralPath $DbHelperPath) {
    . $DbHelperPath
}

if ([string]::IsNullOrWhiteSpace($RunRoot)) {
    $RunRoot = Join-Path $RepoRoot 'autotune\runs'
}
if ([string]::IsNullOrWhiteSpace($ChampionDir)) {
    $ChampionDir = Join-Path $RepoRoot 'autotune\champions'
}

function Ensure-Directory {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        $null = New-Item -ItemType Directory -Path $Path -Force
    }
}

function Invoke-ReleaseSync {
    if ($DryRun) {
        return
    }
    $syncOutput = & powershell -ExecutionPolicy Bypass -File $ReleaseChecks -SkipSyntax
    $syncOutput | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) {
        throw 'release_checks.ps1 -SkipSyntax failed.'
    }
}

function Write-OvernightReport {
    param(
        [string]$Path,
        $Summary
    )

    $lines = @()
    $lines += '# Overnight Autotune Report'
    $lines += ''
    $lines += "- Session: $($Summary.Session)"
    $lines += "- Map: $($Summary.MapName)"
    $lines += "- Campaigns completed: $($Summary.CampaignsCompleted)"
    $lines += "- Promotions: $($Summary.Promotions)"
    $lines += "- Require mass-ratio gain: $($Summary.RequireMassRatioGain)"
    $lines += "- Minimum absolute mass ratio: $($Summary.MinMassRatioAbsolute)"
    $lines += "- Retest top: $($Summary.RetestTop)"
    $lines += "- Retest games: $($Summary.RetestGames)"
    $lines += "- Retest maps: $($Summary.RetestMaps -join ', ')"
    $lines += ''
    $lines += '## Campaigns'
    $lines += ''
    $lines += '| Session | Promoted | Best | Score | Avg Time | Mass Ratio | Failure | Baseline Mass Ratio | Blockers |'
    $lines += '| --- | --- | --- | ---: | ---: | ---: | --- | ---: | --- |'
    foreach ($row in $Summary.Results) {
        $blockers = if ($row.PromotionBlockedReasons) { ($row.PromotionBlockedReasons -join '; ') } else { '' }
        $lines += "| $($row.Session) | $($row.Promoted) | $($row.BestCandidate) | $($row.BestScore) | $($row.BestAvgGameTime) | $($row.BestAvgMassRatio) | $($row.BestPrimaryFailureClass) | $($row.BaselineAvgMassRatio) | $blockers |"
    }
    $lines += ''
    Set-Content -LiteralPath $Path -Value ($lines -join [Environment]::NewLine) -Encoding UTF8
}

Ensure-Directory $RunRoot
Ensure-Directory $ChampionDir
$overnightTag = Get-Date -Format 'yyyyMMdd-HHmmss'
$overnightDir = Join-Path $RunRoot ("overnight-{0}" -f $overnightTag)
Ensure-Directory $overnightDir
$buildMeta = if (Get-Command Get-OvermindBuildMetadata -ErrorAction SilentlyContinue) { Get-OvermindBuildMetadata -RepoRoot $RepoRoot } else { $null }
$originalConfigPath = Join-Path $overnightDir 'original-AutoTuneConfig.lua'
Copy-Item -LiteralPath $ConfigPath -Destination $originalConfigPath -Force

trap {
    if ($RestoreOriginalOnExit -and -not $DryRun -and (Test-Path -LiteralPath $originalConfigPath)) {
        try {
            Copy-Item -LiteralPath $originalConfigPath -Destination $ConfigPath -Force
            Invoke-ReleaseSync
            Write-Warning "Overnight autotune aborted; restored original config from $originalConfigPath"
        } catch {
            Write-Warning "Overnight autotune restore failed: $_"
        }
    }
    break
}

if ($Campaigns -lt 1) { throw 'Campaigns must be at least 1.' }
if ($BaseSeed -le 0) {
    $BaseSeed = Get-Random -Minimum 1 -Maximum 1600000000
}

Write-Host "Overnight autotune session: $overnightTag"
Write-Host "  campaigns=$Campaigns candidates=$Candidates games=$GamesPerCandidate parallel=$ParallelInstances speed=$TargetSpeed map=$MapName seed=$BaseSeed"
Write-Host "  runDir=$overnightDir"

$campaignSummaries = @()
for ($campaign = 1; $campaign -le $Campaigns; $campaign++) {
    $campaignRunRoot = Join-Path $overnightDir ("campaign-{0:000}" -f $campaign)
    Ensure-Directory $campaignRunRoot
    $campaignSeed = $BaseSeed + (($campaign - 1) * 10000000)

    $args = @(
        '-ExecutionPolicy', 'Bypass',
        '-File', $AutotuneScript,
        '-Candidates', $Candidates,
        '-GamesPerCandidate', $GamesPerCandidate,
        '-ParallelInstances', $ParallelInstances,
        '-TargetSpeed', $TargetSpeed,
        '-MapName', $MapName,
        '-BaseSeed', $campaignSeed,
        '-MaxGameSeconds', $MaxGameSeconds,
        '-MaxRealSeconds', $MaxRealSeconds,
        '-PromoteScoreMargin', $PromoteScoreMargin,
        '-MutationRate', $MutationRate,
        '-RequireMassRatioGain', $RequireMassRatioGain,
        '-MinMassRatioAbsolute', $MinMassRatioAbsolute,
        '-MaxMassRatioRegression', $MaxMassRatioRegression,
        '-MinAvgGameTime', $MinAvgGameTime,
        '-MaxSurvivalRegression', $MaxSurvivalRegression,
        '-RetestTop', $RetestTop,
        '-RetestGames', $RetestGames,
        '-RetestMaps', $RetestMaps,
        '-RunRoot', $campaignRunRoot,
        '-ChampionDir', $ChampionDir
    )
    if ($NoPromote) { $args += '-NoPromote' }
    if ($DisableAdaptiveMutation) { $args += '-DisableAdaptiveMutation' }
    if ($UseDatabase) { $args += '-UseDatabase' }
    if ($UseDatabase -and $campaign -eq 1 -and $DbInitSchema) { $args += '-DbInitSchema' }
    if (-not [string]::IsNullOrWhiteSpace($DbComposeFile)) { $args += @('-DbComposeFile', $DbComposeFile) }
    if (-not [string]::IsNullOrWhiteSpace($DbEnvFile)) { $args += @('-DbEnvFile', $DbEnvFile) }
    if (-not [string]::IsNullOrWhiteSpace($DbProjectName)) { $args += @('-DbProjectName', $DbProjectName) }
    if ($DryRun) { $args += '-DryRun' }

    Write-Host ("Starting campaign {0}/{1}, seed={2}" -f $campaign, $Campaigns, $campaignSeed)
    $output = & powershell @args
    $output | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) {
        throw "run_economy_autotune.ps1 failed in campaign $campaign."
    }

    $summaryPath = @(Get-ChildItem -LiteralPath $campaignRunRoot -Recurse -Filter 'session-summary.json' |
        Sort-Object -Property LastWriteTime -Descending |
        Select-Object -First 1).FullName
    if ($summaryPath) {
        $summary = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json
        $campaignSummaries += $summary
        Write-Host ("Campaign {0} result: promoted={1} best={2} score={3} massRatio={4} avgTime={5}" -f
            $campaign,
            $summary.Promoted,
            $summary.BestCandidate,
            $summary.BestScore,
            $summary.BestAvgMassRatio,
            $summary.BestAvgGameTime)
        if ($StopOnPromotion -and $summary.Promoted) {
            Write-Host 'StopOnPromotion set; stopping overnight run.'
            break
        }
    } else {
        Write-Warning "No session summary found for campaign $campaign."
    }
}

$overnightSummary = [pscustomobject]@{
    Session = $overnightTag
    RunDir = $overnightDir
    CreatedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    CampaignsRequested = $Campaigns
    CampaignsCompleted = $campaignSummaries.Count
    BaseSeed = $BaseSeed
    MapName = $MapName
    Candidates = $Candidates
    GamesPerCandidate = $GamesPerCandidate
    ParallelInstances = $ParallelInstances
    TargetSpeed = $TargetSpeed
    NoPromote = [bool]$NoPromote
    RequireMassRatioGain = $RequireMassRatioGain
    MinMassRatioAbsolute = $MinMassRatioAbsolute
    MinAvgGameTime = $MinAvgGameTime
    RetestTop = $RetestTop
    RetestGames = $RetestGames
    RetestMaps = if ([string]::IsNullOrWhiteSpace($RetestMaps)) { @($MapName) } else { @($RetestMaps -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
    Version = if ($buildMeta) { $buildMeta.Version } else { $null }
    Fingerprint = if ($buildMeta) { $buildMeta.Fingerprint } else { $null }
    GitCommit = if ($buildMeta) { $buildMeta.GitCommit } else { $null }
    Promotions = @($campaignSummaries | Where-Object { $_.Promoted }).Count
    Results = $campaignSummaries | Select-Object Session, Promoted, BestCandidate, BestScore, BestAvgGameTime, BestAvgMassRatio, BestPrimaryFailureClass, BaselineScore, BaselineAvgGameTime, BaselineAvgMassRatio, PromotionAllowed, PromotionBlockedReasons
}
$overnightSummaryPath = Join-Path $overnightDir 'overnight-summary.json'
$overnightSummary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $overnightSummaryPath -Encoding UTF8
Write-OvernightReport -Path (Join-Path $overnightDir 'overnight-report.md') -Summary $overnightSummary

if ($UseDatabase -and -not $DryRun -and (Test-Path -LiteralPath $DbIngestScript)) {
    try {
        $dbArgs = @(
            '-ExecutionPolicy', 'Bypass',
            '-File', $DbIngestScript,
            '-OvernightSummaryPath', $overnightSummaryPath,
            '-StartDb',
            '-ComposeFile', $DbComposeFile,
            '-EnvFile', $DbEnvFile,
            '-ProjectName', $DbProjectName
        )
        & powershell @dbArgs
        if ($LASTEXITCODE -ne 0) {
            Write-Warning 'Autotune DB ingestion failed for overnight summary.'
        }
    } catch {
        Write-Warning ("Autotune DB overnight ingestion failed: {0}" -f $_)
    }
}

Write-Host "Overnight summary: $overnightSummaryPath"
Write-Host "Overnight report: $(Join-Path $overnightDir 'overnight-report.md')"
