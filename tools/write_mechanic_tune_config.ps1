param(
    [string]$ConfigJson = '',
    [string]$ConfigPath = '',
    [string]$OutputPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $repoRoot 'lua\AI\Overmind\MechanicTuneConfig.lua'
}

function Get-DefaultConfig {
    return [ordered]@{
        Version = 1
        ProfileId = 'baseline'
        GeneratedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        GeneratedBy = 'write_mechanic_tune_config.ps1'
        ForceSideEscortAABias = 0
        ForceACUEmergencyThreatScaleBias = 0
        ForceACUEmergencyBaseNeedBias = 0
        ForceACUEmergencyHoldBias = 0
        ForceACUEmergencyCrisisShareBias = 0
        CombatIndirectEscortBias = 0
        CombatHeavyEscortBias = 0
        CombatAASupportBias = 0
        EngineerRepairThreatBias = 0
        EngineerRepairDistanceBias = 0
        EngineerRepairRouteRiskBias = 0
        EngineerACURepairPriorityBias = 0
        EngineerACURepairThreatBias = 0
        EngineerACURepairDistanceBias = 0
        EngineerACURepairHealthBias = 0
    }
}

function Format-LuaValue {
    param($Value)

    if ($Value -is [string]) {
        return "'" + ($Value.Replace('\', '/').Replace("'", "\\'")) + "'"
    }
    if ($Value -is [double] -or $Value -is [float] -or $Value -is [decimal]) {
        return ([double]$Value).ToString([Globalization.CultureInfo]::InvariantCulture)
    }
    return [string]$Value
}

$cfg = Get-DefaultConfig
$sourceText = ''
if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) {
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw "ConfigPath not found: $ConfigPath"
    }
    $sourceText = Get-Content -LiteralPath $ConfigPath -Raw
} elseif (-not [string]::IsNullOrWhiteSpace($ConfigJson)) {
    if (Test-Path -LiteralPath $ConfigJson) {
        $sourceText = Get-Content -LiteralPath $ConfigJson -Raw
    } else {
        $sourceText = $ConfigJson
    }
}

if (-not [string]::IsNullOrWhiteSpace($sourceText)) {
    $incoming = $sourceText | ConvertFrom-Json
    foreach ($prop in $incoming.PSObject.Properties) {
        $cfg[$prop.Name] = $prop.Value
    }
}

$lines = @()
$lines += 'Config = {'
foreach ($key in $cfg.Keys) {
    $lines += "    $key = $(Format-LuaValue -Value $cfg[$key]),"
}
$lines += '}'

Set-Content -LiteralPath $OutputPath -Value ($lines -join [Environment]::NewLine) -Encoding ASCII
Write-Host "Mechanic tune config written: $OutputPath"
