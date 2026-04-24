param(
    [int]$Candidates = 6,
    [int]$GamesPerCandidate = 20,
    [int]$ParallelInstances = 20,
    [int]$TargetSpeed = 20,
    [string]$MapName = 'SCMP_036',
    [int]$BaseSeed = 0,
    [int]$MaxGameSeconds = 2400,
    [int]$MaxRealSeconds = 1200,
    [double]$PromoteScoreMargin = 0.03,
    [double]$MutationRate = 0.55,
    [double]$RequireMassRatioGain = 0,
    [double]$MinMassRatioAbsolute = 0,
    [double]$MaxMassRatioRegression = 0,
    [int]$MinAvgGameTime = 0,
    [double]$MaxSurvivalRegression = 0.25,
    [int]$RetestTop = 0,
    [int]$RetestGames = 0,
    [string]$RetestMaps = '',
    [string]$RunRoot = '',
    [string]$ChampionDir = '',
    [switch]$SkipBaseline,
    [switch]$NoPromote,
    [switch]$RestoreOriginalOnExit,
    [switch]$DisableAdaptiveMutation,
    [switch]$UseDatabase,
    [switch]$DbInitSchema,
    [string]$DbComposeFile = '',
    [string]$DbEnvFile = '',
    [string]$DbProjectName = 'overmind-autotune',
    [int]$DbHistoryPool = 24,
    [int]$DbDirectionPool = 16,
    [int]$DbActionMinSamples = 20,
    [switch]$DisableActionHints,
    [switch]$DryRun,
    [switch]$KeepLosingCandidateConfig
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Script:RestoreConfigPath = ''

trap {
    if (-not $DryRun -and -not [string]::IsNullOrWhiteSpace($Script:RestoreConfigPath) -and (Test-Path -LiteralPath $Script:RestoreConfigPath)) {
        try {
            Copy-Item -LiteralPath $Script:RestoreConfigPath -Destination $ConfigPath -Force
            Invoke-ReleaseSync
            Write-Warning "Autotune aborted; restored baseline config from $Script:RestoreConfigPath"
        } catch {
            Write-Warning "Autotune aborted and baseline restore failed: $_"
        }
    }
    break
}

$RepoRoot = Split-Path -Parent $PSScriptRoot
$ConfigPath = Join-Path $RepoRoot 'lua\AI\Overmind\AutoTuneConfig.lua'
$ReleaseChecks = Join-Path $RepoRoot 'tools\release_checks.ps1'
$DbHelperPath = Join-Path $RepoRoot 'tools\lib\AutotuneDb.ps1'
$DbIngestScript = Join-Path $RepoRoot 'tools\db_ingest_autotune.ps1'
$AutorunRoot = 'C:\Program Files (x86)\Steam\steamapps\common\Supreme Commander Forged Alliance\autorun'
$StartScript = Join-Path $AutorunRoot 'bin\start_autorun_parallel.ps1'
$AnalyzeScript = Join-Path $AutorunRoot 'bin\analyze_autorun_logs.ps1'
$KpiScript = Join-Path $AutorunRoot 'bin\extract_autorun_kpis.ps1'

if (Test-Path -LiteralPath $DbHelperPath) {
    . $DbHelperPath
}

if ([string]::IsNullOrWhiteSpace($RunRoot)) {
    $RunRoot = Join-Path $RepoRoot 'autotune\runs'
}

if ($Candidates -lt 1) { throw 'Candidates must be at least 1.' }
if ($GamesPerCandidate -lt 1) { throw 'GamesPerCandidate must be at least 1.' }
if ($ParallelInstances -lt 1) { throw 'ParallelInstances must be at least 1.' }
if ($TargetSpeed -lt 1) { throw 'TargetSpeed must be at least 1.' }
if ($MutationRate -lt 0 -or $MutationRate -gt 1) { throw 'MutationRate must be between 0 and 1.' }
if ($RequireMassRatioGain -lt 0) { throw 'RequireMassRatioGain must be zero or higher.' }
if ($MinMassRatioAbsolute -lt 0) { throw 'MinMassRatioAbsolute must be zero or higher.' }
if ($MaxMassRatioRegression -lt 0) { throw 'MaxMassRatioRegression must be zero or higher.' }
if ($MinAvgGameTime -lt 0) { throw 'MinAvgGameTime must be zero or higher.' }
if ($MaxSurvivalRegression -lt 0 -or $MaxSurvivalRegression -gt 1) { throw 'MaxSurvivalRegression must be between 0 and 1.' }
if ($RetestTop -lt 0) { throw 'RetestTop must be zero or higher.' }
if ($RetestGames -lt 0) { throw 'RetestGames must be zero or higher.' }
if ($DbHistoryPool -lt 0) { throw 'DbHistoryPool must be zero or higher.' }
if ($DbDirectionPool -lt 0) { throw 'DbDirectionPool must be zero or higher.' }
if ($DbActionMinSamples -lt 1) { throw 'DbActionMinSamples must be at least 1.' }

if ([string]::IsNullOrWhiteSpace($ChampionDir)) {
    $ChampionDir = Join-Path $RepoRoot 'autotune\champions'
}

function Ensure-Directory {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        $null = New-Item -ItemType Directory -Path $Path -Force
    }
}

function To-Double {
    param($Value)
    $parsed = 0.0
    [void][double]::TryParse([string]$Value, [ref]$parsed)
    return $parsed
}

function To-Int {
    param($Value)
    $parsed = 0
    [void][int]::TryParse([string]$Value, [ref]$parsed)
    return $parsed
}

function Clamp-Number {
    param([double]$Value, [double]$Min, [double]$Max)
    if ($Value -lt $Min) { return $Min }
    if ($Value -gt $Max) { return $Max }
    return $Value
}

function Get-ObjectPropertyValue {
    param(
        $Object,
        [string]$Name,
        $Default = 0
    )
    if ($null -eq $Object -or [string]::IsNullOrWhiteSpace($Name)) {
        return $Default
    }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) {
            return $Object[$Name]
        }
        return $Default
    }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) {
        return $Default
    }
    return $prop.Value
}

function New-EmptyHintSet {
    param([string]$Source = 'none')

    return [pscustomobject]@{
        Directions = @{}
        SourceCount = 0
        Source = $Source
    }
}

function New-TuneSpecs {
    return [ordered]@{
        FactoryFloorEarly = @{ Min = 2; Max = 7; Step = 1; Kind = 'int'; Sigma = 1 }
        FactoryFloorMid = @{ Min = 3; Max = 10; Step = 1; Kind = 'int'; Sigma = 1 }
        FactoryFloorLate = @{ Min = 4; Max = 14; Step = 1; Kind = 'int'; Sigma = 1 }
        FactoryRecoveryStagnation = @{ Min = 45; Max = 220; Step = 5; Kind = 'int'; Sigma = 15 }
        ScoutMinCount = @{ Min = 1; Max = 7; Step = 1; Kind = 'int'; Sigma = 1 }
        ACUOpeningMaxDistance = @{ Min = 16; Max = 70; Step = 2; Kind = 'int'; Sigma = 4 }
        ACUMidMaxDistance = @{ Min = 24; Max = 100; Step = 2; Kind = 'int'; Sigma = 6 }
        ACULateMaxDistance = @{ Min = 35; Max = 130; Step = 3; Kind = 'int'; Sigma = 9 }
        SafeExpandHotspotCapBias = @{ Min = -4; Max = 4; Step = 0.25; Kind = 'double'; Sigma = 0.75 }
        BaseEngineerFloorMin = @{ Min = 2; Max = 7; Step = 1; Kind = 'int'; Sigma = 1 }
        BaseEngineerFloorBias = @{ Min = -1; Max = 3; Step = 1; Kind = 'int'; Sigma = 1 }
        EngineerFactoryRatioBias = @{ Min = -0.25; Max = 0.35; Step = 0.025; Kind = 'double'; Sigma = 0.08 }
        FactoryMassIncomeBias = @{ Min = -2.5; Max = 2.5; Step = 0.1; Kind = 'double'; Sigma = 0.55 }
        FactoryEnergyIncomeBias = @{ Min = -45; Max = 45; Step = 2.5; Kind = 'double'; Sigma = 10 }
        FactoryMassRatioBias = @{ Min = -0.14; Max = 0.14; Step = 0.01; Kind = 'double'; Sigma = 0.035 }
        FactoryEnergyRatioBias = @{ Min = -0.16; Max = 0.16; Step = 0.01; Kind = 'double'; Sigma = 0.04 }
        FactoryMassPerFactoryBias = @{ Min = -0.35; Max = 0.35; Step = 0.025; Kind = 'double'; Sigma = 0.08 }
        FactoryToMexCapBias = @{ Min = -0.24; Max = 0.24; Step = 0.02; Kind = 'double'; Sigma = 0.055 }
        FactoryTempoBias = @{ Min = -0.35; Max = 0.45; Step = 0.025; Kind = 'double'; Sigma = 0.09 }
        SafeExpandDistanceBias = @{ Min = -180; Max = 240; Step = 10; Kind = 'int'; Sigma = 55 }
        SafeExpandThreatCapBias = @{ Min = -0.45; Max = 0.65; Step = 0.025; Kind = 'double'; Sigma = 0.11 }
        SafeExpandEnemyBufferBias = @{ Min = -45; Max = 55; Step = 5; Kind = 'int'; Sigma = 15 }
        ReclaimQuotaTimeBias = @{ Min = -120; Max = 180; Step = 10; Kind = 'int'; Sigma = 35 }
        ReclaimScoreBias = @{ Min = -90; Max = 110; Step = 5; Kind = 'int'; Sigma = 25 }
        ReclaimQuotaBias = @{ Min = -1; Max = 2; Step = 1; Kind = 'int'; Sigma = 1 }
        ExpansionQuotaBias = @{ Min = -1; Max = 2; Step = 1; Kind = 'int'; Sigma = 1 }
        UpgradeTimeBias = @{ Min = -120; Max = 210; Step = 10; Kind = 'int'; Sigma = 45 }
        AirFactoryTimeBias = @{ Min = -180; Max = 240; Step = 10; Kind = 'int'; Sigma = 50 }
        RadarTimeBias = @{ Min = -180; Max = 240; Step = 10; Kind = 'int'; Sigma = 45 }
        PowerNeedRatioBias = @{ Min = -0.14; Max = 0.16; Step = 0.01; Kind = 'double'; Sigma = 0.035 }
        StrategyExpandBias = @{ Min = -1.4; Max = 1.8; Step = 0.05; Kind = 'double'; Sigma = 0.35 }
        StrategyStabilizeBias = @{ Min = -1.8; Max = 1.2; Step = 0.05; Kind = 'double'; Sigma = 0.35 }
        StrategyTempoBias = @{ Min = -1.4; Max = 1.8; Step = 0.05; Kind = 'double'; Sigma = 0.35 }
        StrategyTechBias = @{ Min = -1.5; Max = 1.5; Step = 0.05; Kind = 'double'; Sigma = 0.35 }
        StrategyAirBias = @{ Min = -1.6; Max = 1.4; Step = 0.05; Kind = 'double'; Sigma = 0.35 }
        StrategyForwardTheaterBias = @{ Min = -1.2; Max = 1.5; Step = 0.05; Kind = 'double'; Sigma = 0.3 }
        StrategyOuterRetentionBias = @{ Min = -1.4; Max = 1.8; Step = 0.05; Kind = 'double'; Sigma = 0.35 }
        StrategyCollapseResistanceBias = @{ Min = -1.6; Max = 1.4; Step = 0.05; Kind = 'double'; Sigma = 0.32 }
        StrategyReclaimFieldBias = @{ Min = -1.2; Max = 1.6; Step = 0.05; Kind = 'double'; Sigma = 0.3 }
        ForceOuterContestBias = @{ Min = -1.2; Max = 1.8; Step = 0.05; Kind = 'double'; Sigma = 0.35 }
        ForceHomeGuardBias = @{ Min = -1.4; Max = 1.4; Step = 0.05; Kind = 'double'; Sigma = 0.32 }
        ForceRaidBias = @{ Min = -1.4; Max = 1.6; Step = 0.05; Kind = 'double'; Sigma = 0.35 }
        ReclaimRiskBias = @{ Min = -0.45; Max = 0.75; Step = 0.025; Kind = 'double'; Sigma = 0.12 }
        ReclaimSupportBias = @{ Min = -1; Max = 1; Step = 0.25; Kind = 'double'; Sigma = 0.35 }
        ReclaimNearbyBias = @{ Min = -0.35; Max = 0.65; Step = 0.025; Kind = 'double'; Sigma = 0.12 }
        ReclaimFieldRadiusBias = @{ Min = -18; Max = 24; Step = 2; Kind = 'int'; Sigma = 6 }
        ReclaimFieldMassBias = @{ Min = -28; Max = 36; Step = 2; Kind = 'int'; Sigma = 8 }
        ReclaimRouteRiskBias = @{ Min = -1.0; Max = 1.4; Step = 0.05; Kind = 'double'; Sigma = 0.24 }
        ReclaimEnemyMexBias = @{ Min = -1.0; Max = 1.8; Step = 0.05; Kind = 'double'; Sigma = 0.3 }
        MexUpgradeBudgetBias = @{ Min = -2.5; Max = 3; Step = 0.1; Kind = 'double'; Sigma = 0.65 }
        MexUpgradeRiskBias = @{ Min = -0.45; Max = 0.7; Step = 0.025; Kind = 'double'; Sigma = 0.12 }
        MexUpgradeCapBias = @{ Min = -1; Max = 2; Step = 1; Kind = 'int'; Sigma = 1 }
        FactoryHQTimingBias = @{ Min = -120; Max = 180; Step = 10; Kind = 'int'; Sigma = 40 }
        FactoryHQEcoBias = @{ Min = -1; Max = 1; Step = 0.05; Kind = 'double'; Sigma = 0.28 }
        EarlyAirUnlockBias = @{ Min = -1.4; Max = 1.4; Step = 0.05; Kind = 'double'; Sigma = 0.32 }
    }
}

function Get-DefaultTuneConfig {
    $cfg = [ordered]@{
        Version = 5
        CandidateId = 'baseline'
        ParentCandidateId = 'manual'
        ParentSource = 'manual'
        ParentSessionId = ''
        ParentFailureClass = ''
        GeneratedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        GeneratedBy = 'run_economy_autotune.ps1'
        Score = 0
        Games = 0
        MapName = $MapName
    }
    foreach ($name in (New-TuneSpecs).Keys) {
        $spec = (New-TuneSpecs)[$name]
        if ($name -eq 'FactoryFloorEarly') { $cfg[$name] = 2 }
        elseif ($name -eq 'FactoryFloorMid') { $cfg[$name] = 3 }
        elseif ($name -eq 'FactoryFloorLate') { $cfg[$name] = 5 }
        elseif ($name -eq 'FactoryRecoveryStagnation') { $cfg[$name] = 85 }
        elseif ($name -eq 'ScoutMinCount') { $cfg[$name] = 5 }
        elseif ($name -eq 'ACUOpeningMaxDistance') { $cfg[$name] = 16 }
        elseif ($name -eq 'ACUMidMaxDistance') { $cfg[$name] = 24 }
        elseif ($name -eq 'ACULateMaxDistance') { $cfg[$name] = 38 }
        elseif ($name -eq 'BaseEngineerFloorMin') { $cfg[$name] = 3 }
        else { $cfg[$name] = 0 }
    }
    return $cfg
}

function Read-TuneConfig {
    param([string]$Path)
    $cfg = Get-DefaultTuneConfig
    if (-not (Test-Path -LiteralPath $Path)) {
        return $cfg
    }

    foreach ($line in [System.IO.File]::ReadLines($Path)) {
        if ($line -match '^\s*([A-Za-z0-9_]+)\s*=\s*(.+?),?\s*$') {
            $key = $Matches[1]
            $raw = $Matches[2].Trim().TrimEnd(',')
            if ($raw -match "^'(.*)'$") {
                $cfg[$key] = $Matches[1]
            } elseif ($raw -match '^"(.+)"$') {
                $cfg[$key] = $Matches[1]
            } elseif ($raw -match '^-?[0-9]+$') {
                $cfg[$key] = [int]$raw
            } elseif ($raw -match '^-?[0-9]+\.[0-9]+$') {
                $cfg[$key] = [double]$raw
            }
        }
    }
    return $cfg
}

function Format-LuaValue {
    param($Value)
    if ($Value -is [string]) {
        return "'" + ($Value.Replace('\', '/').Replace("'", "\\'")) + "'"
    }
    if ($Value -is [double] -or $Value -is [float] -or $Value -is [decimal]) {
        return ([math]::Round([double]$Value, 4)).ToString([Globalization.CultureInfo]::InvariantCulture)
    }
    return ([string]$Value)
}

function Write-TuneConfig {
    param(
        [hashtable]$Config,
        [string]$Path
    )

    $orderedKeys = @(
        'Version',
        'CandidateId',
        'ParentCandidateId',
        'ParentSource',
        'ParentSessionId',
        'ParentFailureClass',
        'GeneratedAt',
        'GeneratedBy',
        'Score',
        'Games',
        'MapName'
    ) + @((New-TuneSpecs).Keys)

    $lines = @()
    $lines += 'Config = {'
    foreach ($key in $orderedKeys) {
        if ($Config.Contains($key)) {
            $lines += "    $key = $(Format-LuaValue -Value $Config[$key]),"
        }
    }
    $lines += '}'
    Set-Content -LiteralPath $Path -Value ($lines -join [Environment]::NewLine) -Encoding ASCII
}

function Copy-TuneConfig {
    param([hashtable]$Config)
    $clone = [ordered]@{}
    foreach ($key in $Config.Keys) {
        $clone[$key] = $Config[$key]
    }
    return $clone
}

function ConvertTo-TuneConfigHashtable {
    param($InputObject)

    $cfg = Get-DefaultTuneConfig
    if ($null -eq $InputObject) {
        return $cfg
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        foreach ($key in $InputObject.Keys) {
            $cfg[[string]$key] = $InputObject[$key]
        }
        return $cfg
    }

    foreach ($prop in $InputObject.PSObject.Properties) {
        $cfg[[string]$prop.Name] = $prop.Value
    }
    return $cfg
}

function Get-SafeName {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) {
        return 'unknown'
    }
    return ($Value -replace '[^A-Za-z0-9_.-]', '-')
}

function Get-RetestMapList {
    if ([string]::IsNullOrWhiteSpace($RetestMaps)) {
        return @($MapName)
    }

    $maps = @()
    foreach ($entry in ($RetestMaps -split ',')) {
        $trimmed = $entry.Trim()
        if (-not [string]::IsNullOrWhiteSpace($trimmed)) {
            $maps += $trimmed
        }
    }
    if ($maps.Count -eq 0) {
        return @($MapName)
    }
    return $maps
}

function Merge-HintSets {
    param(
        [object[]]$HintSets,
        [string]$Source = 'merged'
    )

    $merged = @{}
    $sourceCount = 0
    foreach ($hint in @($HintSets)) {
        if ($null -eq $hint) {
            continue
        }
        $sourceCount += To-Int (Get-ObjectPropertyValue -Object $hint -Name 'SourceCount')
        $directions = Get-ObjectPropertyValue -Object $hint -Name 'Directions'
        if ($directions -isnot [System.Collections.IDictionary]) {
            continue
        }
        foreach ($name in $directions.Keys) {
            if (-not $merged.ContainsKey($name)) {
                $merged[$name] = 0
            }
            $merged[$name] += To-Int $directions[$name]
        }
    }

    $final = @{}
    foreach ($name in $merged.Keys) {
        if ($merged[$name] -gt 0) {
            $final[$name] = 1
        } elseif ($merged[$name] -lt 0) {
            $final[$name] = -1
        }
    }

    return [pscustomobject]@{
        Directions = $final
        SourceCount = $sourceCount
        Source = $Source
    }
}

function Get-AdaptiveHints {
    param([string]$Path)

    $empty = [pscustomobject]@{
        Directions = @{}
        SourceCount = 0
    }
    if ($DisableAdaptiveMutation -or [string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        return $empty
    }

    $scoreFiles = @(Get-ChildItem -LiteralPath $Path -Recurse -Filter 'score.json' -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty FullName)
    if ($scoreFiles.Count -lt 8) {
        return $empty
    }

    $rows = @()
    foreach ($file in $scoreFiles) {
        try {
            $data = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
            if ($data.CandidateId -and $data.CandidateId -notmatch '^baseline|^retest-baseline' -and $data.RuntimeClean -and $data.Config) {
                $rows += $data
            }
        } catch {
        }
    }
    if ($rows.Count -lt 8) {
        return $empty
    }

    $sorted = @($rows | Sort-Object -Property Score -Descending)
    $take = [math]::Min(12, [math]::Max(3, [int][math]::Floor($sorted.Count * 0.25)))
    $top = @($sorted | Select-Object -First $take)
    $bottom = @($sorted | Select-Object -Last $take)
    $directions = @{}
    foreach ($name in (New-TuneSpecs).Keys) {
        $topAvg = (@($top | ForEach-Object { To-Double (Get-ObjectPropertyValue -Object $_.Config -Name $name) }) | Measure-Object -Average).Average
        $bottomAvg = (@($bottom | ForEach-Object { To-Double (Get-ObjectPropertyValue -Object $_.Config -Name $name) }) | Measure-Object -Average).Average
        $step = To-Double ((New-TuneSpecs)[$name].Step)
        if ($null -ne $topAvg -and $null -ne $bottomAvg -and [math]::Abs($topAvg - $bottomAvg) -ge ($step * 0.9)) {
            $directions[$name] = if ($topAvg -gt $bottomAvg) { 1 } else { -1 }
        }
    }

    return [pscustomobject]@{
        Directions = $directions
        SourceCount = $rows.Count
        Source = 'local-history'
    }
}

function Invoke-DbJsonQuery {
    param(
        $Settings,
        [string]$Query
    )

    if ($null -eq $Settings -or -not (Get-Command Invoke-AutotuneSqlQuery -ErrorAction SilentlyContinue)) {
        return @()
    }

    try {
        $lines = @(Invoke-AutotuneSqlQuery -Settings $Settings -Query $Query -Quiet)
    } catch {
        Write-Warning ("DB query failed: {0}" -f $_)
        return @()
    }

    $rows = @()
    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line) -or $line -eq 'row_json') {
            continue
        }
        try {
            $rows += ($line | ConvertFrom-Json)
        } catch {
        }
    }
    return $rows
}

function Get-DbHistoricalCandidates {
    param(
        $Settings,
        [string]$MapValue,
        [int]$PoolSize
    )

    if ($PoolSize -le 0 -or [string]::IsNullOrWhiteSpace($MapValue)) {
        return @()
    }

    $specialistPool = [math]::Max(4, [int][math]::Ceiling($PoolSize / 3))
    $query = @"
with ranked as (
    select
        cr.session_id,
        cr.candidate_id,
        cr.score,
        cr.avg_mass_ratio,
        cr.avg_game_time,
        cr.primary_failure_class,
        cr.promoted,
        sr.map_name,
        sr.opponent_key,
        cr.config_json,
        row_number() over (order by case when sr.map_name = $(ConvertTo-AutotuneSqlLiteral $MapValue) then 0 else 1 end, cr.score desc nulls last) as score_rank,
        row_number() over (order by case when sr.map_name = $(ConvertTo-AutotuneSqlLiteral $MapValue) then 0 else 1 end, cr.avg_mass_ratio desc nulls last, cr.score desc nulls last) as mass_rank,
        row_number() over (order by case when sr.map_name = $(ConvertTo-AutotuneSqlLiteral $MapValue) then 0 else 1 end, cr.avg_game_time desc nulls last, cr.score desc nulls last) as survival_rank
    from autotune.candidate_results cr
    join autotune.session_runs sr on sr.session_id = cr.session_id
    where cr.runtime_clean = true
      and cr.config_json is not null
      and cr.candidate_id not in ('baseline', 'retest-baseline')
)
select json_build_object(
    'SessionId', session_id,
    'CandidateId', candidate_id,
    'Score', score,
    'AvgMassRatio', avg_mass_ratio,
    'AvgGameTime', avg_game_time,
    'PrimaryFailureClass', primary_failure_class,
    'Promoted', promoted,
    'MapName', map_name,
    'OpponentKey', opponent_key,
    'ArchiveRole',
        case
            when promoted then 'champion'
            when mass_rank <= $specialistPool then 'mass'
            when survival_rank <= $specialistPool then 'survival'
            else 'score'
        end,
    'Config', config_json
)::text as row_json
from ranked
where promoted = true
   or score_rank <= $PoolSize
   or mass_rank <= $specialistPool
   or survival_rank <= $specialistPool
order by
  case when map_name = $(ConvertTo-AutotuneSqlLiteral $MapValue) then 0 else 1 end,
  case when promoted then 0 else 1 end,
  least(score_rank, mass_rank, survival_rank),
  coalesce(avg_mass_ratio, 0) desc,
  score desc
limit $PoolSize;
"@

    $rawRows = @(Invoke-DbJsonQuery -Settings $Settings -Query $query)
    $rows = @()
    foreach ($row in $rawRows) {
        $rows += [pscustomobject]@{
            SessionId = [string]$row.SessionId
            CandidateId = [string]$row.CandidateId
            Score = To-Double $row.Score
            AvgMassRatio = To-Double $row.AvgMassRatio
            AvgGameTime = To-Double $row.AvgGameTime
            PrimaryFailureClass = [string]$row.PrimaryFailureClass
            Promoted = [bool]$row.Promoted
            MapName = [string]$row.MapName
            OpponentKey = [string]$row.OpponentKey
            Config = ConvertTo-TuneConfigHashtable -InputObject $row.Config
            ArchiveRole = [string](Get-ObjectPropertyValue -Object $row -Name 'ArchiveRole' -Default 'score')
            Source = if ($row.Promoted) { 'db-champion' } elseif ([string](Get-ObjectPropertyValue -Object $row -Name 'ArchiveRole' -Default 'score') -ne 'score') { 'db-pareto-' + [string]$row.ArchiveRole } else { 'db-history' }
        }
    }
    return $rows
}

function Get-HistoryDirectionHints {
    param(
        [array]$Candidates,
        [string]$ScopeLabel
    )

    $empty = New-EmptyHintSet -Source $ScopeLabel
    $usable = @($Candidates | Where-Object { $null -ne $_.Config })
    if ($usable.Count -lt 8) {
        return $empty
    }

    $sorted = @($usable | Sort-Object @{ Expression = { if ($_.Promoted) { 1 } else { 0 } }; Descending = $true }, @{ Expression = { $_.Score }; Descending = $true })
    $take = [math]::Min($DbDirectionPool, [math]::Max(3, [int][math]::Floor($sorted.Count * 0.25)))
    $top = @($sorted | Select-Object -First $take)
    $bottom = @($sorted | Select-Object -Last $take)
    $directions = @{}
    $specs = New-TuneSpecs
    foreach ($name in $specs.Keys) {
        $topAvg = (@($top | ForEach-Object { To-Double (Get-ObjectPropertyValue -Object $_.Config -Name $name) }) | Measure-Object -Average).Average
        $bottomAvg = (@($bottom | ForEach-Object { To-Double (Get-ObjectPropertyValue -Object $_.Config -Name $name) }) | Measure-Object -Average).Average
        $step = To-Double $specs[$name].Step
        if ($null -ne $topAvg -and $null -ne $bottomAvg -and [math]::Abs($topAvg - $bottomAvg) -ge ($step * 0.9)) {
            $directions[$name] = if ($topAvg -gt $bottomAvg) { 1 } else { -1 }
        }
    }

    return [pscustomobject]@{
        Directions = $directions
        SourceCount = $usable.Count
        Source = $ScopeLabel
    }
}

function Get-DbFailureRecoveryHints {
    param(
        [array]$Candidates,
        [string]$FailureClass
    )

    $empty = New-EmptyHintSet -Source ('db-failure:' + $FailureClass)
    if ([string]::IsNullOrWhiteSpace($FailureClass)) {
        return $empty
    }

    $failureRows = @($Candidates | Where-Object { $_.PrimaryFailureClass -eq $FailureClass -and $null -ne $_.Config } |
        Sort-Object -Property Score -Descending |
        Select-Object -First ([math]::Max(4, $DbDirectionPool)))
    $recoveryRows = @($Candidates | Where-Object { $_.PrimaryFailureClass -ne $FailureClass -and $null -ne $_.Config } |
        Sort-Object @{ Expression = { if ($_.Promoted) { 1 } else { 0 } }; Descending = $true }, @{ Expression = { $_.Score }; Descending = $true } |
        Select-Object -First ([math]::Max(6, $DbDirectionPool)))
    if ($failureRows.Count -lt 3 -or $recoveryRows.Count -lt 3) {
        return $empty
    }

    $directions = @{}
    $specs = New-TuneSpecs
    foreach ($name in $specs.Keys) {
        $failureAvg = (@($failureRows | ForEach-Object { To-Double (Get-ObjectPropertyValue -Object $_.Config -Name $name) }) | Measure-Object -Average).Average
        $recoveryAvg = (@($recoveryRows | ForEach-Object { To-Double (Get-ObjectPropertyValue -Object $_.Config -Name $name) }) | Measure-Object -Average).Average
        $step = To-Double $specs[$name].Step
        if ($null -ne $failureAvg -and $null -ne $recoveryAvg -and [math]::Abs($recoveryAvg - $failureAvg) -ge ($step * 0.9)) {
            $directions[$name] = if ($recoveryAvg -gt $failureAvg) { 1 } else { -1 }
        }
    }

    return [pscustomobject]@{
        Directions = $directions
        SourceCount = $failureRows.Count + $recoveryRows.Count
        Source = ('db-failure:' + $FailureClass)
    }
}

function Add-HintDelta {
    param(
        [hashtable]$Directions,
        [string]$Name,
        [int]$Delta
    )

    if ([string]::IsNullOrWhiteSpace($Name) -or $Delta -eq 0) {
        return
    }
    if (-not $Directions.ContainsKey($Name)) {
        $Directions[$Name] = 0
    }
    $Directions[$Name] += $Delta
}

function Add-TextActionHints {
    param(
        [hashtable]$Directions,
        [string]$Text,
        [int]$Delta
    )

    if ([string]::IsNullOrWhiteSpace($Text) -or $Delta -eq 0) {
        return
    }

    $value = $Text.ToLowerInvariant()
    if ($value -match 'reclaim_field') {
        Add-HintDelta -Directions $Directions -Name 'StrategyReclaimFieldBias' -Delta $Delta
        Add-HintDelta -Directions $Directions -Name 'ReclaimQuotaBias' -Delta $Delta
        Add-HintDelta -Directions $Directions -Name 'StrategyForwardTheaterBias' -Delta $Delta
    }
    if ($value -match 'trade_tech_for_tempo|front_pressure|push_window|land_push|tempo') {
        Add-HintDelta -Directions $Directions -Name 'StrategyTempoBias' -Delta $Delta
        Add-HintDelta -Directions $Directions -Name 'StrategyForwardTheaterBias' -Delta $Delta
    }
    if ($value -match 'starter_mex_claim|expand') {
        Add-HintDelta -Directions $Directions -Name 'StrategyExpandBias' -Delta $Delta
        Add-HintDelta -Directions $Directions -Name 'ExpansionQuotaBias' -Delta $Delta
    }
    if ($value -match 'stabilize|home_approach|hold:') {
        Add-HintDelta -Directions $Directions -Name 'StrategyStabilizeBias' -Delta $Delta
    }
    if ($value -match 'air_switch|air_control') {
        Add-HintDelta -Directions $Directions -Name 'StrategyAirBias' -Delta $Delta
        Add-HintDelta -Directions $Directions -Name 'EarlyAirUnlockBias' -Delta $Delta
    }
    if ($value -match 'first_land_hq') {
        Add-HintDelta -Directions $Directions -Name 'FactoryHQTimingBias' -Delta (-1 * $Delta)
        Add-HintDelta -Directions $Directions -Name 'FactoryHQEcoBias' -Delta (-1 * $Delta)
    }
    if ($value -match 'starter_mex_claim|land_factory_floor|bootstrap_factory') {
        Add-HintDelta -Directions $Directions -Name 'UpgradeTimeBias' -Delta $Delta
        Add-HintDelta -Directions $Directions -Name 'MexUpgradeBudgetBias' -Delta (-1 * $Delta)
    }
    if ($value -match 'pressure|focus_t1_spam|missing_first_factory|pre_hq_floor') {
        Add-HintDelta -Directions $Directions -Name 'FactoryTempoBias' -Delta $Delta
    }
    if ($value -match 'retreat|recall') {
        Add-HintDelta -Directions $Directions -Name 'ACUOpeningMaxDistance' -Delta (-1 * $Delta)
        Add-HintDelta -Directions $Directions -Name 'ACUMidMaxDistance' -Delta (-1 * $Delta)
        Add-HintDelta -Directions $Directions -Name 'ACULateMaxDistance' -Delta (-1 * $Delta)
        Add-HintDelta -Directions $Directions -Name 'StrategyStabilizeBias' -Delta $Delta
    }
}

function Add-ForceActionHints {
    param(
        [hashtable]$Directions,
        [string]$ActionValue,
        [int]$Delta
    )

    if ([string]::IsNullOrWhiteSpace($ActionValue) -or $Delta -eq 0) {
        return
    }
    if ($ActionValue -notmatch '^g(\d+)-m(\d+)-o(\d+)-r(\d+)$') {
        return
    }

    $guard = [int]$Matches[1]
    $main = [int]$Matches[2]
    $outer = [int]$Matches[3]
    $raid = [int]$Matches[4]

    if ($outer -gt 0) {
        Add-HintDelta -Directions $Directions -Name 'ForceOuterContestBias' -Delta $Delta
        Add-HintDelta -Directions $Directions -Name 'StrategyOuterRetentionBias' -Delta $Delta
    } elseif ($Delta -lt 0) {
        Add-HintDelta -Directions $Directions -Name 'ForceOuterContestBias' -Delta 1
        Add-HintDelta -Directions $Directions -Name 'StrategyOuterRetentionBias' -Delta 1
    }

    if ($raid -gt 0) {
        Add-HintDelta -Directions $Directions -Name 'ForceRaidBias' -Delta $Delta
    } elseif ($Delta -lt 0) {
        Add-HintDelta -Directions $Directions -Name 'ForceRaidBias' -Delta 1
    }

    if ($main -gt 0) {
        Add-HintDelta -Directions $Directions -Name 'StrategyForwardTheaterBias' -Delta $Delta
    }

    if ($guard -gt ($main + $outer + $raid + 2)) {
        Add-HintDelta -Directions $Directions -Name 'ForceHomeGuardBias' -Delta $Delta
    } elseif ($guard -gt 0 -and $outer -le 0 -and $raid -le 0 -and $Delta -lt 0) {
        Add-HintDelta -Directions $Directions -Name 'ForceHomeGuardBias' -Delta -1
    }
}

function Convert-ActionRowsToHints {
    param(
        [array]$Rows,
        [string]$Source
    )

    $directions = @{}
    $sourceCount = 0
    foreach ($row in @($Rows)) {
        $weight = To-Int (Get-ObjectPropertyValue -Object $row -Name 'HintWeight')
        if ($weight -eq 0) {
            continue
        }

        $subsystem = [string](Get-ObjectPropertyValue -Object $row -Name 'subsystem')
        $actionType = [string](Get-ObjectPropertyValue -Object $row -Name 'action_type')
        $actionValue = [string](Get-ObjectPropertyValue -Object $row -Name 'action_value')
        $sourceCount += [math]::Max(1, (To-Int (Get-ObjectPropertyValue -Object $row -Name 'samples')))

        Add-TextActionHints -Directions $directions -Text $actionValue -Delta $weight

        switch ($subsystem) {
            'force' {
                Add-ForceActionHints -Directions $directions -ActionValue $actionValue -Delta $weight
            }
            'engineer' {
                Add-HintDelta -Directions $directions -Name 'ExpansionQuotaBias' -Delta $weight
                Add-HintDelta -Directions $directions -Name 'ReclaimQuotaBias' -Delta $weight
            }
            'factory' {
                Add-HintDelta -Directions $directions -Name 'FactoryTempoBias' -Delta $weight
            }
            'upgrade' {
                Add-HintDelta -Directions $directions -Name 'UpgradeTimeBias' -Delta $weight
                Add-HintDelta -Directions $directions -Name 'MexUpgradeBudgetBias' -Delta (-1 * $weight)
            }
            'metrics' {
                Add-HintDelta -Directions $directions -Name 'StrategyForwardTheaterBias' -Delta $weight
            }
        }

        if ($actionType -eq 'mode_shift' -and $actionValue -eq 'air_control') {
            Add-HintDelta -Directions $directions -Name 'EarlyAirUnlockBias' -Delta $weight
            Add-HintDelta -Directions $directions -Name 'StrategyAirBias' -Delta $weight
        }
    }

    $final = @{}
    foreach ($name in $directions.Keys) {
        if ($directions[$name] -gt 0) {
            $final[$name] = 1
        } elseif ($directions[$name] -lt 0) {
            $final[$name] = -1
        }
    }

    return [pscustomobject]@{
        Directions = $final
        SourceCount = $sourceCount
        Source = $Source
    }
}

function Get-DbActionHints {
    param(
        $Settings,
        [string]$FailureClass = '',
        [int]$WindowSeconds = 120,
        [int]$MinSamples = 20
    )

    $source = if ([string]::IsNullOrWhiteSpace($FailureClass)) { 'db-action' } else { 'db-action:' + $FailureClass }
    $empty = New-EmptyHintSet -Source $source
    if ($DisableActionHints -or $null -eq $Settings) {
        return $empty
    }

    $rows = @()
    if ([string]::IsNullOrWhiteSpace($FailureClass)) {
        $positiveQuery = @"
select json_build_object(
    'subsystem', subsystem,
    'action_type', action_type,
    'action_value', action_value,
    'samples', samples,
    'HintWeight', 1
)::text as row_json
from autotune.v_action_value_by_choice
where window_seconds = $(ConvertTo-AutotuneSqlLiteral $WindowSeconds)
  and samples >= $(ConvertTo-AutotuneSqlLiteral $MinSamples)
order by avg_reward desc, samples desc
limit 20;
"@
        $negativeQuery = @"
select json_build_object(
    'subsystem', subsystem,
    'action_type', action_type,
    'action_value', action_value,
    'samples', samples,
    'HintWeight', -1
)::text as row_json
from autotune.v_action_value_by_choice
where window_seconds = $(ConvertTo-AutotuneSqlLiteral $WindowSeconds)
  and samples >= $(ConvertTo-AutotuneSqlLiteral $MinSamples)
order by avg_reward asc, samples desc
limit 20;
"@
        $rows += @(Invoke-DbJsonQuery -Settings $Settings -Query $positiveQuery)
        $rows += @(Invoke-DbJsonQuery -Settings $Settings -Query $negativeQuery)
        return Convert-ActionRowsToHints -Rows $rows -Source $source
    }

    $failureQuery = @"
select json_build_object(
    'subsystem', subsystem,
    'action_type', action_type,
    'action_value', action_value,
    'samples', samples,
    'HintWeight', -1
)::text as row_json
from autotune.v_action_failure_precursors
where primary_failure_class = $(ConvertTo-AutotuneSqlLiteral $FailureClass)
  and window_seconds = $(ConvertTo-AutotuneSqlLiteral $WindowSeconds)
  and samples >= $(ConvertTo-AutotuneSqlLiteral $MinSamples)
order by avg_reward asc, samples desc
limit 20;
"@
    $rows = @(Invoke-DbJsonQuery -Settings $Settings -Query $failureQuery)
    return Convert-ActionRowsToHints -Rows $rows -Source $source
}

function Select-MutationParent {
    param(
        $Baseline,
        $Best,
        [array]$Results,
        [array]$DbCandidates,
        [int]$CandidateIndex,
        [System.Random]$Random
    )

    $localEligible = @($Results | Where-Object { $_.RuntimeClean -and $null -ne $_.Config -and $_.CandidateId -ne 'baseline' -and $_.CandidateId -ne 'retest-baseline' })
    $localPoolMap = @{}
    foreach ($item in @($localEligible | Sort-Object -Property Score -Descending | Select-Object -First 3)) {
        $localPoolMap[[string]$item.CandidateId] = $item
    }
    foreach ($item in @($localEligible | Sort-Object -Property AvgMassRatio -Descending | Select-Object -First 2)) {
        $localPoolMap[[string]$item.CandidateId] = $item
    }
    foreach ($item in @($localEligible | Sort-Object -Property AvgGameTime -Descending | Select-Object -First 2)) {
        $localPoolMap[[string]$item.CandidateId] = $item
    }
    $localPool = @($localPoolMap.Values | Sort-Object -Property Score -Descending)
    $dbPool = @($DbCandidates | Select-Object -First ([math]::Max(0, $DbHistoryPool)))

    if ($CandidateIndex -eq 1) {
        $dbChampion = @($dbPool | Where-Object { $_.Promoted } | Select-Object -First 1)
        if ($dbChampion.Count -gt 0) {
            return $dbChampion[0]
        }
    }
    if ($CandidateIndex -eq 2 -and $localPool.Count -gt 0) {
        return [pscustomobject]@{
            SessionId = $sessionTag
            CandidateId = [string]$localPool[0].CandidateId
            Score = To-Double $localPool[0].Score
            AvgMassRatio = To-Double $localPool[0].AvgMassRatio
            AvgGameTime = To-Double $localPool[0].AvgGameTime
            PrimaryFailureClass = [string]$localPool[0].PrimaryFailureClass
            Promoted = $false
            Config = Copy-TuneConfig -Config $localPool[0].Config
            Source = 'session-best'
        }
    }

    $preferDb = $false
    $bestFailure = [string](Get-ObjectPropertyValue -Object $Best -Name 'PrimaryFailureClass')
    if ($dbPool.Count -gt 0 -and $bestFailure -in @('eco_starved', 'no_expansion', 'reclaim_failure', 'factory_spend_stall', 'over_defensive_stall', 'map_control_collapse')) {
        $preferDb = $true
    }

    $useDb = $dbPool.Count -gt 0 -and ($preferDb -or $Random.NextDouble() -lt 0.4)
    if ($useDb) {
        $topSlice = [math]::Min($dbPool.Count, [math]::Max(1, [int][math]::Ceiling($dbPool.Count * 0.4)))
        return $dbPool[$Random.Next(0, $topSlice)]
    }
    if ($localPool.Count -gt 0) {
        $chosenLocal = $localPool[$Random.Next(0, $localPool.Count)]
        return [pscustomobject]@{
            SessionId = $sessionTag
            CandidateId = [string]$chosenLocal.CandidateId
            Score = To-Double $chosenLocal.Score
            AvgMassRatio = To-Double $chosenLocal.AvgMassRatio
            AvgGameTime = To-Double $chosenLocal.AvgGameTime
            PrimaryFailureClass = [string]$chosenLocal.PrimaryFailureClass
            Promoted = $false
            Config = Copy-TuneConfig -Config $chosenLocal.Config
            Source = 'session-local'
        }
    }

    return [pscustomobject]@{
        SessionId = $sessionTag
        CandidateId = [string]$Baseline.CandidateId
        Score = To-Double $Baseline.Score
        AvgMassRatio = To-Double $Baseline.AvgMassRatio
        AvgGameTime = To-Double $Baseline.AvgGameTime
        PrimaryFailureClass = [string]$Baseline.PrimaryFailureClass
        Promoted = $false
        Config = Copy-TuneConfig -Config $Baseline.Config
        Source = 'baseline-fallback'
    }
}

function Get-FailureMutationHints {
    param([string]$FailureClass)

    $directions = @{}
    switch ($FailureClass) {
        'eco_starved' {
            $directions['StrategyExpandBias'] = 1
            $directions['ExpansionQuotaBias'] = 1
            $directions['BaseEngineerFloorBias'] = 1
            $directions['EngineerFactoryRatioBias'] = 1
            $directions['FactoryToMexCapBias'] = -1
            $directions['FactoryMassIncomeBias'] = 1
        }
        'no_expansion' {
            $directions['StrategyExpandBias'] = 1
            $directions['StrategyForwardTheaterBias'] = 1
            $directions['StrategyOuterRetentionBias'] = 1
            $directions['StrategyStabilizeBias'] = -1
            $directions['ExpansionQuotaBias'] = 1
            $directions['SafeExpandDistanceBias'] = 1
            $directions['SafeExpandThreatCapBias'] = 1
            $directions['SafeExpandEnemyBufferBias'] = -1
            $directions['ForceOuterContestBias'] = 1
            $directions['ForceHomeGuardBias'] = -1
        }
        'reclaim_failure' {
            $directions['ReclaimQuotaBias'] = 1
            $directions['ReclaimScoreBias'] = -1
            $directions['ReclaimRiskBias'] = 1
            $directions['ReclaimSupportBias'] = 1
            $directions['ReclaimNearbyBias'] = 1
            $directions['StrategyForwardTheaterBias'] = 1
            $directions['StrategyReclaimFieldBias'] = 1
            $directions['ReclaimFieldRadiusBias'] = 1
            $directions['ReclaimFieldMassBias'] = 1
            $directions['ReclaimRouteRiskBias'] = 1
            $directions['ReclaimEnemyMexBias'] = 1
        }
        'factory_spend_stall' {
            $directions['FactoryMassIncomeBias'] = -1
            $directions['FactoryEnergyIncomeBias'] = -1
            $directions['FactoryMassRatioBias'] = -1
            $directions['FactoryEnergyRatioBias'] = -1
            $directions['FactoryMassPerFactoryBias'] = -1
            $directions['FactoryToMexCapBias'] = 1
            $directions['FactoryTempoBias'] = 1
        }
        'over_defensive_stall' {
            $directions['StrategyStabilizeBias'] = -1
            $directions['StrategyExpandBias'] = 1
            $directions['StrategyTempoBias'] = 1
            $directions['StrategyForwardTheaterBias'] = 1
            $directions['StrategyOuterRetentionBias'] = 1
            $directions['StrategyCollapseResistanceBias'] = 1
            $directions['ReclaimRiskBias'] = 1
            $directions['FactoryTempoBias'] = 1
            $directions['ForceOuterContestBias'] = 1
            $directions['ForceHomeGuardBias'] = -1
            $directions['ForceRaidBias'] = 1
            $directions['EarlyAirUnlockBias'] = 1
        }
        'over_greedy_collapse' {
            $directions['StrategyStabilizeBias'] = 1
            $directions['StrategyTempoBias'] = -1
            $directions['StrategyExpandBias'] = -1
            $directions['ReclaimRiskBias'] = -1
            $directions['SafeExpandThreatCapBias'] = -1
            $directions['FactoryToMexCapBias'] = -1
            $directions['StrategyCollapseResistanceBias'] = -1
            $directions['ForceOuterContestBias'] = -1
            $directions['ForceHomeGuardBias'] = 1
            $directions['ForceRaidBias'] = -1
            $directions['EarlyAirUnlockBias'] = -1
        }
        'map_control_collapse' {
            $directions['StrategyExpandBias'] = 1
            $directions['StrategyTempoBias'] = 1
            $directions['StrategyForwardTheaterBias'] = 1
            $directions['StrategyOuterRetentionBias'] = 1
            $directions['StrategyReclaimFieldBias'] = 1
            $directions['StrategyTechBias'] = -1
            $directions['StrategyAirBias'] = -1
            $directions['ExpansionQuotaBias'] = 1
            $directions['ReclaimQuotaBias'] = 1
            $directions['ForceOuterContestBias'] = 1
            $directions['ForceRaidBias'] = 1
            $directions['ReclaimEnemyMexBias'] = 1
        }
        'engineer_collapse' {
            $directions['BaseEngineerFloorMin'] = 1
            $directions['BaseEngineerFloorBias'] = 1
            $directions['EngineerFactoryRatioBias'] = 1
            $directions['StrategyStabilizeBias'] = 1
            $directions['ReclaimRiskBias'] = -1
            $directions['ForceHomeGuardBias'] = 1
        }
        default {
            return [pscustomobject]@{
                Directions = $directions
                SourceFailureClass = $FailureClass
            }
        }
    }

    return [pscustomobject]@{
        Directions = $directions
        SourceFailureClass = $FailureClass
    }
}

function Round-To-Step {
    param([double]$Value, [double]$Step)
    if ($Step -le 0) { return $Value }
    return [math]::Round($Value / $Step) * $Step
}

function New-MutatedConfig {
    param(
        [hashtable]$Parent,
        [int]$CandidateIndex,
        [System.Random]$Random,
        $AdaptiveHints = $null,
        $FailureHints = $null
    )

    $specs = New-TuneSpecs
    $cfg = [ordered]@{}
    foreach ($key in $Parent.Keys) {
        $cfg[$key] = $Parent[$key]
    }

    $cfg.Version = 5
    $cfg.CandidateId = "candidate-$CandidateIndex"
    $cfg.ParentCandidateId = [string]($Parent.CandidateId)
    $cfg.ParentSource = [string](Get-ObjectPropertyValue -Object $Parent -Name 'ParentSource')
    $cfg.ParentSessionId = [string](Get-ObjectPropertyValue -Object $Parent -Name 'ParentSessionId')
    $cfg.ParentFailureClass = [string](Get-ObjectPropertyValue -Object $Parent -Name 'ParentFailureClass')
    $cfg.GeneratedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $cfg.GeneratedBy = 'run_economy_autotune.ps1'
    $cfg.Score = 0
    $cfg.Games = $GamesPerCandidate
    $cfg.MapName = $MapName

    $mutated = 0
    $forcedNames = @()
    if ($FailureHints -and $FailureHints.Directions -and $FailureHints.Directions.Count -gt 0 -and $CandidateIndex -le [math]::Min(6, $Candidates)) {
        $hintNames = @($FailureHints.Directions.Keys)
        $forceCount = [math]::Min(3, $hintNames.Count)
        while ($forcedNames.Count -lt $forceCount) {
            $pick = [string]$hintNames[$Random.Next(0, $hintNames.Count)]
            if ($forcedNames -notcontains $pick) {
                $forcedNames += $pick
            }
        }
    }
    foreach ($name in $specs.Keys) {
        $spec = $specs[$name]
        $value = To-Double $cfg[$name]
        if (($forcedNames -contains $name) -or $Random.NextDouble() -le $MutationRate) {
            $direction = if ($Random.NextDouble() -lt 0.5) { -1 } else { 1 }
            if ($FailureHints -and $FailureHints.Directions.ContainsKey($name) -and $Random.NextDouble() -lt 0.78) {
                $direction = [int]$FailureHints.Directions[$name]
            } elseif ($AdaptiveHints -and $AdaptiveHints.Directions.ContainsKey($name) -and $Random.NextDouble() -lt 0.65) {
                $direction = [int]$AdaptiveHints.Directions[$name]
            }
            $magnitude = 0.35 + ($Random.NextDouble() * 1.3)
            $delta = $direction * (To-Double $spec.Sigma) * $magnitude
            $value = $value + $delta
            $mutated += 1
        }
        $value = Round-To-Step -Value $value -Step (To-Double $spec.Step)
        $value = Clamp-Number -Value $value -Min (To-Double $spec.Min) -Max (To-Double $spec.Max)
        if ($spec.Kind -eq 'int') {
            $cfg[$name] = [int][math]::Round($value)
        } else {
            $cfg[$name] = [math]::Round($value, 4)
        }
    }

    if ($mutated -eq 0) {
        $first = @($specs.Keys)[0]
        $cfg[$first] = [int](Clamp-Number -Value ((To-Double $cfg[$first]) + 1) -Min (To-Double $specs[$first].Min) -Max (To-Double $specs[$first].Max))
    }
    return $cfg
}

function Invoke-ReleaseSync {
    if ($DryRun) {
        Write-Host '[DRYRUN] would sync AutoTuneConfig.lua to live mirrors'
        return
    }
    $syncOutput = & powershell -ExecutionPolicy Bypass -File $ReleaseChecks -SkipSyntax
    $syncOutput | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) {
        throw 'release_checks.ps1 -SkipSyntax failed.'
    }
}

function Invoke-AutorunBatch {
    param(
        [string]$CandidateId,
        [string]$CandidateDir,
        [int]$Games,
        [int]$SeedBase,
        [string]$MapOverride = ''
    )

    $logDir = Join-Path $CandidateDir 'logs'
    Ensure-Directory $logDir
    $runMap = if ([string]::IsNullOrWhiteSpace($MapOverride)) { $MapName } else { $MapOverride }

    $launchedLogs = @()
    $remaining = $Games
    $launched = 0
    $batch = 0
    while ($remaining -gt 0) {
        $batch += 1
        $instances = [math]::Min($ParallelInstances, $remaining)
        $seed = $SeedBase + $launched
        if ($DryRun) {
            $runTag = Get-Date -Format 'yyyyMMdd-HHmmss'
            Write-Host "[$CandidateId] launching batch $batch instances=$instances seed=$seed"
            for ($index = 1; $index -le $instances; $index++) {
                $drySeed = $seed + $index - 1
                $dryLog = Join-Path $logDir ("autorun-{0}-i{1}.log" -f $runTag, $index)
                Write-Host ("DRYRUN [{0}/{1}] seed={2} config=/lua/generated/autogen-{3}-i{0}.lua log={4}" -f $index, $instances, $drySeed, $runTag, $dryLog)
            }
            $launched += $instances
            $remaining -= $instances
            continue
        }

        $args = @(
            '-ExecutionPolicy', 'Bypass',
            '-File', $StartScript,
            '-Instances', $instances,
            '-TargetSpeed', $TargetSpeed,
            '-MapName', $runMap,
            '-BaseSeed', $seed,
            '-LogDir', $logDir,
            '-ExitDelaySeconds', 4
        )
        if ($MaxGameSeconds -gt 0) {
            $args += @('-MaxGameSeconds', $MaxGameSeconds)
        }
        if ($MaxRealSeconds -gt 0) {
            $args += @('-MaxRealSeconds', $MaxRealSeconds)
        }
        Write-Host "[$CandidateId] launching batch $batch instances=$instances seed=$seed"
        $output = & powershell @args
        $output | ForEach-Object { Write-Host $_ }

        foreach ($line in $output) {
            if ($line -match 'log=([A-Za-z]:\\.+?\.log)') {
                $launchedLogs += $Matches[1]
            }
        }

        if (-not $DryRun) {
            $pids = @()
            foreach ($line in $output) {
                if ($line -match 'pid=(\d+)') {
                    $pids += [int]$Matches[1]
                }
            }
            foreach ($gamePid in $pids) {
                try {
                    Wait-Process -Id $gamePid -ErrorAction Stop
                } catch {
                    Write-Warning "Process $gamePid was already gone or could not be waited on."
                }
            }
        }

        $launched += $instances
        $remaining -= $instances
    }

    return $logDir
}

function Invoke-Analysis {
    param(
        [string]$CandidateDir,
        [string]$LogDir
    )

    $analysisDir = Join-Path $CandidateDir 'analysis'
    $summaryDir = Join-Path $analysisDir 'summary'
    $kpiDir = Join-Path $analysisDir 'kpis'
    Ensure-Directory $summaryDir
    Ensure-Directory $kpiDir

    if ($DryRun) {
        Write-Host "[DRYRUN] would analyze logs in $LogDir"
        return [pscustomobject]@{ SummaryDir = $summaryDir; KpiDir = $kpiDir }
    }

    & powershell -ExecutionPolicy Bypass -File $AnalyzeScript -LogsPath (Join-Path $LogDir '*.log') -OutputDir $summaryDir
    if ($LASTEXITCODE -ne 0) { throw 'analyze_autorun_logs.ps1 failed.' }
    & powershell -ExecutionPolicy Bypass -File $KpiScript -LogsPath (Join-Path $LogDir '*.log') -OutputDir $kpiDir
    if ($LASTEXITCODE -ne 0) { throw 'extract_autorun_kpis.ps1 failed.' }

    return [pscustomobject]@{ SummaryDir = $summaryDir; KpiDir = $kpiDir }
}

function Get-RawLogMetrics {
    param([string]$Path)

    $maxReclaimOrders = 0
    $maxReclaimMass = 0.0
    $maxMex = 0
    $maxFac = 0
    $minEngAfter240 = 999
    $modularError = $false
    $runtimeFallback = $false
    $acuKilled = $false

    foreach ($line in [System.IO.File]::ReadLines($Path)) {
        if ($line -match 'ENGDIR MODULAR ERROR') { $modularError = $true }
        if ($line -match 'runtime-fallback') { $runtimeFallback = $true }
        if ($line -match 'OnACUKilled') { $acuKilled = $true }
        if ($line -match '\*OVERMIND ECONSCORE A\d+ t=([0-9.]+).*?mex=(\d+).*?fac=(\d+)\/(\d+)\/(\d+).*?eng=(\d+)\/(\d+).*?reclaim=(\d+)\/([0-9.]+)') {
            $t = To-Double $Matches[1]
            $mex = To-Int $Matches[2]
            $fac = (To-Int $Matches[3]) + (To-Int $Matches[4]) + (To-Int $Matches[5])
            $eng = To-Int $Matches[6]
            $reclaimOrders = To-Int $Matches[8]
            $reclaimMass = To-Double $Matches[9]
            if ($mex -gt $maxMex) { $maxMex = $mex }
            if ($fac -gt $maxFac) { $maxFac = $fac }
            if ($reclaimOrders -gt $maxReclaimOrders) { $maxReclaimOrders = $reclaimOrders }
            if ($reclaimMass -gt $maxReclaimMass) { $maxReclaimMass = $reclaimMass }
            if ($t -ge 240 -and $eng -lt $minEngAfter240) { $minEngAfter240 = $eng }
        }
    }
    if ($minEngAfter240 -eq 999) { $minEngAfter240 = 0 }

    return [pscustomobject]@{
        MaxReclaimOrders = $maxReclaimOrders
        MaxReclaimMass = [math]::Round($maxReclaimMass, 2)
        MaxMex = $maxMex
        MaxFac = $maxFac
        MinEngAfter240 = $minEngAfter240
        ModularError = $modularError
        RuntimeFallback = $runtimeFallback
        AcuKilled = $acuKilled
    }
}

function Get-FailureClass {
    param(
        [double]$GameTime,
        [double]$MassRatio,
        [double]$SpendRatio,
        [double]$MexAt240,
        [double]$MexAt360,
        [double]$ExpandOrders,
        [double]$FieldOrders,
        $Raw,
        [bool]$RuntimeClean
    )

    if (-not $RuntimeClean -or $Raw.ModularError -or $Raw.RuntimeFallback) { return 'runtime_failure' }
    if ($Raw.MinEngAfter240 -gt 0 -and $Raw.MinEngAfter240 -lt 3) { return 'engineer_collapse' }
    if ($MassRatio -lt 0.20 -and $GameTime -ge 900) { return 'over_defensive_stall' }
    if ($GameTime -lt 650 -and $MassRatio -ge 0.25) { return 'over_greedy_collapse' }
    if ($Raw.MaxMex -lt 4 -or ($MexAt360 -lt 4 -and $GameTime -ge 420)) { return 'eco_starved' }
    if ($ExpandOrders -le 0 -and $Raw.MaxMex -lt 8) { return 'no_expansion' }
    if ($FieldOrders -le 0 -and $Raw.MaxReclaimMass -lt 500 -and $GameTime -ge 600) { return 'reclaim_failure' }
    if ($SpendRatio -lt ($MassRatio * 0.72)) { return 'factory_spend_stall' }
    if ($MassRatio -lt 0.28) { return 'map_control_collapse' }
    return 'combat_or_acu_loss'
}

function Get-PrimaryFailureClass {
    param($Runs)
    $groups = @($Runs | Group-Object -Property FailureClass | Sort-Object -Property Count -Descending)
    if ($groups.Count -eq 0) {
        return 'unknown'
    }
    return [string]$groups[0].Name
}

function Score-Candidate {
    param(
        [string]$CandidateId,
        [string]$CandidateDir,
        [hashtable]$Config
    )

    if ($DryRun) {
        return [pscustomobject]@{
            CandidateId = $CandidateId
            Score = 0
            Games = 0
            WinRate = 0
            AvgGameTime = 0
            AvgMassRatio = 0
            RuntimeClean = $true
            PrimaryFailureClass = 'dry_run'
            Config = $Config
        }
    }

    $summaryCsv = Join-Path $CandidateDir 'analysis\summary\autorun_log_summary.csv'
    $playersCsv = Join-Path $CandidateDir 'analysis\summary\autorun_player_stats.csv'
    $kpiCsv = Join-Path $CandidateDir 'analysis\kpis\autorun_kpis.csv'
    if (-not (Test-Path -LiteralPath $summaryCsv)) { throw "Missing summary CSV: $summaryCsv" }
    if (-not (Test-Path -LiteralPath $playersCsv)) { throw "Missing player CSV: $playersCsv" }
    if (-not (Test-Path -LiteralPath $kpiCsv)) { throw "Missing KPI CSV: $kpiCsv" }

    $summaryRows = @(Import-Csv $summaryCsv)
    $playerRows = @(Import-Csv $playersCsv)
    $kpiRows = @(Import-Csv $kpiCsv)
    $scores = @()
    $wins = 0
    $runtimeClean = $true

    foreach ($run in $summaryRows) {
        $logName = [string]$run.log_name
        $om = @($playerRows | Where-Object { $_.log_name -eq $logName -and $_.player_name -match 'Overmind' } | Select-Object -First 1)
        $opp = @($playerRows | Where-Object { $_.log_name -eq $logName -and $_.player_name -match 'M27|M28' } | Select-Object -First 1)
        $kpi = @($kpiRows | Where-Object { $_.log_name -eq $logName } | Select-Object -First 1)
        $raw = Get-RawLogMetrics -Path $run.log_path
        $runClean = -not ($raw.ModularError -or $raw.RuntimeFallback -or (To-Int $run.errors) -gt 0)
        if (-not $runClean) {
            $runtimeClean = $false
        }

        $gameTime = To-Double $run.game_time_seconds
        $win = ([string]$run.winner_name -match 'Overmind')
        if ($win) { $wins += 1 }

        $massRatio = 0.0
        $spendRatio = 0.0
        if ($om.Count -gt 0 -and $opp.Count -gt 0) {
            $oppMass = [math]::Max(1, (To-Double $opp[0].mass_in))
            $oppSpend = [math]::Max(1, (To-Double $opp[0].mass_out))
            $massRatio = (To-Double $om[0].mass_in) / $oppMass
            $spendRatio = (To-Double $om[0].mass_out) / $oppSpend
        }

        $mex120 = if ($kpi.Count -gt 0) { To-Double $kpi[0].mex_at_120 } else { 0 }
        $mex240 = if ($kpi.Count -gt 0) { To-Double $kpi[0].mex_at_240 } else { 0 }
        $mex360 = if ($kpi.Count -gt 0) { To-Double $kpi[0].mex_at_360 } else { 0 }
        $fac600 = if ($kpi.Count -gt 0) { To-Double $kpi[0].fac_total_at_600 } else { 0 }
        $expandOrders = if ($kpi.Count -gt 0) { To-Double $kpi[0].expansion_orders_total } else { 0 }
        $fieldOrders = if ($kpi.Count -gt 0) { To-Double $kpi[0].reclaim_field_orders_total } else { 0 }

        $runScore = 0.0
        $runScore += $gameTime * 1.2
        $runScore += $massRatio * 10500.0
        $runScore += $spendRatio * 2600.0
        $runScore += $mex120 * 55.0
        $runScore += $mex240 * 45.0
        $runScore += $mex360 * 30.0
        $runScore += $raw.MaxMex * 95.0
        $runScore += [math]::Max($raw.MaxFac, $fac600) * 75.0
        $runScore += $expandOrders * 16.0
        $runScore += $fieldOrders * 9.0
        $runScore += $raw.MaxReclaimOrders * 10.0
        $runScore += $raw.MaxReclaimMass * 0.14
        if ($massRatio -lt 0.22) { $runScore -= (0.22 - $massRatio) * 18000.0 }
        if ($massRatio -lt 0.18) { $runScore -= (0.18 - $massRatio) * 32000.0 }
        if ($massRatio -ge 0.28) { $runScore += ($massRatio - 0.28) * 9000.0 }
        if ($gameTime -gt 900 -and $massRatio -lt 0.22) { $runScore -= [math]::Min(2500.0, ($gameTime - 900.0) * 4.0) }
        if ($win) { $runScore += 12000.0 }
        if ($gameTime -ge 2100 -and $massRatio -ge 0.25) { $runScore += 3000.0 }
        if ($gameTime -lt 900) { $runScore -= (900.0 - $gameTime) * 5.0 }
        if ($gameTime -lt 600) { $runScore -= (600.0 - $gameTime) * 10.0 }
        if ($raw.MinEngAfter240 -gt 0 -and $raw.MinEngAfter240 -lt 3) { $runScore -= (3 - $raw.MinEngAfter240) * 420.0 }
        $runScore -= (To-Double $run.warnings) * 3.0
        $runScore -= (To-Double $run.errors) * 6000.0
        if ($raw.ModularError) { $runScore -= 10000.0 }
        if ($raw.RuntimeFallback) { $runScore -= 7000.0 }
        $failureClass = Get-FailureClass -GameTime $gameTime -MassRatio $massRatio -SpendRatio $spendRatio -MexAt240 $mex240 -MexAt360 $mex360 -ExpandOrders $expandOrders -FieldOrders $fieldOrders -Raw $raw -RuntimeClean $runClean
        $scores += [pscustomobject]@{
            LogName = $logName
            Score = [math]::Round($runScore, 2)
            GameTime = $gameTime
            Win = $win
            MassRatio = [math]::Round($massRatio, 4)
            SpendRatio = [math]::Round($spendRatio, 4)
            MaxMex = $raw.MaxMex
            MaxFac = $raw.MaxFac
            ReclaimMass = $raw.MaxReclaimMass
            MinEngAfter240 = $raw.MinEngAfter240
            FailureClass = $failureClass
        }
    }

    $avgScore = if ($scores.Count -gt 0) { (@($scores | Measure-Object -Property Score -Average).Average) } else { -999999 }
    $avgTime = if ($scores.Count -gt 0) { (@($scores | Measure-Object -Property GameTime -Average).Average) } else { 0 }
    $avgMassRatio = if ($scores.Count -gt 0) { (@($scores | Measure-Object -Property MassRatio -Average).Average) } else { 0 }
    $winRate = if ($scores.Count -gt 0) { $wins / $scores.Count } else { 0 }

    $result = [pscustomobject]@{
        CandidateId = $CandidateId
        Score = [math]::Round($avgScore, 2)
        Games = $scores.Count
        WinRate = [math]::Round($winRate, 4)
        AvgGameTime = [math]::Round($avgTime, 2)
        AvgMassRatio = [math]::Round($avgMassRatio, 4)
        RuntimeClean = $runtimeClean
        PrimaryFailureClass = Get-PrimaryFailureClass -Runs $scores
        Runs = $scores
        Config = $Config
    }
    $result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $CandidateDir 'score.json') -Encoding UTF8
    return $result
}

function Run-Candidate {
    param(
        [string]$CandidateId,
        [hashtable]$Config,
        [string]$SessionDir,
        [int]$SeedBase,
        [int]$GamesOverride = 0,
        [string]$MapOverride = ''
    )

    $candidateDir = Join-Path $SessionDir $CandidateId
    Ensure-Directory $candidateDir
    $runGames = if ($GamesOverride -gt 0) { $GamesOverride } else { $GamesPerCandidate }
    $runMap = if ([string]::IsNullOrWhiteSpace($MapOverride)) { $MapName } else { $MapOverride }
    $Config.CandidateId = $CandidateId
    $Config.GeneratedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $Config.Games = $runGames
    $Config.MapName = $runMap

    $candidateConfigPath = Join-Path $candidateDir 'AutoTuneConfig.lua'
    Write-TuneConfig -Config $Config -Path $candidateConfigPath

    if (-not $DryRun) {
        Write-TuneConfig -Config $Config -Path $ConfigPath
        Invoke-ReleaseSync
    } else {
        Write-Host "[DRYRUN] generated candidate config: $candidateConfigPath"
    }

    $logDir = Invoke-AutorunBatch -CandidateId $CandidateId -CandidateDir $candidateDir -Games $runGames -SeedBase $SeedBase -MapOverride $runMap
    [void](Invoke-Analysis -CandidateDir $candidateDir -LogDir $logDir)
    $result = Score-Candidate -CandidateId $CandidateId -CandidateDir $candidateDir -Config $Config
    $result | Add-Member -NotePropertyName ParentCandidateId -NotePropertyValue ([string](Get-ObjectPropertyValue -Object $Config -Name 'ParentCandidateId')) -Force
    $result | Add-Member -NotePropertyName ParentSource -NotePropertyValue ([string](Get-ObjectPropertyValue -Object $Config -Name 'ParentSource')) -Force
    $result | Add-Member -NotePropertyName ParentSessionId -NotePropertyValue ([string](Get-ObjectPropertyValue -Object $Config -Name 'ParentSessionId')) -Force
    $result | Add-Member -NotePropertyName ParentFailureClass -NotePropertyValue ([string](Get-ObjectPropertyValue -Object $Config -Name 'ParentFailureClass')) -Force
    Write-Host ("[$CandidateId] score={0} games={1} winRate={2} avgTime={3} massRatio={4} clean={5}" -f $result.Score, $result.Games, $result.WinRate, $result.AvgGameTime, $result.AvgMassRatio, $result.RuntimeClean)
    return $result
}

function Get-PromotionDecision {
    param(
        $Candidate,
        $Baseline,
        [double]$Margin
    )

    $reasons = @()
    if ($Candidate.CandidateId -eq $Baseline.CandidateId -or $Candidate.CandidateId -eq 'baseline' -or $Candidate.CandidateId -eq 'retest-baseline') {
        $reasons += 'candidate is baseline'
    }
    if (-not $Candidate.RuntimeClean) {
        $reasons += 'candidate runtime was not clean'
    }
    if ($Margin -lt $PromoteScoreMargin) {
        $reasons += ("score margin {0:P2} below required {1:P2}" -f $Margin, $PromoteScoreMargin)
    }

    $requiredMassRatio = [double]$Baseline.AvgMassRatio - $MaxMassRatioRegression
    if ($RequireMassRatioGain -gt 0) {
        $requiredMassRatio = [double]$Baseline.AvgMassRatio + $RequireMassRatioGain
    }
    if ($MinMassRatioAbsolute -gt 0 -and $requiredMassRatio -lt $MinMassRatioAbsolute) {
        $requiredMassRatio = $MinMassRatioAbsolute
    }
    if ([double]$Candidate.AvgMassRatio -lt $requiredMassRatio) {
        $reasons += ("mass ratio {0} below required {1}" -f $Candidate.AvgMassRatio, [math]::Round($requiredMassRatio, 4))
    }

    $minimumGameTime = [double]$Baseline.AvgGameTime * (1.0 - $MaxSurvivalRegression)
    if ($MinAvgGameTime -gt 0 -and $minimumGameTime -lt $MinAvgGameTime) {
        $minimumGameTime = $MinAvgGameTime
    }
    if ([double]$Candidate.AvgGameTime -lt $minimumGameTime) {
        $reasons += ("avg game time {0} below required {1}" -f $Candidate.AvgGameTime, [math]::Round($minimumGameTime, 2))
    }

    return [pscustomobject]@{
        Allowed = ($reasons.Count -eq 0)
        Reasons = $reasons
        RequiredMassRatio = [math]::Round($requiredMassRatio, 4)
        MinimumGameTime = [math]::Round($minimumGameTime, 2)
    }
}

function Save-Champion {
    param(
        $Winner,
        $Baseline,
        [double]$Margin,
        [string]$SessionDir
    )

    if ($DryRun) {
        Write-Host '[DRYRUN] would archive promoted champion'
        return
    }

    Ensure-Directory $ChampionDir
    $safeId = Get-SafeName -Value ([string]$Winner.CandidateId)
    $championPath = Join-Path $ChampionDir ("{0}-{1}.lua" -f $sessionTag, $safeId)
    $currentPath = Join-Path $ChampionDir 'current.lua'
    Write-TuneConfig -Config $Winner.Config -Path $championPath
    Write-TuneConfig -Config $Winner.Config -Path $currentPath

    $manifest = [pscustomobject]@{
        Session = $sessionTag
        SessionDir = $SessionDir
        CandidateId = $Winner.CandidateId
        BaselineCandidateId = $Baseline.CandidateId
        Score = $Winner.Score
        BaselineScore = $Baseline.Score
        Margin = [math]::Round($Margin, 5)
        AvgGameTime = $Winner.AvgGameTime
        BaselineAvgGameTime = $Baseline.AvgGameTime
        AvgMassRatio = $Winner.AvgMassRatio
        BaselineAvgMassRatio = $Baseline.AvgMassRatio
        ConfigPath = $championPath
        CreatedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    }
    $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $ChampionDir ("{0}-{1}.json" -f $sessionTag, $safeId)) -Encoding UTF8
}

function Test-ParetoDominated {
    param(
        $Candidate,
        [array]$Candidates
    )

    foreach ($other in $Candidates) {
        if ($other.CandidateId -eq $Candidate.CandidateId) {
            continue
        }
        $scoreBetter = (To-Double $other.Score) -ge (To-Double $Candidate.Score)
        $massBetter = (To-Double $other.AvgMassRatio) -ge (To-Double $Candidate.AvgMassRatio)
        $timeBetter = (To-Double $other.AvgGameTime) -ge (To-Double $Candidate.AvgGameTime)
        $strictBetter = ((To-Double $other.Score) -gt (To-Double $Candidate.Score)) `
            -or ((To-Double $other.AvgMassRatio) -gt (To-Double $Candidate.AvgMassRatio)) `
            -or ((To-Double $other.AvgGameTime) -gt (To-Double $Candidate.AvgGameTime))
        if ($scoreBetter -and $massBetter -and $timeBetter -and $strictBetter) {
            return $true
        }
    }

    return $false
}

function Add-ParetoArchiveEntry {
    param(
        [hashtable]$Seen,
        [System.Collections.ArrayList]$Entries,
        $Candidate,
        [string]$Role
    )

    if ($null -eq $Candidate -or $null -eq $Candidate.Config) {
        return
    }

    $key = [string]$Candidate.CandidateId
    if ([string]::IsNullOrWhiteSpace($key) -or $Seen.ContainsKey($key)) {
        return
    }

    $Seen[$key] = $true
    [void]$Entries.Add([pscustomobject]@{
        Role = $Role
        Candidate = $Candidate
    })
}

function Save-ParetoArchive {
    param(
        [array]$Results,
        [string]$SessionDir
    )

    $eligible = @($Results |
        Where-Object {
            $_.RuntimeClean `
                -and $null -ne $_.Config `
                -and $_.CandidateId -ne 'baseline' `
                -and $_.CandidateId -ne 'retest-baseline'
        })
    if ($eligible.Count -le 0) {
        return @()
    }

    $entries = [System.Collections.ArrayList]::new()
    $seen = @{}
    foreach ($candidate in $eligible) {
        if (-not (Test-ParetoDominated -Candidate $candidate -Candidates $eligible)) {
            Add-ParetoArchiveEntry -Seen $seen -Entries $entries -Candidate $candidate -Role 'pareto'
        }
    }
    Add-ParetoArchiveEntry -Seen $seen -Entries $entries -Candidate ($eligible | Sort-Object -Property Score -Descending | Select-Object -First 1) -Role 'top_score'
    Add-ParetoArchiveEntry -Seen $seen -Entries $entries -Candidate ($eligible | Sort-Object -Property AvgMassRatio -Descending | Select-Object -First 1) -Role 'top_mass_ratio'
    Add-ParetoArchiveEntry -Seen $seen -Entries $entries -Candidate ($eligible | Sort-Object -Property AvgGameTime -Descending | Select-Object -First 1) -Role 'top_survival'
    Add-ParetoArchiveEntry -Seen $seen -Entries $entries -Candidate ($eligible |
        Sort-Object @{ Expression = { (To-Double $_.Score) + ((To-Double $_.AvgMassRatio) * 1200) + ((To-Double $_.AvgGameTime) * 0.55) }; Descending = $true } |
        Select-Object -First 1) -Role 'balanced'

    if ($DryRun) {
        Write-Host ("[DRYRUN] would archive Pareto configs: {0}" -f $entries.Count)
        return @($entries | ForEach-Object {
            [pscustomobject]@{
                Role = $_.Role
                CandidateId = $_.Candidate.CandidateId
                Score = $_.Candidate.Score
                AvgMassRatio = $_.Candidate.AvgMassRatio
                AvgGameTime = $_.Candidate.AvgGameTime
                ConfigPath = ''
            }
        })
    }

    $paretoDir = Join-Path $ChampionDir 'pareto'
    Ensure-Directory $ChampionDir
    Ensure-Directory $paretoDir
    $manifestEntries = @()
    foreach ($entry in $entries) {
        $candidate = $entry.Candidate
        $safeRole = Get-SafeName -Value ([string]$entry.Role)
        $safeId = Get-SafeName -Value ([string]$candidate.CandidateId)
        $configPath = Join-Path $paretoDir ("{0}-{1}-{2}.lua" -f $sessionTag, $safeRole, $safeId)
        Write-TuneConfig -Config $candidate.Config -Path $configPath
        $manifestEntries += [pscustomobject]@{
            Session = $sessionTag
            SessionDir = $SessionDir
            Role = $entry.Role
            CandidateId = $candidate.CandidateId
            Score = $candidate.Score
            AvgMassRatio = $candidate.AvgMassRatio
            AvgGameTime = $candidate.AvgGameTime
            PrimaryFailureClass = $candidate.PrimaryFailureClass
            ParentCandidateId = $candidate.ParentCandidateId
            ParentSource = $candidate.ParentSource
            ConfigPath = $configPath
        }
    }

    $manifest = [pscustomobject]@{
        Session = $sessionTag
        SessionDir = $SessionDir
        CreatedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        Entries = $manifestEntries
    }
    $manifestPath = Join-Path $paretoDir ("{0}-pareto.json" -f $sessionTag)
    $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
    $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $paretoDir 'latest.json') -Encoding UTF8
    return $manifestEntries
}

function New-AggregatedResult {
    param(
        [string]$CandidateId,
        [array]$Items,
        [hashtable]$Config
    )

    if ($Items.Count -eq 0) {
        return $null
    }

    return [pscustomobject]@{
        CandidateId = $CandidateId
        Score = [math]::Round((@($Items | Measure-Object -Property Score -Average).Average), 2)
        Games = (@($Items | Measure-Object -Property Games -Sum).Sum)
        WinRate = [math]::Round((@($Items | Measure-Object -Property WinRate -Average).Average), 4)
        AvgGameTime = [math]::Round((@($Items | Measure-Object -Property AvgGameTime -Average).Average), 2)
        AvgMassRatio = [math]::Round((@($Items | Measure-Object -Property AvgMassRatio -Average).Average), 4)
        RuntimeClean = (@($Items | Where-Object { -not $_.RuntimeClean }).Count -eq 0)
        PrimaryFailureClass = Get-PrimaryFailureClass -Runs @($Items | ForEach-Object { [pscustomobject]@{ FailureClass = $_.PrimaryFailureClass } })
        Runs = @()
        Config = $Config
    }
}

function Write-SessionReport {
    param(
        [string]$Path,
        $Summary,
        [array]$Results
    )

    $lines = @()
    $lines += '# Economy Autotune Session'
    $lines += ''
    $lines += "- Session: $($Summary.Session)"
    $lines += "- Map: $($Summary.MapName)"
    $lines += "- Promoted: $($Summary.Promoted)"
    $lines += "- Best: $($Summary.BestCandidate)"
    $lines += "- Best score: $($Summary.BestScore)"
    $lines += "- Best average mass ratio: $($Summary.BestAvgMassRatio)"
    $lines += "- Best average game time: $($Summary.BestAvgGameTime)"
    $lines += "- Baseline score: $($Summary.BaselineScore)"
    $lines += "- Baseline average mass ratio: $($Summary.BaselineAvgMassRatio)"
    $lines += "- Baseline average game time: $($Summary.BaselineAvgGameTime)"
    $lines += ''
    if ($Summary.PromotionBlockedReasons -and $Summary.PromotionBlockedReasons.Count -gt 0) {
        $lines += '## Promotion Blockers'
        $lines += ''
        foreach ($reason in $Summary.PromotionBlockedReasons) {
            $lines += "- $reason"
        }
        $lines += ''
    }
    if ($Summary.ParetoArchive -and $Summary.ParetoArchive.Count -gt 0) {
        $lines += '## Pareto Archive'
        $lines += ''
        $lines += '| Role | Candidate | Score | Avg Time | Mass Ratio | Failure |'
        $lines += '| --- | --- | ---: | ---: | ---: | --- |'
        foreach ($row in @($Summary.ParetoArchive)) {
            $lines += "| $($row.Role) | $($row.CandidateId) | $($row.Score) | $($row.AvgGameTime) | $($row.AvgMassRatio) | $($row.PrimaryFailureClass) |"
        }
        $lines += ''
    }
    $lines += '## Candidates'
    $lines += ''
    $lines += '| Candidate | Parent | Source | Score | Games | Avg Time | Mass Ratio | Failure | Clean |'
    $lines += '| --- | --- | --- | ---: | ---: | ---: | ---: | --- | --- |'
    foreach ($row in @($Results | Sort-Object -Property Score -Descending)) {
        $lines += "| $($row.CandidateId) | $($row.ParentCandidateId) | $($row.ParentSource) | $($row.Score) | $($row.Games) | $($row.AvgGameTime) | $($row.AvgMassRatio) | $($row.PrimaryFailureClass) | $($row.RuntimeClean) |"
    }
    $lines += ''
    Set-Content -LiteralPath $Path -Value ($lines -join [Environment]::NewLine) -Encoding UTF8
}

Ensure-Directory $RunRoot
$sessionTag = Get-Date -Format 'yyyyMMdd-HHmmss'
$sessionDir = Join-Path $RunRoot $sessionTag
Ensure-Directory $sessionDir
$buildMeta = if (Get-Command Get-OvermindBuildMetadata -ErrorAction SilentlyContinue) { Get-OvermindBuildMetadata -RepoRoot $RepoRoot } else { $null }

if ($BaseSeed -le 0) {
    $BaseSeed = Get-Random -Minimum 1 -Maximum 2000000000
}
$rng = [System.Random]::new($BaseSeed)
$adaptiveHints = Get-AdaptiveHints -Path $RunRoot
$dbSettings = $null
$dbHistoryCandidates = @()
$dbAdaptiveHints = New-EmptyHintSet -Source 'db-history'
$dbActionHints = New-EmptyHintSet -Source 'db-action'
$baselineConfig = Read-TuneConfig -Path $ConfigPath
$baselineConfig.CandidateId = if ($baselineConfig.CandidateId) { [string]$baselineConfig.CandidateId } else { 'baseline' }
$baselineConfig.ParentSource = if ([string]::IsNullOrWhiteSpace([string]$baselineConfig.ParentSource)) { 'manual' } else { [string]$baselineConfig.ParentSource }
$baselineRawPath = Join-Path $sessionDir 'baseline-AutoTuneConfig.raw.lua'
if (Test-Path -LiteralPath $ConfigPath) {
    Copy-Item -LiteralPath $ConfigPath -Destination $baselineRawPath -Force
} else {
    Write-TuneConfig -Config $baselineConfig -Path $baselineRawPath
}
$Script:RestoreConfigPath = $baselineRawPath
$baselinePath = Join-Path $sessionDir 'baseline-AutoTuneConfig.lua'
Write-TuneConfig -Config $baselineConfig -Path $baselinePath

Write-Host "Economy autotune session: $sessionTag"
Write-Host "  candidates=$Candidates gamesPerCandidate=$GamesPerCandidate parallel=$ParallelInstances speed=$TargetSpeed map=$MapName seed=$BaseSeed"
Write-Host "  runDir=$sessionDir"
if ($adaptiveHints.SourceCount -gt 0) {
    Write-Host ("  adaptive mutation hints={0} sourceCandidates={1}" -f $adaptiveHints.Directions.Count, $adaptiveHints.SourceCount)
}
if ($UseDatabase -and (Get-Command Get-AutotuneDbSettings -ErrorAction SilentlyContinue)) {
    try {
        $dbSettings = Get-AutotuneDbSettings -RepoRoot $RepoRoot -ComposeFile $DbComposeFile -EnvFile $DbEnvFile -ProjectName $DbProjectName
        $dbHistoryCandidates = @(Get-DbHistoricalCandidates -Settings $dbSettings -MapValue $MapName -PoolSize ([math]::Max($DbHistoryPool, 48)))
        $dbAdaptiveHints = Get-HistoryDirectionHints -Candidates $dbHistoryCandidates -ScopeLabel 'db-history'
        $dbActionHints = Get-DbActionHints -Settings $dbSettings -WindowSeconds 120 -MinSamples $DbActionMinSamples
        if ($dbHistoryCandidates.Count -gt 0) {
            $dbChampionCount = @($dbHistoryCandidates | Where-Object { $_.Promoted }).Count
            Write-Host ("  db history candidates={0} champions={1} adaptiveDirections={2} actionDirections={3}" -f $dbHistoryCandidates.Count, $dbChampionCount, $dbAdaptiveHints.Directions.Count, $dbActionHints.Directions.Count)
        }
    } catch {
        Write-Warning ("DB mutation context unavailable: {0}" -f $_)
        $dbSettings = $null
        $dbHistoryCandidates = @()
        $dbAdaptiveHints = New-EmptyHintSet -Source 'db-history'
        $dbActionHints = New-EmptyHintSet -Source 'db-action'
    }
}

$results = @()
if (-not $SkipBaseline) {
    $baseRunConfig = [ordered]@{}
    foreach ($key in $baselineConfig.Keys) { $baseRunConfig[$key] = $baselineConfig[$key] }
    $baseRunConfig.ParentCandidateId = 'baseline'
    $results += Run-Candidate -CandidateId 'baseline' -Config $baseRunConfig -SessionDir $sessionDir -SeedBase $BaseSeed
} else {
    Write-Host 'Skipping baseline run; promotion will compare against score in current AutoTuneConfig.lua.'
    $results += [pscustomobject]@{
        CandidateId = 'baseline'
        Score = To-Double $baselineConfig.Score
        Games = 0
        WinRate = 0
        AvgGameTime = 0
        AvgMassRatio = 0
        RuntimeClean = $true
        PrimaryFailureClass = 'skipped_baseline'
        Runs = @()
        Config = $baselineConfig
        ParentCandidateId = [string](Get-ObjectPropertyValue -Object $baselineConfig -Name 'ParentCandidateId')
        ParentSource = [string](Get-ObjectPropertyValue -Object $baselineConfig -Name 'ParentSource')
        ParentSessionId = [string](Get-ObjectPropertyValue -Object $baselineConfig -Name 'ParentSessionId')
        ParentFailureClass = [string](Get-ObjectPropertyValue -Object $baselineConfig -Name 'ParentFailureClass')
    }
}

$baseline = @($results | Where-Object { $_.CandidateId -eq 'baseline' } | Select-Object -First 1)[0]
$best = $results[0]
for ($i = 1; $i -le $Candidates; $i++) {
    $parentSelection = Select-MutationParent -Baseline $baseline -Best $best -Results $results -DbCandidates $dbHistoryCandidates -CandidateIndex $i -Random $rng
    $parent = ConvertTo-TuneConfigHashtable -InputObject $parentSelection.Config
    $localFailureHints = Get-FailureMutationHints -FailureClass $best.PrimaryFailureClass
    $dbFailureHints = Get-DbFailureRecoveryHints -Candidates $dbHistoryCandidates -FailureClass $best.PrimaryFailureClass
    $dbActionFailureHints = Get-DbActionHints -Settings $dbSettings -FailureClass $best.PrimaryFailureClass -WindowSeconds 120 -MinSamples $DbActionMinSamples
    $failureHints = Merge-HintSets -HintSets @($localFailureHints, $dbFailureHints, $dbActionFailureHints) -Source 'failure-aware'
    $combinedAdaptiveHints = Merge-HintSets -HintSets @($adaptiveHints, $dbAdaptiveHints, $dbActionHints) -Source 'adaptive'
    if ($i -eq 1) {
        Write-Host ("  parent source={0} candidate={1} session={2}" -f $parentSelection.Source, $parentSelection.CandidateId, $parentSelection.SessionId)
        if ($failureHints.Directions.Count -gt 0) {
            Write-Host ("  failure-aware mutation class={0} hints={1}" -f $best.PrimaryFailureClass, $failureHints.Directions.Count)
        }
        if ($dbActionHints.Directions.Count -gt 0 -or $dbActionFailureHints.Directions.Count -gt 0) {
            Write-Host ("  action-aware hints global={0} failure={1}" -f $dbActionHints.Directions.Count, $dbActionFailureHints.Directions.Count)
        }
    }
    $parent.ParentSource = [string]$parentSelection.Source
    $parent.ParentSessionId = [string]$parentSelection.SessionId
    $parent.ParentFailureClass = [string]$parentSelection.PrimaryFailureClass
    $candidateConfig = New-MutatedConfig -Parent $parent -CandidateIndex $i -Random $rng -AdaptiveHints $combinedAdaptiveHints -FailureHints $failureHints
    $candidateSeed = $BaseSeed + ($i * 100000)
    $candidateResult = Run-Candidate -CandidateId ("candidate-$i") -Config $candidateConfig -SessionDir $sessionDir -SeedBase $candidateSeed
    $results += $candidateResult
    if ($candidateResult.RuntimeClean -and $candidateResult.Score -gt $best.Score) {
        $best = $candidateResult
    }
}

$promotionBaseline = $baseline
$promotionBest = $best
$retestResults = @()

if ($RetestTop -gt 0 -and -not $DryRun) {
    $retestGamesActual = if ($RetestGames -gt 0) { $RetestGames } else { $GamesPerCandidate }
    $retestMapList = Get-RetestMapList
    $topCandidates = @($results |
        Where-Object { $_.CandidateId -ne 'baseline' -and $_.RuntimeClean } |
        Sort-Object -Property Score -Descending |
        Select-Object -First $RetestTop)

    if ($topCandidates.Count -gt 0) {
        Write-Host ("Retesting top {0} candidate(s), games={1}, maps={2}" -f $topCandidates.Count, $retestGamesActual, ($retestMapList -join ','))
        $retestSeed = $BaseSeed + 900000000
        $baselineRetests = @()
        $candidateRetests = @{}
        $mapIndex = 0
        foreach ($retestMap in $retestMapList) {
            $mapIndex += 1
            $safeMap = Get-SafeName -Value $retestMap
            $baselineRetestConfig = Copy-TuneConfig -Config $baselineConfig
            $baselineRetest = Run-Candidate -CandidateId ("retest-baseline-{0}" -f $safeMap) -Config $baselineRetestConfig -SessionDir $sessionDir -SeedBase ($retestSeed + ($mapIndex * 1000000)) -GamesOverride $retestGamesActual -MapOverride $retestMap
            $baselineRetests += $baselineRetest
            $retestResults += $baselineRetest

            $candidateIndex = 0
            foreach ($candidate in $topCandidates) {
                $candidateIndex += 1
                $candidateConfig = Copy-TuneConfig -Config $candidate.Config
                $candidateConfig.ParentCandidateId = [string]$candidate.CandidateId
                $candidateKey = [string]$candidate.CandidateId
                $retestResult = Run-Candidate -CandidateId ("retest-{0}-{1}" -f (Get-SafeName -Value $candidateKey), $safeMap) -Config $candidateConfig -SessionDir $sessionDir -SeedBase ($retestSeed + ($mapIndex * 1000000) + ($candidateIndex * 100000)) -GamesOverride $retestGamesActual -MapOverride $retestMap
                if (-not $candidateRetests.ContainsKey($candidateKey)) {
                    $candidateRetests[$candidateKey] = @()
                }
                $candidateRetests[$candidateKey] += $retestResult
                $retestResults += $retestResult
            }
        }

        $results += $retestResults
        $promotionBaseline = New-AggregatedResult -CandidateId 'retest-baseline' -Items $baselineRetests -Config $baselineConfig
        $aggregatedCandidates = @()
        foreach ($candidate in $topCandidates) {
            $candidateKey = [string]$candidate.CandidateId
            if ($candidateRetests.ContainsKey($candidateKey)) {
                $aggregatedCandidates += New-AggregatedResult -CandidateId ("retest-{0}" -f (Get-SafeName -Value $candidateKey)) -Items $candidateRetests[$candidateKey] -Config $candidate.Config
            }
        }
        $promotionBest = @($aggregatedCandidates |
            Where-Object { $_.RuntimeClean } |
            Sort-Object -Property Score -Descending |
            Select-Object -First 1)[0]
        if (-not $promotionBest) {
            $promotionBest = $promotionBaseline
        }
    }
}

$margin = if ([math]::Abs($promotionBaseline.Score) -gt 1) { ($promotionBest.Score - $promotionBaseline.Score) / [math]::Abs($promotionBaseline.Score) } else { $promotionBest.Score - $promotionBaseline.Score }
$promotionDecision = Get-PromotionDecision -Candidate $promotionBest -Baseline $promotionBaseline -Margin $margin
$promoted = $false
if (-not $NoPromote -and $promotionDecision.Allowed) {
    $promoteConfig = $promotionBest.Config
    $promoteConfig.Score = $promotionBest.Score
    $promoteConfig.Games = $promotionBest.Games
    $promoteConfig.GeneratedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    if (-not $DryRun) {
        Write-TuneConfig -Config $promoteConfig -Path $ConfigPath
        Invoke-ReleaseSync
        Save-Champion -Winner $promotionBest -Baseline $promotionBaseline -Margin $margin -SessionDir $sessionDir
    }
    $promoted = $true
    Write-Host ("PROMOTED {0}: score {1} vs baseline {2}, margin {3:P2}" -f $promotionBest.CandidateId, $promotionBest.Score, $promotionBaseline.Score, $margin)
} else {
    if (-not $DryRun -and -not $KeepLosingCandidateConfig) {
        Copy-Item -LiteralPath $baselineRawPath -Destination $ConfigPath -Force
        Invoke-ReleaseSync
    }
    if ($NoPromote) {
        Write-Host 'NO PROMOTION: NoPromote was set.'
    } else {
        Write-Host ("NO PROMOTION: best={0} score={1}, baseline={2}, margin={3:P2}, required={4:P2}" -f $promotionBest.CandidateId, $promotionBest.Score, $promotionBaseline.Score, $margin, $PromoteScoreMargin)
        if ($promotionDecision.Reasons.Count -gt 0) {
            Write-Host ("  gates: {0}" -f ($promotionDecision.Reasons -join '; '))
        }
    }
}

$Script:RestoreConfigPath = ''
$paretoArchive = Save-ParetoArchive -Results $results -SessionDir $sessionDir

$summary = [pscustomobject]@{
    Session = $sessionTag
    RunDir = $sessionDir
    CreatedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    BaseSeed = $BaseSeed
    MapName = $MapName
    Candidates = $Candidates
    GamesPerCandidate = $GamesPerCandidate
    ParallelInstances = $ParallelInstances
    TargetSpeed = $TargetSpeed
    Promoted = $promoted
    NoPromote = [bool]$NoPromote
    PromoteScoreMargin = $PromoteScoreMargin
    RequireMassRatioGain = $RequireMassRatioGain
    MinMassRatioAbsolute = $MinMassRatioAbsolute
    MaxMassRatioRegression = $MaxMassRatioRegression
    MinAvgGameTime = $MinAvgGameTime
    MaxSurvivalRegression = $MaxSurvivalRegression
    RetestTop = $RetestTop
    RetestGames = $RetestGames
    RetestMaps = Get-RetestMapList
    AdaptiveMutationSources = $adaptiveHints.SourceCount
    DbHistorySources = $dbHistoryCandidates.Count
    DbAdaptiveDirections = $dbAdaptiveHints.Directions.Count
    FailureAwareMutation = $true
    Version = if ($buildMeta) { $buildMeta.Version } else { $null }
    Fingerprint = if ($buildMeta) { $buildMeta.Fingerprint } else { $null }
    GitCommit = if ($buildMeta) { $buildMeta.GitCommit } else { $null }
    BaselineScore = $promotionBaseline.Score
    BaselineAvgGameTime = $promotionBaseline.AvgGameTime
    BaselineAvgMassRatio = $promotionBaseline.AvgMassRatio
    BaselinePrimaryFailureClass = $promotionBaseline.PrimaryFailureClass
    BestCandidate = $promotionBest.CandidateId
    BestScore = $promotionBest.Score
    BestAvgGameTime = $promotionBest.AvgGameTime
    BestAvgMassRatio = $promotionBest.AvgMassRatio
    BestPrimaryFailureClass = $promotionBest.PrimaryFailureClass
    Margin = [math]::Round($margin, 5)
    PromotionAllowed = [bool]$promotionDecision.Allowed
    PromotionBlockedReasons = $promotionDecision.Reasons
    ParetoArchive = $paretoArchive | Select-Object Role, CandidateId, Score, AvgMassRatio, AvgGameTime, PrimaryFailureClass, ConfigPath
    Results = $results | Select-Object CandidateId, ParentCandidateId, ParentSource, ParentSessionId, ParentFailureClass, Score, Games, WinRate, AvgGameTime, AvgMassRatio, PrimaryFailureClass, RuntimeClean
}
$summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $sessionDir 'session-summary.json') -Encoding UTF8
$results | Select-Object CandidateId, ParentCandidateId, ParentSource, ParentSessionId, ParentFailureClass, Score, Games, WinRate, AvgGameTime, AvgMassRatio, PrimaryFailureClass, RuntimeClean |
    Export-Csv -Path (Join-Path $sessionDir 'candidate-scores.csv') -NoTypeInformation -Encoding UTF8
Write-SessionReport -Path (Join-Path $sessionDir 'session-report.md') -Summary $summary -Results $results

$sessionSummaryPath = Join-Path $sessionDir 'session-summary.json'

if ($UseDatabase -and -not $DryRun -and (Test-Path -LiteralPath $DbIngestScript)) {
    try {
        $dbArgs = @(
            '-ExecutionPolicy', 'Bypass',
            '-File', $DbIngestScript,
            '-SessionSummaryPath', $sessionSummaryPath,
            '-StartDb',
            '-ProjectName', $DbProjectName
        )
        if (-not [string]::IsNullOrWhiteSpace($DbComposeFile)) { $dbArgs += @('-ComposeFile', $DbComposeFile) }
        if (-not [string]::IsNullOrWhiteSpace($DbEnvFile)) { $dbArgs += @('-EnvFile', $DbEnvFile) }
        if ($DbInitSchema) {
            $dbArgs += '-InitSchema'
        }
        & powershell @dbArgs
        if ($LASTEXITCODE -ne 0) {
            Write-Warning 'Autotune DB ingestion failed after session completion.'
        }
    } catch {
        Write-Warning ("Autotune DB ingestion failed: {0}" -f $_)
    }
}

if ($RestoreOriginalOnExit -and -not $DryRun -and (Test-Path -LiteralPath $baselineRawPath)) {
    Copy-Item -LiteralPath $baselineRawPath -Destination $ConfigPath -Force
    Invoke-ReleaseSync
    Write-Host "RestoreOriginalOnExit set; restored baseline config from $baselineRawPath"
}

Write-Host "Session summary: $sessionSummaryPath"
Write-Host "Session report: $(Join-Path $sessionDir 'session-report.md')"
