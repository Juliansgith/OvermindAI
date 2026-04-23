param(
    [string]$SessionSummaryPath = '',
    [string]$OvernightSummaryPath = '',
    [switch]$StartDb,
    [switch]$InitSchema,
    [string]$ComposeFile = '',
    [string]$EnvFile = '',
    [string]$ProjectName = 'overmind-autotune'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib\AutotuneDb.ps1')

function To-NullableInt {
    param($Value)
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return $null
    }
    return [int]$Value
}

function To-NullableLong {
    param($Value)
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return $null
    }
    return [long]$Value
}

function To-NullableDouble {
    param($Value)
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return $null
    }
    return [double]$Value
}

function To-NullableBool {
    param($Value)
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return $null
    }
    if ($Value -is [bool]) {
        return [bool]$Value
    }
    return [bool]::Parse([string]$Value)
}

function Read-JsonFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }
    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Import-CsvSafe {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        return @()
    }
    return @(Import-Csv -LiteralPath $Path)
}

function Get-ObjectPropertyValue {
    param(
        $Object,
        [string]$Name,
        $Default = $null
    )

    if ($null -eq $Object) {
        return $Default
    }

    $prop = $Object.PSObject.Properties[$Name]
    if ($prop) {
        return $prop.Value
    }

    return $Default
}

function Read-AutotuneConfigLua {
    param([string]$Path)

    $config = [ordered]@{}
    if (-not (Test-Path -LiteralPath $Path)) {
        return $config
    }

    foreach ($line in [System.IO.File]::ReadLines($Path)) {
        if ($line -match '^\s*([A-Za-z0-9_]+)\s*=\s*(.+?),?\s*$') {
            $key = $Matches[1]
            $raw = $Matches[2].Trim().TrimEnd(',')
            if ($raw -match "^'(.*)'$") {
                $config[$key] = $Matches[1]
            } elseif ($raw -match '^"(.+)"$') {
                $config[$key] = $Matches[1]
            } elseif ($raw -match '^-?[0-9]+$') {
                $config[$key] = [int]$raw
            } elseif ($raw -match '^-?[0-9]+\.[0-9]+$') {
                $config[$key] = [double]$raw
            }
        }
    }
    return $config
}

function Get-OpponentKey {
    param([string]$AiMatchup)
    if ([string]::IsNullOrWhiteSpace($AiMatchup)) {
        return $null
    }
    if ($AiMatchup -match 'vs\s+(.+)$') {
        return (($Matches[1].ToLowerInvariant()) -replace '[^a-z0-9]+', '_').Trim('_')
    }
    return (($AiMatchup.ToLowerInvariant()) -replace '[^a-z0-9]+', '_').Trim('_')
}

function Get-SessionRuntimeMetadata {
    param([string]$SessionDir)

    $summaryFiles = @(Get-ChildItem -LiteralPath $SessionDir -Recurse -Filter 'autorun_log_summary.csv' -ErrorAction SilentlyContinue |
        Sort-Object -Property FullName)
    if ($summaryFiles.Count -le 0) {
        return [pscustomobject]@{
            AiMatchup = $null
            OpponentKey = $null
        }
    }

    $rows = @(Import-Csv -LiteralPath $summaryFiles[0].FullName)
    $aiMatchup = if ($rows.Count -gt 0) { [string]$rows[0].ai_matchup } else { $null }
    return [pscustomobject]@{
        AiMatchup = $aiMatchup
        OpponentKey = Get-OpponentKey -AiMatchup $aiMatchup
    }
}

function Get-ConfigParameterRows {
    param($Config)

    $exclude = @(
        'Version', 'CandidateId', 'ParentCandidateId', 'GeneratedAt', 'GeneratedBy',
        'Score', 'Games', 'MapName', 'SourceLog'
    )

    $rows = @()
    if ($null -eq $Config) {
        return $rows
    }
    foreach ($prop in $Config.PSObject.Properties) {
        if ($exclude -contains $prop.Name) {
            continue
        }
        if ($prop.Value -is [byte] -or $prop.Value -is [int16] -or $prop.Value -is [int32] -or $prop.Value -is [int64] -or
            $prop.Value -is [single] -or $prop.Value -is [double] -or $prop.Value -is [decimal]) {
            $rows += [pscustomobject]@{
                ParamName = [string]$prop.Name
                ParamValue = [double]$prop.Value
            }
        }
    }
    return $rows
}

function Add-SqlLine {
    param(
        [System.Text.StringBuilder]$Builder,
        [string]$Line
    )
    [void]$Builder.AppendLine($Line)
}

function ConvertTo-AutotuneSqlJsonText {
    param([string]$JsonText)

    if ([string]::IsNullOrWhiteSpace($JsonText)) {
        return 'NULL'
    }

    try {
        $parsed = $JsonText | ConvertFrom-Json -ErrorAction Stop
        return ConvertTo-AutotuneSqlJson -Value $parsed
    } catch {
        return ("'{0}'::jsonb" -f ($JsonText.Replace("'", "''")))
    }
}

function Ensure-CandidateActionArtifacts {
    param([string]$CandidateDir)

    $actionsDir = Join-Path $CandidateDir 'analysis\actions'
    $eventsPath = Join-Path $actionsDir 'action_events.csv'
    $outcomesPath = Join-Path $actionsDir 'action_outcomes.csv'
    if ((Test-Path -LiteralPath $eventsPath) -and (Test-Path -LiteralPath $outcomesPath)) {
        return
    }

    $logsDir = Join-Path $CandidateDir 'logs'
    $extractorPath = Join-Path $PSScriptRoot 'extract_autotune_actions.ps1'
    if (-not (Test-Path -LiteralPath $logsDir) -or -not (Test-Path -LiteralPath $extractorPath)) {
        return
    }

    if (-not (Test-Path -LiteralPath $actionsDir)) {
        $null = New-Item -ItemType Directory -Path $actionsDir -Force
    }

    try {
        & powershell -ExecutionPolicy Bypass -File $extractorPath -LogsPath (Join-Path $logsDir '*.log') -OutputDir $actionsDir | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Warning ("Action extraction failed for '{0}' with exit code {1}" -f $CandidateDir, $LASTEXITCODE)
        }
    } catch {
        Write-Warning ("Action extraction failed for '{0}': {1}" -f $CandidateDir, $_.Exception.Message)
    }
}

function Get-CandidateArtifacts {
    param(
        [string]$SessionDir,
        [string]$CandidateId
    )

    $candidateDir = Join-Path $SessionDir $CandidateId
    $scorePath = Join-Path $candidateDir 'score.json'
    $score = Read-JsonFile -Path $scorePath
    $config = $null
    if ($score -and $score.Config) {
        $config = $score.Config
    } else {
        $config = Read-AutotuneConfigLua -Path (Join-Path $candidateDir 'AutoTuneConfig.lua')
    }
    Ensure-CandidateActionArtifacts -CandidateDir $candidateDir

    return [pscustomobject]@{
        CandidateDir = $candidateDir
        Score = $score
        Config = $config
        SummaryRows = Import-CsvSafe -Path (Join-Path $candidateDir 'analysis\summary\autorun_log_summary.csv')
        PlayerRows = Import-CsvSafe -Path (Join-Path $candidateDir 'analysis\summary\autorun_player_stats.csv')
        KpiRows = Import-CsvSafe -Path (Join-Path $candidateDir 'analysis\kpis\autorun_kpis.csv')
        ActionRows = Import-CsvSafe -Path (Join-Path $candidateDir 'analysis\actions\action_events.csv')
        ActionOutcomeRows = Import-CsvSafe -Path (Join-Path $candidateDir 'analysis\actions\action_outcomes.csv')
    }
}

function Write-EconomySessionSql {
    param(
        $Summary,
        [string]$SessionSummaryPath,
        [string]$RepoRoot
    )

    $sessionDir = Split-Path -Parent $SessionSummaryPath
    $runtimeMeta = Get-SessionRuntimeMetadata -SessionDir $sessionDir
    $buildMeta = Get-OvermindBuildMetadata -RepoRoot $RepoRoot
    $candidateRows = @((Get-ObjectPropertyValue -Object $Summary -Name 'Results' -Default @()))
    $bestCandidateId = [string](Get-ObjectPropertyValue -Object $Summary -Name 'BestCandidate' -Default $null)
    if ([string]::IsNullOrWhiteSpace($bestCandidateId)) {
        $bestCandidateId = $null
    }
    $summaryCandidates = To-NullableInt (Get-ObjectPropertyValue -Object $Summary -Name 'Candidates' -Default $candidateRows.Count)
    $summaryPromoted = To-NullableBool (Get-ObjectPropertyValue -Object $Summary -Name 'Promoted')
    $summaryNoPromote = To-NullableBool (Get-ObjectPropertyValue -Object $Summary -Name 'NoPromote')
    $summaryPromoteScoreMargin = To-NullableDouble (Get-ObjectPropertyValue -Object $Summary -Name 'PromoteScoreMargin')
    $summaryRequireMassRatioGain = To-NullableDouble (Get-ObjectPropertyValue -Object $Summary -Name 'RequireMassRatioGain')
    $summaryMinMassRatioAbsolute = To-NullableDouble (Get-ObjectPropertyValue -Object $Summary -Name 'MinMassRatioAbsolute')
    $summaryMinAvgGameTime = To-NullableInt (Get-ObjectPropertyValue -Object $Summary -Name 'MinAvgGameTime')
    $summaryMaxMassRatioRegression = To-NullableDouble (Get-ObjectPropertyValue -Object $Summary -Name 'MaxMassRatioRegression')
    $summaryMaxSurvivalRegression = To-NullableDouble (Get-ObjectPropertyValue -Object $Summary -Name 'MaxSurvivalRegression')
    $summaryRetestTop = To-NullableInt (Get-ObjectPropertyValue -Object $Summary -Name 'RetestTop')
    $summaryRetestGames = To-NullableInt (Get-ObjectPropertyValue -Object $Summary -Name 'RetestGames')
    $summaryRetestMaps = @(Get-ObjectPropertyValue -Object $Summary -Name 'RetestMaps' -Default @())
    $summaryAdaptiveMutationSources = To-NullableInt (Get-ObjectPropertyValue -Object $Summary -Name 'AdaptiveMutationSources')
    $summaryFailureAwareMutation = To-NullableBool (Get-ObjectPropertyValue -Object $Summary -Name 'FailureAwareMutation')
    $summaryBaselineScore = To-NullableDouble (Get-ObjectPropertyValue -Object $Summary -Name 'BaselineScore')
    $summaryBaselineAvgGameTime = To-NullableDouble (Get-ObjectPropertyValue -Object $Summary -Name 'BaselineAvgGameTime')
    $summaryBaselineAvgMassRatio = To-NullableDouble (Get-ObjectPropertyValue -Object $Summary -Name 'BaselineAvgMassRatio')
    $summaryBaselinePrimaryFailureClass = Get-ObjectPropertyValue -Object $Summary -Name 'BaselinePrimaryFailureClass'
    $summaryBestScore = To-NullableDouble (Get-ObjectPropertyValue -Object $Summary -Name 'BestScore')
    $summaryBestAvgGameTime = To-NullableDouble (Get-ObjectPropertyValue -Object $Summary -Name 'BestAvgGameTime')
    $summaryBestAvgMassRatio = To-NullableDouble (Get-ObjectPropertyValue -Object $Summary -Name 'BestAvgMassRatio')
    $summaryBestPrimaryFailureClass = Get-ObjectPropertyValue -Object $Summary -Name 'BestPrimaryFailureClass'
    $summaryMargin = To-NullableDouble (Get-ObjectPropertyValue -Object $Summary -Name 'Margin')
    $summaryPromotionAllowed = To-NullableBool (Get-ObjectPropertyValue -Object $Summary -Name 'PromotionAllowed')
    $summaryPromotionBlockedReasons = @(Get-ObjectPropertyValue -Object $Summary -Name 'PromotionBlockedReasons' -Default @())

    $sql = [System.Text.StringBuilder]::new()
    Add-SqlLine -Builder $sql -Line 'begin;'
    Add-SqlLine -Builder $sql -Line ("delete from autotune.champions where session_id = {0};" -f (ConvertTo-AutotuneSqlLiteral $Summary.Session))
    Add-SqlLine -Builder $sql -Line ("delete from autotune.action_outcomes where session_id = {0};" -f (ConvertTo-AutotuneSqlLiteral $Summary.Session))
    Add-SqlLine -Builder $sql -Line ("delete from autotune.action_events where session_id = {0};" -f (ConvertTo-AutotuneSqlLiteral $Summary.Session))
    Add-SqlLine -Builder $sql -Line ("delete from autotune.game_kpis where session_id = {0};" -f (ConvertTo-AutotuneSqlLiteral $Summary.Session))
    Add-SqlLine -Builder $sql -Line ("delete from autotune.game_player_stats where session_id = {0};" -f (ConvertTo-AutotuneSqlLiteral $Summary.Session))
    Add-SqlLine -Builder $sql -Line ("delete from autotune.game_results where session_id = {0};" -f (ConvertTo-AutotuneSqlLiteral $Summary.Session))
    Add-SqlLine -Builder $sql -Line ("delete from autotune.candidate_parameters where session_id = {0};" -f (ConvertTo-AutotuneSqlLiteral $Summary.Session))
    Add-SqlLine -Builder $sql -Line ("delete from autotune.candidate_results where session_id = {0};" -f (ConvertTo-AutotuneSqlLiteral $Summary.Session))
    Add-SqlLine -Builder $sql -Line ("delete from autotune.session_runs where session_id = {0};" -f (ConvertTo-AutotuneSqlLiteral $Summary.Session))

    Add-SqlLine -Builder $sql -Line @"
insert into autotune.session_runs (
    session_id, overnight_session_id, session_kind, run_dir, map_name, base_seed, candidates,
    games_per_candidate, parallel_instances, target_speed, promoted, no_promote, promote_score_margin,
    require_mass_ratio_gain, min_mass_ratio_absolute, min_avg_game_time, max_mass_ratio_regression,
    max_survival_regression, retest_top, retest_games, retest_maps, adaptive_mutation_sources,
    failure_aware_mutation, baseline_score, baseline_avg_game_time, baseline_avg_mass_ratio,
    baseline_primary_failure_class, best_candidate, best_score, best_avg_game_time, best_avg_mass_ratio,
    best_primary_failure_class, margin, promotion_allowed, promotion_blocked_reasons, version,
    fingerprint, git_commit, ai_matchup, opponent_key, raw_summary
) values (
    $(ConvertTo-AutotuneSqlLiteral $Summary.Session),
    NULL,
    'economy',
    $(ConvertTo-AutotuneSqlLiteral $Summary.RunDir),
    $(ConvertTo-AutotuneSqlLiteral $Summary.MapName),
    $(ConvertTo-AutotuneSqlLiteral (To-NullableLong $Summary.BaseSeed)),
    $(ConvertTo-AutotuneSqlLiteral $summaryCandidates),
    $(ConvertTo-AutotuneSqlLiteral (To-NullableInt $Summary.GamesPerCandidate)),
    $(ConvertTo-AutotuneSqlLiteral (To-NullableInt $Summary.ParallelInstances)),
    $(ConvertTo-AutotuneSqlLiteral (To-NullableInt $Summary.TargetSpeed)),
    $(ConvertTo-AutotuneSqlLiteral $summaryPromoted),
    $(ConvertTo-AutotuneSqlLiteral $summaryNoPromote),
    $(ConvertTo-AutotuneSqlLiteral $summaryPromoteScoreMargin),
    $(ConvertTo-AutotuneSqlLiteral $summaryRequireMassRatioGain),
    $(ConvertTo-AutotuneSqlLiteral $summaryMinMassRatioAbsolute),
    $(ConvertTo-AutotuneSqlLiteral $summaryMinAvgGameTime),
    $(ConvertTo-AutotuneSqlLiteral $summaryMaxMassRatioRegression),
    $(ConvertTo-AutotuneSqlLiteral $summaryMaxSurvivalRegression),
    $(ConvertTo-AutotuneSqlLiteral $summaryRetestTop),
    $(ConvertTo-AutotuneSqlLiteral $summaryRetestGames),
    $(ConvertTo-AutotuneSqlTextArray $summaryRetestMaps),
    $(ConvertTo-AutotuneSqlLiteral $summaryAdaptiveMutationSources),
    $(ConvertTo-AutotuneSqlLiteral $summaryFailureAwareMutation),
    $(ConvertTo-AutotuneSqlLiteral $summaryBaselineScore),
    $(ConvertTo-AutotuneSqlLiteral $summaryBaselineAvgGameTime),
    $(ConvertTo-AutotuneSqlLiteral $summaryBaselineAvgMassRatio),
    $(ConvertTo-AutotuneSqlLiteral $summaryBaselinePrimaryFailureClass),
    $(ConvertTo-AutotuneSqlLiteral $Summary.BestCandidate),
    $(ConvertTo-AutotuneSqlLiteral $summaryBestScore),
    $(ConvertTo-AutotuneSqlLiteral $summaryBestAvgGameTime),
    $(ConvertTo-AutotuneSqlLiteral $summaryBestAvgMassRatio),
    $(ConvertTo-AutotuneSqlLiteral $summaryBestPrimaryFailureClass),
    $(ConvertTo-AutotuneSqlLiteral $summaryMargin),
    $(ConvertTo-AutotuneSqlLiteral $summaryPromotionAllowed),
    $(ConvertTo-AutotuneSqlTextArray $summaryPromotionBlockedReasons),
    $(ConvertTo-AutotuneSqlLiteral $buildMeta.Version),
    $(ConvertTo-AutotuneSqlLiteral $buildMeta.Fingerprint),
    $(ConvertTo-AutotuneSqlLiteral $buildMeta.GitCommit),
    $(ConvertTo-AutotuneSqlLiteral $runtimeMeta.AiMatchup),
    $(ConvertTo-AutotuneSqlLiteral $runtimeMeta.OpponentKey),
    $(ConvertTo-AutotuneSqlJson $Summary)
);
"@

    foreach ($candidateRow in $candidateRows) {
        $candidateId = [string]$candidateRow.CandidateId
        $artifacts = Get-CandidateArtifacts -SessionDir $sessionDir -CandidateId $candidateId
        $config = $artifacts.Config
        $scoreData = $artifacts.Score
        $parentId = if ($config -and $config.PSObject.Properties['ParentCandidateId']) { $config.ParentCandidateId } else { $null }
        $configVersion = if ($config -and $config.PSObject.Properties['Version']) { To-NullableInt $config.Version } else { $null }
        $isPromoted = ($summaryPromoted -eq $true -and $bestCandidateId -eq $candidateId)
        $candidateGames = To-NullableInt (Get-ObjectPropertyValue -Object $candidateRow -Name 'Games')
        $candidateScore = To-NullableDouble (Get-ObjectPropertyValue -Object $candidateRow -Name 'Score')
        $candidateWinRate = To-NullableDouble (Get-ObjectPropertyValue -Object $candidateRow -Name 'WinRate')
        $candidateAvgGameTime = To-NullableDouble (Get-ObjectPropertyValue -Object $candidateRow -Name 'AvgGameTime')
        $candidateAvgMassRatio = To-NullableDouble (Get-ObjectPropertyValue -Object $candidateRow -Name 'AvgMassRatio')
        $candidatePrimaryFailureClass = Get-ObjectPropertyValue -Object $candidateRow -Name 'PrimaryFailureClass'
        $candidateRuntimeClean = To-NullableBool (Get-ObjectPropertyValue -Object $candidateRow -Name 'RuntimeClean')

        Add-SqlLine -Builder $sql -Line @"
insert into autotune.candidate_results (
    session_id, candidate_id, parent_candidate_id, map_name, games, score, win_rate,
    avg_game_time, avg_mass_ratio, primary_failure_class, runtime_clean, config_version,
    promoted, config_json, raw_score
) values (
    $(ConvertTo-AutotuneSqlLiteral $Summary.Session),
    $(ConvertTo-AutotuneSqlLiteral $candidateId),
    $(ConvertTo-AutotuneSqlLiteral $parentId),
    $(ConvertTo-AutotuneSqlLiteral $Summary.MapName),
    $(ConvertTo-AutotuneSqlLiteral $candidateGames),
    $(ConvertTo-AutotuneSqlLiteral $candidateScore),
    $(ConvertTo-AutotuneSqlLiteral $candidateWinRate),
    $(ConvertTo-AutotuneSqlLiteral $candidateAvgGameTime),
    $(ConvertTo-AutotuneSqlLiteral $candidateAvgMassRatio),
    $(ConvertTo-AutotuneSqlLiteral $candidatePrimaryFailureClass),
    $(ConvertTo-AutotuneSqlLiteral $candidateRuntimeClean),
    $(ConvertTo-AutotuneSqlLiteral $configVersion),
    $(ConvertTo-AutotuneSqlLiteral $isPromoted),
    $(ConvertTo-AutotuneSqlJson $config),
    $(ConvertTo-AutotuneSqlJson $scoreData)
);
"@

        foreach ($param in @(Get-ConfigParameterRows -Config $config)) {
            Add-SqlLine -Builder $sql -Line @"
insert into autotune.candidate_parameters (session_id, candidate_id, param_name, param_value) values (
    $(ConvertTo-AutotuneSqlLiteral $Summary.Session),
    $(ConvertTo-AutotuneSqlLiteral $candidateId),
    $(ConvertTo-AutotuneSqlLiteral $param.ParamName),
    $(ConvertTo-AutotuneSqlLiteral $param.ParamValue)
);
"@
        }

        $summaryByLog = @{}
        foreach ($row in $artifacts.SummaryRows) {
            $summaryByLog[[string]$row.log_name] = $row
        }
        $kpiByLog = @{}
        foreach ($row in $artifacts.KpiRows) {
            $kpiByLog[[string]$row.log_name] = $row
        }
        $playerByLog = @{}
        foreach ($row in $artifacts.PlayerRows) {
            $logName = [string]$row.log_name
            if (-not $playerByLog.ContainsKey($logName)) {
                $playerByLog[$logName] = @()
            }
            $playerByLog[$logName] += $row
        }
        $actionByLog = @{}
        foreach ($row in $artifacts.ActionRows) {
            $logName = [string]$row.log_name
            if (-not $actionByLog.ContainsKey($logName)) {
                $actionByLog[$logName] = @()
            }
            $actionByLog[$logName] += $row
        }
        $actionOutcomeByLog = @{}
        foreach ($row in $artifacts.ActionOutcomeRows) {
            $logName = [string]$row.log_name
            if (-not $actionOutcomeByLog.ContainsKey($logName)) {
                $actionOutcomeByLog[$logName] = @()
            }
            $actionOutcomeByLog[$logName] += $row
        }

        $runs = @()
        if ($scoreData -and $scoreData.Runs) {
            $runs = @($scoreData.Runs)
        } else {
            foreach ($row in $artifacts.SummaryRows) {
                $runs += [pscustomobject]@{ LogName = $row.log_name }
            }
        }

        foreach ($run in $runs) {
            $logName = [string]$run.LogName
            $summaryRow = if ($summaryByLog.ContainsKey($logName)) { $summaryByLog[$logName] } else { $null }
            $kpiRow = if ($kpiByLog.ContainsKey($logName)) { $kpiByLog[$logName] } else { $null }
            $playerRows = if ($playerByLog.ContainsKey($logName)) { @($playerByLog[$logName]) } else { @() }
            $actionRows = if ($actionByLog.ContainsKey($logName)) { @($actionByLog[$logName]) } else { @() }
            $actionOutcomeRows = if ($actionOutcomeByLog.ContainsKey($logName)) { @($actionOutcomeByLog[$logName]) } else { @() }
            $matchup = if ($summaryRow) { [string]$summaryRow.ai_matchup } else { $runtimeMeta.AiMatchup }
            $summaryRunTag = if ($summaryRow) { $summaryRow.run_tag } else { $null }
            $summaryInstance = if ($summaryRow) { To-NullableInt $summaryRow.instance } else { $null }
            $summaryLogPath = if ($summaryRow) { $summaryRow.log_path } else { $null }
            $summaryWinnerName = if ($summaryRow) { $summaryRow.winner_name } else { $null }
            $summaryWinnerType = if ($summaryRow) { $summaryRow.winner_type } else { $null }
            $summaryWinnerScore = if ($summaryRow) { To-NullableDouble $summaryRow.winner_score } else { $null }
            $summaryWarnings = if ($summaryRow) { To-NullableInt $summaryRow.warnings } else { $null }
            $summaryErrors = if ($summaryRow) { To-NullableInt $summaryRow.errors } else { $null }
            $summaryTopWarning = if ($summaryRow) { $summaryRow.top_warning } else { $null }
            $summaryEventTypes = if ($summaryRow) { To-NullableInt $summaryRow.overmind_event_types } else { $null }
            $summaryEventTotal = if ($summaryRow) { To-NullableInt $summaryRow.overmind_event_total } else { $null }
            $summaryTopEvent = if ($summaryRow) { $summaryRow.top_overmind_event } else { $null }
            $summaryGameTime = if ($summaryRow) { $summaryRow.game_time } else { $null }
            $summaryGameTimeSeconds = if ($summaryRow) { To-NullableDouble $summaryRow.game_time_seconds } else { To-NullableDouble $run.GameTime }
            $summarySessionTimeSeconds = if ($summaryRow) { To-NullableDouble $summaryRow.session_time_seconds } else { $null }
            $summaryRunTimeSeconds = if ($summaryRow) { To-NullableDouble $summaryRow.run_time_seconds } else { $null }
            $summaryStartupOk = if ($summaryRow) { To-NullableBool $summaryRow.startup_ok } else { $null }
            $summaryConfigLoaded = if ($summaryRow) { To-NullableBool $summaryRow.config_loaded } else { $null }
            $summaryConfigPath = if ($summaryRow) { $summaryRow.config_path } else { $null }
            $summarySimSpeed = if ($summaryRow) { To-NullableInt $summaryRow.sim_speed } else { $null }
            $summaryObserverOnly = if ($summaryRow) { To-NullableBool $summaryRow.observer_only } else { $null }
            $kpiRunTag = if ($kpiRow) { $kpiRow.run_tag } else { $null }
            $kpiInstance = if ($kpiRow) { To-NullableInt $kpiRow.instance } else { $null }
            $kpiGameTimeSeconds = if ($kpiRow) { To-NullableDouble $kpiRow.game_time_seconds } else { To-NullableDouble $run.GameTime }
            $kpiMassRatio = if ($kpiRow) {
                if ($kpiRow.PSObject.Properties['overmind_mass_in_ratio_vs_m27']) { To-NullableDouble $kpiRow.overmind_mass_in_ratio_vs_m27 }
                else { To-NullableDouble $kpiRow.overmind_mass_in_ratio }
            } else {
                To-NullableDouble $run.MassRatio
            }

            Add-SqlLine -Builder $sql -Line @"
insert into autotune.game_results (
    session_id, candidate_id, log_name, run_tag, instance, log_path, ai_matchup, winner_name,
    winner_type, winner_score, warnings, errors, top_warning, overmind_event_types, overmind_event_total,
    top_overmind_event, game_time, game_time_seconds, session_time_seconds, run_time_seconds, startup_ok,
    config_loaded, config_path, sim_speed, observer_only, raw_summary
) values (
    $(ConvertTo-AutotuneSqlLiteral $Summary.Session),
    $(ConvertTo-AutotuneSqlLiteral $candidateId),
    $(ConvertTo-AutotuneSqlLiteral $logName),
    $(ConvertTo-AutotuneSqlLiteral $summaryRunTag),
    $(ConvertTo-AutotuneSqlLiteral $summaryInstance),
    $(ConvertTo-AutotuneSqlLiteral $summaryLogPath),
    $(ConvertTo-AutotuneSqlLiteral $matchup),
    $(ConvertTo-AutotuneSqlLiteral $summaryWinnerName),
    $(ConvertTo-AutotuneSqlLiteral $summaryWinnerType),
    $(ConvertTo-AutotuneSqlLiteral $summaryWinnerScore),
    $(ConvertTo-AutotuneSqlLiteral $summaryWarnings),
    $(ConvertTo-AutotuneSqlLiteral $summaryErrors),
    $(ConvertTo-AutotuneSqlLiteral $summaryTopWarning),
    $(ConvertTo-AutotuneSqlLiteral $summaryEventTypes),
    $(ConvertTo-AutotuneSqlLiteral $summaryEventTotal),
    $(ConvertTo-AutotuneSqlLiteral $summaryTopEvent),
    $(ConvertTo-AutotuneSqlLiteral $summaryGameTime),
    $(ConvertTo-AutotuneSqlLiteral $summaryGameTimeSeconds),
    $(ConvertTo-AutotuneSqlLiteral $summarySessionTimeSeconds),
    $(ConvertTo-AutotuneSqlLiteral $summaryRunTimeSeconds),
    $(ConvertTo-AutotuneSqlLiteral $summaryStartupOk),
    $(ConvertTo-AutotuneSqlLiteral $summaryConfigLoaded),
    $(ConvertTo-AutotuneSqlLiteral $summaryConfigPath),
    $(ConvertTo-AutotuneSqlLiteral $summarySimSpeed),
    $(ConvertTo-AutotuneSqlLiteral $summaryObserverOnly),
    $(ConvertTo-AutotuneSqlJson $summaryRow)
);
"@

            foreach ($player in $playerRows) {
                $isOvermind = ([string]$player.player_name -match 'Overmind')
                $isOpponent = (-not $isOvermind) -and ([string]$player.player_name -match 'M27|M28')
                Add-SqlLine -Builder $sql -Line @"
insert into autotune.game_player_stats (
    session_id, candidate_id, log_name, player_name, player_type, faction, score, current_units,
    kills_mass, loss_mass, mass_in, mass_out, mass_over, energy_in, energy_out, energy_over,
    is_overmind, is_opponent, raw_player
) values (
    $(ConvertTo-AutotuneSqlLiteral $Summary.Session),
    $(ConvertTo-AutotuneSqlLiteral $candidateId),
    $(ConvertTo-AutotuneSqlLiteral $logName),
    $(ConvertTo-AutotuneSqlLiteral $player.player_name),
    $(ConvertTo-AutotuneSqlLiteral $player.player_type),
    $(ConvertTo-AutotuneSqlLiteral (To-NullableInt $player.faction)),
    $(ConvertTo-AutotuneSqlLiteral (To-NullableDouble $player.score)),
    $(ConvertTo-AutotuneSqlLiteral (To-NullableInt $player.current_units)),
    $(ConvertTo-AutotuneSqlLiteral (To-NullableDouble $player.kills_mass)),
    $(ConvertTo-AutotuneSqlLiteral (To-NullableDouble $player.loss_mass)),
    $(ConvertTo-AutotuneSqlLiteral (To-NullableDouble $player.mass_in)),
    $(ConvertTo-AutotuneSqlLiteral (To-NullableDouble $player.mass_out)),
    $(ConvertTo-AutotuneSqlLiteral (To-NullableDouble $player.mass_over)),
    $(ConvertTo-AutotuneSqlLiteral (To-NullableDouble $player.energy_in)),
    $(ConvertTo-AutotuneSqlLiteral (To-NullableDouble $player.energy_out)),
    $(ConvertTo-AutotuneSqlLiteral (To-NullableDouble $player.energy_over)),
    $(ConvertTo-AutotuneSqlLiteral $isOvermind),
    $(ConvertTo-AutotuneSqlLiteral $isOpponent),
    $(ConvertTo-AutotuneSqlJson $player)
);
"@
            }

            $opponentMassIn = $null
            if ($playerRows.Count -gt 0) {
                $opp = @($playerRows | Where-Object { $_.player_name -match 'M27|M28' } | Select-Object -First 1)
                if ($opp.Count -gt 0) {
                    $opponentMassIn = To-NullableDouble $opp[0].mass_in
                }
            }

            $kpiFirstMex1Time = if ($kpiRow) { To-NullableDouble $kpiRow.first_mex_1_time } else { $null }
            $kpiFirstMex5Time = if ($kpiRow) { To-NullableDouble $kpiRow.first_mex_5_time } else { $null }
            $kpiFirstMex8Time = if ($kpiRow) { To-NullableDouble $kpiRow.first_mex_8_time } else { $null }
            $kpiFirstFactory2Time = if ($kpiRow) { To-NullableDouble $kpiRow.first_factory_2_time } else { $null }
            $kpiFirstExpandDispatchTime = if ($kpiRow) { To-NullableDouble $kpiRow.first_expand_dispatch_time } else { $null }
            $kpiMaxFactoryTotal = if ($kpiRow) { To-NullableInt $kpiRow.max_factory_total } else { To-NullableInt $run.MaxFac }
            $kpiMaxMexReady = if ($kpiRow) { To-NullableInt $kpiRow.max_mex_ready } else { To-NullableInt $run.MaxMex }
            $kpiExpansionOrdersTotal = if ($kpiRow) { To-NullableDouble $kpiRow.expansion_orders_total } else { $null }
            $kpiReclaimFieldOrdersTotal = if ($kpiRow) { To-NullableDouble $kpiRow.reclaim_field_orders_total } else { $null }
            $kpiStagnationSecondsEst = if ($kpiRow) { To-NullableDouble $kpiRow.stagnation_seconds_est } else { $null }
            $kpiOvermindMassIn = if ($kpiRow) { To-NullableDouble $kpiRow.overmind_mass_in } else { $null }
            $kpiOvermindMassOut = if ($kpiRow) { To-NullableDouble $kpiRow.overmind_mass_out } else { $null }
            $kpiMexAt120 = if ($kpiRow) { To-NullableDouble $kpiRow.mex_at_120 } else { $null }
            $kpiFacTotalAt120 = if ($kpiRow) { To-NullableDouble $kpiRow.fac_total_at_120 } else { $null }
            $kpiMexAt240 = if ($kpiRow) { To-NullableDouble $kpiRow.mex_at_240 } else { $null }
            $kpiFacTotalAt240 = if ($kpiRow) { To-NullableDouble $kpiRow.fac_total_at_240 } else { $null }
            $kpiMexAt360 = if ($kpiRow) { To-NullableDouble $kpiRow.mex_at_360 } else { $null }
            $kpiFacTotalAt360 = if ($kpiRow) { To-NullableDouble $kpiRow.fac_total_at_360 } else { $null }
            $kpiMexAt600 = if ($kpiRow) { To-NullableDouble $kpiRow.mex_at_600 } else { $null }
            $kpiFacTotalAt600 = if ($kpiRow) { To-NullableDouble $kpiRow.fac_total_at_600 } else { $null }
            $kpiMexAt900 = if ($kpiRow) { To-NullableDouble $kpiRow.mex_at_900 } else { $null }
            $kpiFacTotalAt900 = if ($kpiRow) { To-NullableDouble $kpiRow.fac_total_at_900 } else { $null }

            Add-SqlLine -Builder $sql -Line @"
insert into autotune.game_kpis (
    session_id, candidate_id, log_name, run_tag, instance, game_time_seconds, first_mex_1_time,
    first_mex_5_time, first_mex_8_time, first_factory_2_time, first_expand_dispatch_time,
    max_factory_total, max_mex_ready, expansion_orders_total, reclaim_field_orders_total,
    stagnation_seconds_est, overmind_mass_in, overmind_mass_out, opponent_mass_in, overmind_mass_in_ratio,
    mex_at_120, fac_total_at_120, mex_at_240, fac_total_at_240, mex_at_360, fac_total_at_360,
    mex_at_600, fac_total_at_600, mex_at_900, fac_total_at_900, raw_kpi
) values (
    $(ConvertTo-AutotuneSqlLiteral $Summary.Session),
    $(ConvertTo-AutotuneSqlLiteral $candidateId),
    $(ConvertTo-AutotuneSqlLiteral $logName),
    $(ConvertTo-AutotuneSqlLiteral $kpiRunTag),
    $(ConvertTo-AutotuneSqlLiteral $kpiInstance),
    $(ConvertTo-AutotuneSqlLiteral $kpiGameTimeSeconds),
    $(ConvertTo-AutotuneSqlLiteral $kpiFirstMex1Time),
    $(ConvertTo-AutotuneSqlLiteral $kpiFirstMex5Time),
    $(ConvertTo-AutotuneSqlLiteral $kpiFirstMex8Time),
    $(ConvertTo-AutotuneSqlLiteral $kpiFirstFactory2Time),
    $(ConvertTo-AutotuneSqlLiteral $kpiFirstExpandDispatchTime),
    $(ConvertTo-AutotuneSqlLiteral $kpiMaxFactoryTotal),
    $(ConvertTo-AutotuneSqlLiteral $kpiMaxMexReady),
    $(ConvertTo-AutotuneSqlLiteral $kpiExpansionOrdersTotal),
    $(ConvertTo-AutotuneSqlLiteral $kpiReclaimFieldOrdersTotal),
    $(ConvertTo-AutotuneSqlLiteral $kpiStagnationSecondsEst),
    $(ConvertTo-AutotuneSqlLiteral $kpiOvermindMassIn),
    $(ConvertTo-AutotuneSqlLiteral $kpiOvermindMassOut),
    $(ConvertTo-AutotuneSqlLiteral $opponentMassIn),
    $(ConvertTo-AutotuneSqlLiteral $kpiMassRatio),
    $(ConvertTo-AutotuneSqlLiteral $kpiMexAt120),
    $(ConvertTo-AutotuneSqlLiteral $kpiFacTotalAt120),
    $(ConvertTo-AutotuneSqlLiteral $kpiMexAt240),
    $(ConvertTo-AutotuneSqlLiteral $kpiFacTotalAt240),
    $(ConvertTo-AutotuneSqlLiteral $kpiMexAt360),
    $(ConvertTo-AutotuneSqlLiteral $kpiFacTotalAt360),
    $(ConvertTo-AutotuneSqlLiteral $kpiMexAt600),
    $(ConvertTo-AutotuneSqlLiteral $kpiFacTotalAt600),
    $(ConvertTo-AutotuneSqlLiteral $kpiMexAt900),
    $(ConvertTo-AutotuneSqlLiteral $kpiFacTotalAt900),
    $(ConvertTo-AutotuneSqlJson $kpiRow)
);
"@

            foreach ($action in $actionRows) {
                Add-SqlLine -Builder $sql -Line @"
insert into autotune.action_events (
    session_id, candidate_id, log_name, event_index, run_tag, instance, subsystem, action_type,
    action_key, action_value, event_time, mex_ready, fac_total, reclaim_mass, map_control,
    idle_factories, engineer_count, force_guard, force_main, force_outer, force_raid,
    strategy_dir, production_mode, state_json, raw_event
) values (
    $(ConvertTo-AutotuneSqlLiteral $Summary.Session),
    $(ConvertTo-AutotuneSqlLiteral $candidateId),
    $(ConvertTo-AutotuneSqlLiteral $logName),
    $(ConvertTo-AutotuneSqlLiteral (To-NullableInt $action.event_index)),
    $(ConvertTo-AutotuneSqlLiteral $action.run_tag),
    $(ConvertTo-AutotuneSqlLiteral (To-NullableInt $action.instance)),
    $(ConvertTo-AutotuneSqlLiteral $action.subsystem),
    $(ConvertTo-AutotuneSqlLiteral $action.action_type),
    $(ConvertTo-AutotuneSqlLiteral $action.action_key),
    $(ConvertTo-AutotuneSqlLiteral $action.action_value),
    $(ConvertTo-AutotuneSqlLiteral (To-NullableDouble $action.event_time)),
    $(ConvertTo-AutotuneSqlLiteral (To-NullableInt $action.mex_ready)),
    $(ConvertTo-AutotuneSqlLiteral (To-NullableInt $action.fac_total)),
    $(ConvertTo-AutotuneSqlLiteral (To-NullableDouble $action.reclaim_mass)),
    $(ConvertTo-AutotuneSqlLiteral (To-NullableDouble $action.map_control)),
    $(ConvertTo-AutotuneSqlLiteral (To-NullableInt $action.idle_factories)),
    $(ConvertTo-AutotuneSqlLiteral (To-NullableInt $action.engineer_count)),
    $(ConvertTo-AutotuneSqlLiteral (To-NullableInt $action.force_guard)),
    $(ConvertTo-AutotuneSqlLiteral (To-NullableInt $action.force_main)),
    $(ConvertTo-AutotuneSqlLiteral (To-NullableInt $action.force_outer)),
    $(ConvertTo-AutotuneSqlLiteral (To-NullableInt $action.force_raid)),
    $(ConvertTo-AutotuneSqlLiteral $action.strategy_dir),
    $(ConvertTo-AutotuneSqlLiteral $action.production_mode),
    $(ConvertTo-AutotuneSqlJsonText $action.state_json),
    $(ConvertTo-AutotuneSqlJsonText $action.raw_event)
);
"@
            }

            foreach ($outcome in $actionOutcomeRows) {
                Add-SqlLine -Builder $sql -Line @"
insert into autotune.action_outcomes (
    session_id, candidate_id, log_name, event_index, window_seconds, subsystem, action_type,
    action_value, event_time, reward, delta_mex_ready, delta_factory_total, delta_reclaim_mass,
    delta_map_control, delta_idle_factories, delta_engineer_count, delta_force_guard,
    delta_force_main, delta_force_outer, delta_force_raid, survived_window,
    game_ended_within_window, final_mass_ratio, outcome_json
) values (
    $(ConvertTo-AutotuneSqlLiteral $Summary.Session),
    $(ConvertTo-AutotuneSqlLiteral $candidateId),
    $(ConvertTo-AutotuneSqlLiteral $logName),
    $(ConvertTo-AutotuneSqlLiteral (To-NullableInt $outcome.event_index)),
    $(ConvertTo-AutotuneSqlLiteral (To-NullableInt $outcome.window_seconds)),
    $(ConvertTo-AutotuneSqlLiteral $outcome.subsystem),
    $(ConvertTo-AutotuneSqlLiteral $outcome.action_type),
    $(ConvertTo-AutotuneSqlLiteral $outcome.action_value),
    $(ConvertTo-AutotuneSqlLiteral (To-NullableDouble $outcome.event_time)),
    $(ConvertTo-AutotuneSqlLiteral (To-NullableDouble $outcome.reward)),
    $(ConvertTo-AutotuneSqlLiteral (To-NullableDouble $outcome.delta_mex_ready)),
    $(ConvertTo-AutotuneSqlLiteral (To-NullableDouble $outcome.delta_factory_total)),
    $(ConvertTo-AutotuneSqlLiteral (To-NullableDouble $outcome.delta_reclaim_mass)),
    $(ConvertTo-AutotuneSqlLiteral (To-NullableDouble $outcome.delta_map_control)),
    $(ConvertTo-AutotuneSqlLiteral (To-NullableDouble $outcome.delta_idle_factories)),
    $(ConvertTo-AutotuneSqlLiteral (To-NullableDouble $outcome.delta_engineer_count)),
    $(ConvertTo-AutotuneSqlLiteral (To-NullableDouble $outcome.delta_force_guard)),
    $(ConvertTo-AutotuneSqlLiteral (To-NullableDouble $outcome.delta_force_main)),
    $(ConvertTo-AutotuneSqlLiteral (To-NullableDouble $outcome.delta_force_outer)),
    $(ConvertTo-AutotuneSqlLiteral (To-NullableDouble $outcome.delta_force_raid)),
    $(ConvertTo-AutotuneSqlLiteral (To-NullableBool $outcome.survived_window)),
    $(ConvertTo-AutotuneSqlLiteral (To-NullableBool $outcome.game_ended_within_window)),
    $(ConvertTo-AutotuneSqlLiteral (To-NullableDouble $outcome.final_mass_ratio)),
    $(ConvertTo-AutotuneSqlJsonText $outcome.outcome_json)
);
"@
            }
        }
    }

    if ($summaryPromoted -eq $true -and -not [string]::IsNullOrWhiteSpace($bestCandidateId) -and $bestCandidateId -ne 'baseline') {
        $bestArtifacts = Get-CandidateArtifacts -SessionDir $sessionDir -CandidateId $bestCandidateId
        Add-SqlLine -Builder $sql -Line @"
insert into autotune.champions (
    session_id, candidate_id, map_name, opponent_key, ai_matchup, score, avg_game_time,
    avg_mass_ratio, version, fingerprint, git_commit, config_json
) values (
    $(ConvertTo-AutotuneSqlLiteral $Summary.Session),
    $(ConvertTo-AutotuneSqlLiteral $bestCandidateId),
    $(ConvertTo-AutotuneSqlLiteral $Summary.MapName),
    $(ConvertTo-AutotuneSqlLiteral $runtimeMeta.OpponentKey),
    $(ConvertTo-AutotuneSqlLiteral $runtimeMeta.AiMatchup),
    $(ConvertTo-AutotuneSqlLiteral $summaryBestScore),
    $(ConvertTo-AutotuneSqlLiteral $summaryBestAvgGameTime),
    $(ConvertTo-AutotuneSqlLiteral $summaryBestAvgMassRatio),
    $(ConvertTo-AutotuneSqlLiteral $buildMeta.Version),
    $(ConvertTo-AutotuneSqlLiteral $buildMeta.Fingerprint),
    $(ConvertTo-AutotuneSqlLiteral $buildMeta.GitCommit),
    $(ConvertTo-AutotuneSqlJson $bestArtifacts.Config)
);
"@
    }

    Add-SqlLine -Builder $sql -Line 'commit;'
    return $sql.ToString()
}

function Write-OvernightSql {
    param(
        $Summary
    )

    $summaryResults = @((Get-ObjectPropertyValue -Object $Summary -Name 'Results' -Default @()))
    $summaryCandidates = To-NullableInt (Get-ObjectPropertyValue -Object $Summary -Name 'Candidates')
    $summaryNoPromote = To-NullableBool (Get-ObjectPropertyValue -Object $Summary -Name 'NoPromote')
    $summaryRequireMassRatioGain = To-NullableDouble (Get-ObjectPropertyValue -Object $Summary -Name 'RequireMassRatioGain')
    $summaryMinMassRatioAbsolute = To-NullableDouble (Get-ObjectPropertyValue -Object $Summary -Name 'MinMassRatioAbsolute')
    $summaryMinAvgGameTime = To-NullableInt (Get-ObjectPropertyValue -Object $Summary -Name 'MinAvgGameTime')
    $summaryRetestTop = To-NullableInt (Get-ObjectPropertyValue -Object $Summary -Name 'RetestTop')
    $summaryRetestGames = To-NullableInt (Get-ObjectPropertyValue -Object $Summary -Name 'RetestGames')
    $summaryRetestMaps = @(Get-ObjectPropertyValue -Object $Summary -Name 'RetestMaps' -Default @())
    $summaryPromotions = To-NullableInt (Get-ObjectPropertyValue -Object $Summary -Name 'Promotions')

    $sql = [System.Text.StringBuilder]::new()
    Add-SqlLine -Builder $sql -Line 'begin;'
    Add-SqlLine -Builder $sql -Line ("delete from autotune.overnight_campaign_results where overnight_session_id = {0};" -f (ConvertTo-AutotuneSqlLiteral $Summary.Session))
    Add-SqlLine -Builder $sql -Line ("delete from autotune.overnight_runs where overnight_session_id = {0};" -f (ConvertTo-AutotuneSqlLiteral $Summary.Session))

    Add-SqlLine -Builder $sql -Line @"
insert into autotune.overnight_runs (
    overnight_session_id, run_dir, campaigns_requested, campaigns_completed, base_seed,
    map_name, candidates, games_per_candidate, parallel_instances, target_speed, no_promote,
    require_mass_ratio_gain, min_mass_ratio_absolute, min_avg_game_time, retest_top, retest_games,
    retest_maps, promotions, raw_summary
) values (
    $(ConvertTo-AutotuneSqlLiteral $Summary.Session),
    $(ConvertTo-AutotuneSqlLiteral $Summary.RunDir),
    $(ConvertTo-AutotuneSqlLiteral (To-NullableInt $Summary.CampaignsRequested)),
    $(ConvertTo-AutotuneSqlLiteral (To-NullableInt $Summary.CampaignsCompleted)),
    $(ConvertTo-AutotuneSqlLiteral (To-NullableLong $Summary.BaseSeed)),
    $(ConvertTo-AutotuneSqlLiteral $Summary.MapName),
    $(ConvertTo-AutotuneSqlLiteral $summaryCandidates),
    $(ConvertTo-AutotuneSqlLiteral (To-NullableInt $Summary.GamesPerCandidate)),
    $(ConvertTo-AutotuneSqlLiteral (To-NullableInt $Summary.ParallelInstances)),
    $(ConvertTo-AutotuneSqlLiteral (To-NullableInt $Summary.TargetSpeed)),
    $(ConvertTo-AutotuneSqlLiteral $summaryNoPromote),
    $(ConvertTo-AutotuneSqlLiteral $summaryRequireMassRatioGain),
    $(ConvertTo-AutotuneSqlLiteral $summaryMinMassRatioAbsolute),
    $(ConvertTo-AutotuneSqlLiteral $summaryMinAvgGameTime),
    $(ConvertTo-AutotuneSqlLiteral $summaryRetestTop),
    $(ConvertTo-AutotuneSqlLiteral $summaryRetestGames),
    $(ConvertTo-AutotuneSqlTextArray $summaryRetestMaps),
    $(ConvertTo-AutotuneSqlLiteral $summaryPromotions),
    $(ConvertTo-AutotuneSqlJson $Summary)
);
"@

    foreach ($row in $summaryResults) {
        $rowPromoted = To-NullableBool (Get-ObjectPropertyValue -Object $row -Name 'Promoted')
        $rowBestCandidate = Get-ObjectPropertyValue -Object $row -Name 'BestCandidate'
        $rowBestScore = To-NullableDouble (Get-ObjectPropertyValue -Object $row -Name 'BestScore')
        $rowBestAvgGameTime = To-NullableDouble (Get-ObjectPropertyValue -Object $row -Name 'BestAvgGameTime')
        $rowBestAvgMassRatio = To-NullableDouble (Get-ObjectPropertyValue -Object $row -Name 'BestAvgMassRatio')
        $rowBestPrimaryFailureClass = Get-ObjectPropertyValue -Object $row -Name 'BestPrimaryFailureClass'
        $rowBaselineScore = To-NullableDouble (Get-ObjectPropertyValue -Object $row -Name 'BaselineScore')
        $rowBaselineAvgGameTime = To-NullableDouble (Get-ObjectPropertyValue -Object $row -Name 'BaselineAvgGameTime')
        $rowBaselineAvgMassRatio = To-NullableDouble (Get-ObjectPropertyValue -Object $row -Name 'BaselineAvgMassRatio')
        $rowPromotionAllowed = To-NullableBool (Get-ObjectPropertyValue -Object $row -Name 'PromotionAllowed')
        $rowPromotionBlockedReasons = @(Get-ObjectPropertyValue -Object $row -Name 'PromotionBlockedReasons' -Default @())
        Add-SqlLine -Builder $sql -Line @"
insert into autotune.overnight_campaign_results (
    overnight_session_id, campaign_session_id, promoted, best_candidate, best_score, best_avg_game_time,
    best_avg_mass_ratio, best_primary_failure_class, baseline_score, baseline_avg_game_time,
    baseline_avg_mass_ratio, promotion_allowed, promotion_blocked_reasons
) values (
    $(ConvertTo-AutotuneSqlLiteral $Summary.Session),
    $(ConvertTo-AutotuneSqlLiteral $row.Session),
    $(ConvertTo-AutotuneSqlLiteral $rowPromoted),
    $(ConvertTo-AutotuneSqlLiteral $rowBestCandidate),
    $(ConvertTo-AutotuneSqlLiteral $rowBestScore),
    $(ConvertTo-AutotuneSqlLiteral $rowBestAvgGameTime),
    $(ConvertTo-AutotuneSqlLiteral $rowBestAvgMassRatio),
    $(ConvertTo-AutotuneSqlLiteral $rowBestPrimaryFailureClass),
    $(ConvertTo-AutotuneSqlLiteral $rowBaselineScore),
    $(ConvertTo-AutotuneSqlLiteral $rowBaselineAvgGameTime),
    $(ConvertTo-AutotuneSqlLiteral $rowBaselineAvgMassRatio),
    $(ConvertTo-AutotuneSqlLiteral $rowPromotionAllowed),
    $(ConvertTo-AutotuneSqlTextArray $rowPromotionBlockedReasons)
);
update autotune.session_runs
set overnight_session_id = $(ConvertTo-AutotuneSqlLiteral $Summary.Session)
where session_id = $(ConvertTo-AutotuneSqlLiteral $row.Session);
"@
        }

    Add-SqlLine -Builder $sql -Line 'commit;'
    return $sql.ToString()
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$settings = Get-AutotuneDbSettings -RepoRoot $repoRoot -ComposeFile $ComposeFile -EnvFile $EnvFile -ProjectName $ProjectName

if ($StartDb -or $InitSchema) {
    Start-AutotuneDb -Settings $settings -IncludeAdminer
}
if ($InitSchema) {
    Invoke-AutotunePsqlFile -Settings $settings -Path (Join-Path $repoRoot 'sql\autotune-db\001_schema.sql')
    Invoke-AutotunePsqlFile -Settings $settings -Path (Join-Path $repoRoot 'sql\autotune-db\002_views.sql')
}

if ([string]::IsNullOrWhiteSpace($SessionSummaryPath) -and [string]::IsNullOrWhiteSpace($OvernightSummaryPath)) {
    throw 'Provide SessionSummaryPath and/or OvernightSummaryPath.'
}

if (-not [string]::IsNullOrWhiteSpace($SessionSummaryPath)) {
    $summary = Read-JsonFile -Path $SessionSummaryPath
    if ($null -eq $summary) {
        throw "Could not read session summary '$SessionSummaryPath'."
    }
    $tempPath = Join-Path ([System.IO.Path]::GetTempPath()) ("autotune-session-{0}.sql" -f $summary.Session)
    Set-Content -LiteralPath $tempPath -Value (Write-EconomySessionSql -Summary $summary -SessionSummaryPath $SessionSummaryPath -RepoRoot $repoRoot) -Encoding UTF8
    Invoke-AutotunePsqlFile -Settings $settings -Path $tempPath
    Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
    Write-Host "Ingested economy session $($summary.Session)"
}

if (-not [string]::IsNullOrWhiteSpace($OvernightSummaryPath)) {
    $summary = Read-JsonFile -Path $OvernightSummaryPath
    if ($null -eq $summary) {
        throw "Could not read overnight summary '$OvernightSummaryPath'."
    }
    $tempPath = Join-Path ([System.IO.Path]::GetTempPath()) ("autotune-overnight-{0}.sql" -f $summary.Session)
    Set-Content -LiteralPath $tempPath -Value (Write-OvernightSql -Summary $summary) -Encoding UTF8
    Invoke-AutotunePsqlFile -Settings $settings -Path $tempPath
    Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
    Write-Host "Ingested overnight session $($summary.Session)"
}
