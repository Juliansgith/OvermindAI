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
    [double]$MaxMassRatioRegression = 0,
    [double]$MaxSurvivalRegression = 0.25,
    [int]$RetestTop = 0,
    [int]$RetestGames = 0,
    [string]$RunRoot = '',
    [string]$ChampionDir = '',
    [switch]$SkipBaseline,
    [switch]$NoPromote,
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
$AutorunRoot = 'C:\Program Files (x86)\Steam\steamapps\common\Supreme Commander Forged Alliance\autorun'
$StartScript = Join-Path $AutorunRoot 'bin\start_autorun_parallel.ps1'
$AnalyzeScript = Join-Path $AutorunRoot 'bin\analyze_autorun_logs.ps1'
$KpiScript = Join-Path $AutorunRoot 'bin\extract_autorun_kpis.ps1'

if ([string]::IsNullOrWhiteSpace($RunRoot)) {
    $RunRoot = Join-Path $RepoRoot 'autotune\runs'
}

if ($Candidates -lt 1) { throw 'Candidates must be at least 1.' }
if ($GamesPerCandidate -lt 1) { throw 'GamesPerCandidate must be at least 1.' }
if ($ParallelInstances -lt 1) { throw 'ParallelInstances must be at least 1.' }
if ($TargetSpeed -lt 1) { throw 'TargetSpeed must be at least 1.' }
if ($MutationRate -lt 0 -or $MutationRate -gt 1) { throw 'MutationRate must be between 0 and 1.' }
if ($RequireMassRatioGain -lt 0) { throw 'RequireMassRatioGain must be zero or higher.' }
if ($MaxMassRatioRegression -lt 0) { throw 'MaxMassRatioRegression must be zero or higher.' }
if ($MaxSurvivalRegression -lt 0 -or $MaxSurvivalRegression -gt 1) { throw 'MaxSurvivalRegression must be between 0 and 1.' }
if ($RetestTop -lt 0) { throw 'RetestTop must be zero or higher.' }
if ($RetestGames -lt 0) { throw 'RetestGames must be zero or higher.' }

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
    }
}

function Get-DefaultTuneConfig {
    $cfg = [ordered]@{
        Version = 2
        CandidateId = 'baseline'
        ParentCandidateId = 'manual'
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

function Get-SafeName {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) {
        return 'unknown'
    }
    return ($Value -replace '[^A-Za-z0-9_.-]', '-')
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
        [System.Random]$Random
    )

    $specs = New-TuneSpecs
    $cfg = [ordered]@{}
    foreach ($key in $Parent.Keys) {
        $cfg[$key] = $Parent[$key]
    }

    $cfg.Version = 2
    $cfg.CandidateId = "candidate-$CandidateIndex"
    $cfg.ParentCandidateId = [string]($Parent.CandidateId)
    $cfg.GeneratedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $cfg.GeneratedBy = 'run_economy_autotune.ps1'
    $cfg.Score = 0
    $cfg.Games = $GamesPerCandidate
    $cfg.MapName = $MapName

    $mutated = 0
    foreach ($name in $specs.Keys) {
        $spec = $specs[$name]
        $value = To-Double $cfg[$name]
        if ($Random.NextDouble() -le $MutationRate) {
            $direction = if ($Random.NextDouble() -lt 0.5) { -1 } else { 1 }
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
        [int]$SeedBase
    )

    $logDir = Join-Path $CandidateDir 'logs'
    Ensure-Directory $logDir

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
            '-MapName', $MapName,
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
        if ($raw.ModularError -or $raw.RuntimeFallback -or (To-Int $run.errors) -gt 0) {
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
        [int]$GamesOverride = 0
    )

    $candidateDir = Join-Path $SessionDir $CandidateId
    Ensure-Directory $candidateDir
    $runGames = if ($GamesOverride -gt 0) { $GamesOverride } else { $GamesPerCandidate }
    $Config.CandidateId = $CandidateId
    $Config.GeneratedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $Config.Games = $runGames
    $Config.MapName = $MapName

    $candidateConfigPath = Join-Path $candidateDir 'AutoTuneConfig.lua'
    Write-TuneConfig -Config $Config -Path $candidateConfigPath

    if (-not $DryRun) {
        Write-TuneConfig -Config $Config -Path $ConfigPath
        Invoke-ReleaseSync
    } else {
        Write-Host "[DRYRUN] generated candidate config: $candidateConfigPath"
    }

    $logDir = Invoke-AutorunBatch -CandidateId $CandidateId -CandidateDir $candidateDir -Games $runGames -SeedBase $SeedBase
    [void](Invoke-Analysis -CandidateDir $candidateDir -LogDir $logDir)
    $result = Score-Candidate -CandidateId $CandidateId -CandidateDir $candidateDir -Config $Config
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
    if ([double]$Candidate.AvgMassRatio -lt $requiredMassRatio) {
        $reasons += ("mass ratio {0} below required {1}" -f $Candidate.AvgMassRatio, [math]::Round($requiredMassRatio, 4))
    }

    $minimumGameTime = [double]$Baseline.AvgGameTime * (1.0 - $MaxSurvivalRegression)
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

Ensure-Directory $RunRoot
$sessionTag = Get-Date -Format 'yyyyMMdd-HHmmss'
$sessionDir = Join-Path $RunRoot $sessionTag
Ensure-Directory $sessionDir

if ($BaseSeed -le 0) {
    $BaseSeed = Get-Random -Minimum 1 -Maximum 2000000000
}
$rng = [System.Random]::new($BaseSeed)
$baselineConfig = Read-TuneConfig -Path $ConfigPath
$baselineConfig.CandidateId = if ($baselineConfig.CandidateId) { [string]$baselineConfig.CandidateId } else { 'baseline' }
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
        Runs = @()
        Config = $baselineConfig
    }
}

$best = $results[0]
for ($i = 1; $i -le $Candidates; $i++) {
    $parent = $best.Config
    $candidateConfig = New-MutatedConfig -Parent $parent -CandidateIndex $i -Random $rng
    $candidateSeed = $BaseSeed + ($i * 100000)
    $candidateResult = Run-Candidate -CandidateId ("candidate-$i") -Config $candidateConfig -SessionDir $sessionDir -SeedBase $candidateSeed
    $results += $candidateResult
    if ($candidateResult.RuntimeClean -and $candidateResult.Score -gt $best.Score) {
        $best = $candidateResult
    }
}

$baseline = @($results | Where-Object { $_.CandidateId -eq 'baseline' } | Select-Object -First 1)[0]
$promotionBaseline = $baseline
$promotionBest = $best
$retestResults = @()

if ($RetestTop -gt 0 -and -not $DryRun) {
    $retestGamesActual = if ($RetestGames -gt 0) { $RetestGames } else { $GamesPerCandidate }
    $topCandidates = @($results |
        Where-Object { $_.CandidateId -ne 'baseline' -and $_.RuntimeClean } |
        Sort-Object -Property Score -Descending |
        Select-Object -First $RetestTop)

    if ($topCandidates.Count -gt 0) {
        Write-Host ("Retesting top {0} candidate(s), games={1}" -f $topCandidates.Count, $retestGamesActual)
        $retestSeed = $BaseSeed + 900000000
        $baselineRetestConfig = Copy-TuneConfig -Config $baselineConfig
        $promotionBaseline = Run-Candidate -CandidateId 'retest-baseline' -Config $baselineRetestConfig -SessionDir $sessionDir -SeedBase $retestSeed -GamesOverride $retestGamesActual
        $retestResults += $promotionBaseline

        $candidateIndex = 0
        foreach ($candidate in $topCandidates) {
            $candidateIndex += 1
            $candidateConfig = Copy-TuneConfig -Config $candidate.Config
            $candidateConfig.ParentCandidateId = [string]$candidate.CandidateId
            $retestResult = Run-Candidate -CandidateId ("retest-{0}" -f (Get-SafeName -Value ([string]$candidate.CandidateId))) -Config $candidateConfig -SessionDir $sessionDir -SeedBase ($retestSeed + ($candidateIndex * 100000)) -GamesOverride $retestGamesActual
            $retestResults += $retestResult
        }

        $results += $retestResults
        $promotionBest = @($retestResults |
            Where-Object { $_.CandidateId -ne 'retest-baseline' -and $_.RuntimeClean } |
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

$summary = [pscustomobject]@{
    Session = $sessionTag
    RunDir = $sessionDir
    BaseSeed = $BaseSeed
    MapName = $MapName
    GamesPerCandidate = $GamesPerCandidate
    ParallelInstances = $ParallelInstances
    TargetSpeed = $TargetSpeed
    Promoted = $promoted
    NoPromote = [bool]$NoPromote
    PromoteScoreMargin = $PromoteScoreMargin
    RequireMassRatioGain = $RequireMassRatioGain
    MaxMassRatioRegression = $MaxMassRatioRegression
    MaxSurvivalRegression = $MaxSurvivalRegression
    RetestTop = $RetestTop
    RetestGames = $RetestGames
    BaselineScore = $promotionBaseline.Score
    BaselineAvgGameTime = $promotionBaseline.AvgGameTime
    BaselineAvgMassRatio = $promotionBaseline.AvgMassRatio
    BestCandidate = $promotionBest.CandidateId
    BestScore = $promotionBest.Score
    BestAvgGameTime = $promotionBest.AvgGameTime
    BestAvgMassRatio = $promotionBest.AvgMassRatio
    Margin = [math]::Round($margin, 5)
    PromotionAllowed = [bool]$promotionDecision.Allowed
    PromotionBlockedReasons = $promotionDecision.Reasons
    Results = $results | Select-Object CandidateId, Score, Games, WinRate, AvgGameTime, AvgMassRatio, RuntimeClean
}
$summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $sessionDir 'session-summary.json') -Encoding UTF8
$results | Select-Object CandidateId, Score, Games, WinRate, AvgGameTime, AvgMassRatio, RuntimeClean |
    Export-Csv -Path (Join-Path $sessionDir 'candidate-scores.csv') -NoTypeInformation -Encoding UTF8

Write-Host "Session summary: $(Join-Path $sessionDir 'session-summary.json')"
