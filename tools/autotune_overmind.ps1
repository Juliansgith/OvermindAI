param(
    [string]$LogPath,
    [string]$LogsDir = "$env:APPDATA\Forged Alliance Forever\logs",
    [string]$OutputPath = "$PSScriptRoot\..\lua\AI\Overmind\AutoTuneConfig.lua"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-LatestLogPath {
    param([string]$Directory)
    $latest = Get-ChildItem -Path $Directory -Filter 'game_*.log' -File |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if (-not $latest) {
        throw "No game logs found in '$Directory'."
    }
    return $latest.FullName
}

function Get-CheckpointTable {
    param([string]$LogText)

    $out = @{}
    $regex = [regex]'\*OVERMIND CHECKPOINT A\d+ t=(?<t>\d+)s fac=(?<fac>\d+) idleFac=(?<idle>\d+)(?: qdef=(?<qdef>\d+) qratio=(?<qratio>[0-9.]+))?(?: harL=(?<harL>\d+)\((?<harLe>\d+)\) harA=(?<harA>\d+)\((?<harAe>\d+)\))? eng=(?<eng>\d+) baseEng=(?<base>\d+) def=(?<def>\d+) acuDist=(?<ad>[0-9.]+) acuEsc=(?<ae>\d+) risk=(?<risk>[0-9.]+) map=(?<map>[0-9.]+)(?: stagn=(?<stagn>[0-9.]+) rf=(?<rf>\d+) rs=(?<rs>\d+) re=(?<re>\d+) rd=(?<rd>\d+))?'
    foreach ($m in $regex.Matches($LogText)) {
        $time = [int]$m.Groups['t'].Value
        $out[$time] = [ordered]@{
            Fac = [int]$m.Groups['fac'].Value
            IdleFac = [int]$m.Groups['idle'].Value
            QueueDeficit = if ($m.Groups['qdef'].Success) { [int]$m.Groups['qdef'].Value } else { 0 }
            QueueDeficitRatio = if ($m.Groups['qratio'].Success) { [double]$m.Groups['qratio'].Value } else { 0.0 }
            HarassLand = if ($m.Groups['harL'].Success) { [int]$m.Groups['harL'].Value } else { 0 }
            HarassLandEnemies = if ($m.Groups['harLe'].Success) { [int]$m.Groups['harLe'].Value } else { 0 }
            HarassAir = if ($m.Groups['harA'].Success) { [int]$m.Groups['harA'].Value } else { 0 }
            HarassAirEnemies = if ($m.Groups['harAe'].Success) { [int]$m.Groups['harAe'].Value } else { 0 }
            Eng = [int]$m.Groups['eng'].Value
            BaseEng = [int]$m.Groups['base'].Value
            Def = [int]$m.Groups['def'].Value
            AcuDist = [double]$m.Groups['ad'].Value
            AcuEsc = [int]$m.Groups['ae'].Value
            Risk = [double]$m.Groups['risk'].Value
            Map = [double]$m.Groups['map'].Value
            Stagn = if ($m.Groups['stagn'].Success) { [double]$m.Groups['stagn'].Value } else { 0.0 }
            RF = if ($m.Groups['rf'].Success) { [int]$m.Groups['rf'].Value } else { 0 }
            RS = if ($m.Groups['rs'].Success) { [int]$m.Groups['rs'].Value } else { 0 }
            RE = if ($m.Groups['re'].Success) { [int]$m.Groups['re'].Value } else { 0 }
            RD = if ($m.Groups['rd'].Success) { [int]$m.Groups['rd'].Value } else { 0 }
        }
    }

    return $out
}

function Get-OvermindEngineerLosses {
    param([string]$LogText)

    $regex = [regex]'(?s)"name":"[^"]*\(AI: Overmind\)".+?"engineer":\{"lost":(\d+)'
    $m = $regex.Match($LogText)
    if ($m.Success) {
        return [int]$m.Groups[1].Value
    }
    return 0
}

function Get-OvermindDefeatTime {
    param([string]$LogText)

    $regex = [regex]'(?s)"type":"AI".+?"Defeated":([0-9.]+).+?"name":"[^"]*\(AI: Overmind\)"'
    $m = $regex.Match($LogText)
    if ($m.Success) {
        return [double]$m.Groups[1].Value
    }
    return $null
}

function Get-ScoutRecoverySignal {
    param(
        [string]$LogText,
        [hashtable]$Checkpoints
    )

    $score = 0
    foreach ($cp in $Checkpoints.Values) {
        if ($cp.RS -ge 1) {
            $score += 1
        }
    }

    $watchdogRegex = [regex]'\*OVERMIND WATCHDOG .* flags=([A-Z\-]+)'
    foreach ($m in $watchdogRegex.Matches($LogText)) {
        if ($m.Groups[1].Value -like '*S*') {
            $score += 1
        }
    }

    return $score
}

function Clamp-Number {
    param(
        [double]$Value,
        [double]$Min,
        [double]$Max
    )

    if ($Value -lt $Min) { return $Min }
    if ($Value -gt $Max) { return $Max }
    return $Value
}

if (-not $LogPath) {
    $LogPath = Get-LatestLogPath -Directory $LogsDir
}

if (-not (Test-Path -LiteralPath $LogPath)) {
    throw "Log file not found: $LogPath"
}

$logText = Get-Content -LiteralPath $LogPath -Raw
$checkpoints = Get-CheckpointTable -LogText $logText
$engineerLosses = Get-OvermindEngineerLosses -LogText $logText
$defeatTime = Get-OvermindDefeatTime -LogText $logText
$scoutSignal = Get-ScoutRecoverySignal -LogText $logText -Checkpoints $checkpoints

$factoryFloorEarly = 3
$factoryFloorMid = 4
$factoryFloorLate = 6
$factoryRecoveryStagnation = 85
$scoutMinCount = 3
$acuOpeningMaxDistance = 20
$acuMidMaxDistance = 36
$acuLateMaxDistance = 60
$safeExpandHotspotCapBias = 0.0
$baseEngineerFloorMin = 3

if ($checkpoints.ContainsKey(240)) {
    $cp = $checkpoints[240]
    if ($cp.Fac -lt 3 -or $cp.Stagn -gt 70) {
        $factoryFloorEarly = 4
        $factoryRecoveryStagnation = 72
    }
    if ($cp.BaseEng -lt 3) {
        $baseEngineerFloorMin = 4
    }
}

if ($checkpoints.ContainsKey(480)) {
    $cp = $checkpoints[480]
    if ($cp.Fac -lt 4 -or $cp.IdleFac -ge 2) {
        $factoryFloorMid = 5
        $factoryRecoveryStagnation = [Math]::Min($factoryRecoveryStagnation, 68)
    }
    if ($cp.Stagn -gt 100) {
        $factoryFloorMid = [Math]::Max($factoryFloorMid, 6)
        $factoryRecoveryStagnation = [Math]::Min($factoryRecoveryStagnation, 62)
    }
    if (($cp.HarassAir -ge 1 -and $cp.HarassAirEnemies -ge 2) -or ($cp.HarassLand -ge 1 -and $cp.HarassLandEnemies -ge 3)) {
        $scoutMinCount = [Math]::Max($scoutMinCount, 3)
        $baseEngineerFloorMin = [Math]::Max($baseEngineerFloorMin, 4)
    }
}

if ($checkpoints.ContainsKey(720)) {
    $cp = $checkpoints[720]
    if ($cp.Fac -lt 6) {
        $factoryFloorLate = 7
    }
}

if ($defeatTime -ne $null -and $defeatTime -lt 900) {
    $acuOpeningMaxDistance -= 6
    $acuMidMaxDistance -= 8
    $acuLateMaxDistance -= 10
}

if ($engineerLosses -ge 10) {
    $safeExpandHotspotCapBias -= 1.0
    $baseEngineerFloorMin = [Math]::Max($baseEngineerFloorMin, 4)
}
if ($engineerLosses -ge 16) {
    $safeExpandHotspotCapBias -= 0.8
    $baseEngineerFloorMin = [Math]::Max($baseEngineerFloorMin, 5)
}

if ($scoutSignal -ge 3) {
    $scoutMinCount = 3
}
if ($scoutSignal -ge 6) {
    $scoutMinCount = 4
}

$acuOpeningMaxDistance = [int](Clamp-Number -Value $acuOpeningMaxDistance -Min 16 -Max 70)
$acuMidMaxDistance = [int](Clamp-Number -Value $acuMidMaxDistance -Min 24 -Max 100)
$acuLateMaxDistance = [int](Clamp-Number -Value $acuLateMaxDistance -Min 35 -Max 130)
$factoryRecoveryStagnation = [int](Clamp-Number -Value $factoryRecoveryStagnation -Min 45 -Max 220)
$safeExpandHotspotCapBias = [Math]::Round((Clamp-Number -Value $safeExpandHotspotCapBias -Min -4 -Max 4), 2)

$outputDir = Split-Path -Parent $OutputPath
if (-not (Test-Path -LiteralPath $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
}

$generatedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
$sourceEscaped = $LogPath.Replace('\', '/')

$lua = @"
return {
    Version = 1,
    SourceLog = '$sourceEscaped',
    GeneratedAt = '$generatedAt',

    FactoryFloorEarly = $factoryFloorEarly,
    FactoryFloorMid = $factoryFloorMid,
    FactoryFloorLate = $factoryFloorLate,
    FactoryRecoveryStagnation = $factoryRecoveryStagnation,

    ScoutMinCount = $scoutMinCount,

    ACUOpeningMaxDistance = $acuOpeningMaxDistance,
    ACUMidMaxDistance = $acuMidMaxDistance,
    ACULateMaxDistance = $acuLateMaxDistance,

    SafeExpandHotspotCapBias = $safeExpandHotspotCapBias,
    BaseEngineerFloorMin = $baseEngineerFloorMin,
}
"@

Set-Content -LiteralPath $OutputPath -Value $lua -Encoding ASCII

Write-Output "Auto-tune config updated:"
Write-Output "  Log: $LogPath"
Write-Output "  Output: $OutputPath"
Write-Output "  Floors: $factoryFloorEarly/$factoryFloorMid/$factoryFloorLate"
Write-Output "  ScoutMin: $scoutMinCount"
Write-Output "  ACU leash: $acuOpeningMaxDistance/$acuMidMaxDistance/$acuLateMaxDistance"
Write-Output "  Risk bias: $safeExpandHotspotCapBias"
