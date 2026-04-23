param(
    [string]$LogsPath = (Join-Path $PSScriptRoot '..\autotune\runs\**\logs\*.log'),
    [string]$OutputDir = (Join-Path $PSScriptRoot '..\autotune\analysis\actions\latest'),
    [int[]]$Windows = @(30, 60, 120, 300)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

function Parse-JsonStatsPayload {
    param([string]$Payload)

    if ([string]::IsNullOrWhiteSpace($Payload)) {
        return $null
    }

    $clean = ($Payload.Trim() -replace ',\s*$', '')
    try {
        return ($clean | ConvertFrom-Json -ErrorAction Stop)
    } catch {
        return $null
    }
}

function New-State {
    return [ordered]@{
        t = 0.0
        mex_ready = 0
        mex_total = 0
        fac_total = 0
        fac_target_total = 0
        idle_factories = 0
        engineer_count = 0
        engineer_need = 0
        engineer_demand = 0
        reclaim_mass = 0.0
        reclaim_stagnation = 0.0
        map_control = 0.0
        force_land = 0
        force_guard = 0
        force_main = 0
        force_outer = 0
        force_raid = 0
        force_acu = 0
        force_acuint = 0
        strategy_theater = 'none'
        strategy_dir = 'none'
        strategy_focus = 'none'
        strategy_raid = 'none'
        strategy_outer = 0
        strategy_reclaim = 0.0
        strategy_tempo = 'none'
        strategy_conf = 0.0
        prod_mode = 'none'
        prod_obj = 'none'
        prod_conf = 0.0
        upgrade_obj = 'none'
        upgrade_reason = 'none'
        upgrade_cap = 0
        upgrade_inflight = 0
        upgrade_fac_state = 'none'
        factory_mode = 'none'
        factory_ready = 0
        factory_empty = 0
        factory_qtarget = 0
        factory_issued = 0
        factory_growth = 0
        engineer_expand = 0
        engineer_field = 0
        engineer_quota = 0
        engineer_block = 'none'
        engineer_base_need = 0
        engineer_fac_task = 'none'
        engineer_struct_task = 'none'
        engineer_acu_repair = 0
        engineer_acu_need = 0
        macro_phase = 'none'
        macro_reason = 'none'
        goal = 'none'
        posture = 'none'
        pivot = 'none'
        aggression = 0.0
        acu_action = 'none'
        acu_dist = 0.0
        acu_hp = 1.0
        prod_struct_shield = 0
        prod_struct_tmd = 0
        prod_struct_home = 0
    }
}

function Copy-State {
    param([hashtable]$State)

    $copy = [ordered]@{}
    foreach ($key in $State.Keys) {
        $copy[$key] = $State[$key]
    }
    return $copy
}

function Add-TimelinePoint {
    param(
        [System.Collections.ArrayList]$Timeline,
        [hashtable]$State
    )

    $snapshot = Copy-State -State $State
    $null = $Timeline.Add([pscustomobject]$snapshot)
}

function Get-StateAtTime {
    param(
        [array]$Timeline,
        [double]$Target
    )

    if (-not $Timeline -or $Timeline.Count -eq 0) {
        return $null
    }

    $chosen = $null
    foreach ($row in $Timeline) {
        if ((To-Double $row.t) -le $Target) {
            $chosen = $row
        } else {
            break
        }
    }

    if ($null -ne $chosen) {
        return $chosen
    }

    return $Timeline[0]
}

function Get-EventReward {
    param(
        [double]$DeltaMex,
        [double]$DeltaFactories,
        [double]$DeltaReclaimMass,
        [double]$DeltaMapControl,
        [double]$DeltaIdleFactories,
        [double]$DeltaEngineers,
        [double]$DeltaGuard,
        [double]$DeltaMain,
        [double]$DeltaOuter,
        [double]$DeltaRaid,
        [bool]$SurvivedWindow,
        [bool]$GameEndedWithinWindow,
        [double]$FinalMassRatio
    )

    $reward = 0.0
    $reward += $DeltaMex * 140.0
    $reward += $DeltaFactories * 60.0
    $reward += $DeltaReclaimMass * 0.12
    $reward += $DeltaMapControl * 900.0
    $reward += (-1.0 * $DeltaIdleFactories) * 18.0
    $reward += $DeltaEngineers * 10.0
    $reward += $DeltaGuard * 4.0
    $reward += $DeltaMain * 12.0
    $reward += $DeltaOuter * 20.0
    $reward += $DeltaRaid * 14.0

    if (-not $SurvivedWindow) {
        $reward -= 1200.0
    }
    if ($GameEndedWithinWindow) {
        $reward -= 800.0
    }
    if ($FinalMassRatio -gt 0) {
        $reward += ($FinalMassRatio - 0.25) * 220.0
    }

    return [math]::Round($reward, 2)
}

function Add-EventRow {
    param(
        [System.Collections.ArrayList]$Events,
        [string]$LogName,
        [string]$RunTag,
        [int]$Instance,
        [int]$EventIndex,
        [string]$Subsystem,
        [string]$ActionType,
        [string]$ActionKey,
        [string]$ActionValue,
        [double]$EventTime,
        [hashtable]$State,
        [string]$Signature,
        [string]$RawLine
    )

    $stateJson = (Copy-State -State $State | ConvertTo-Json -Depth 6 -Compress)
    $rawJson = (@{
        line = $RawLine
        signature = $Signature
    } | ConvertTo-Json -Depth 4 -Compress)

    $null = $Events.Add([pscustomobject]@{
        log_name = $LogName
        run_tag = $RunTag
        instance = $Instance
        event_index = $EventIndex
        subsystem = $Subsystem
        action_type = $ActionType
        action_key = $ActionKey
        action_value = $ActionValue
        event_time = [math]::Round($EventTime, 2)
        mex_ready = To-Int $State.mex_ready
        fac_total = To-Int $State.fac_total
        reclaim_mass = [math]::Round((To-Double $State.reclaim_mass), 2)
        map_control = [math]::Round((To-Double $State.map_control), 4)
        idle_factories = To-Int $State.idle_factories
        engineer_count = To-Int $State.engineer_count
        force_guard = To-Int $State.force_guard
        force_main = To-Int $State.force_main
        force_outer = To-Int $State.force_outer
        force_raid = To-Int $State.force_raid
        strategy_dir = [string]$State.strategy_dir
        production_mode = [string]$State.prod_mode
        state_json = $stateJson
        raw_event = $rawJson
    })
}

function Get-LogIdentity {
    param([System.IO.FileInfo]$Log)

    $runTag = $null
    $instance = $null
    if ($Log.BaseName -match '^autorun-(\d{8}-\d{6})-i(\d+)$') {
        $runTag = $Matches[1]
        $instance = [int]$Matches[2]
    }

    return [pscustomobject]@{
        RunTag = $runTag
        Instance = $instance
    }
}

function Get-FinalMassRatio {
    param([object]$JsonStats)

    if ($null -eq $JsonStats -or $null -eq $JsonStats.stats) {
        return 0.0
    }

    $statsRows = @($JsonStats.stats)
    $om = @($statsRows | Where-Object { ([string]$_.name).ToLowerInvariant() -match 'overmind' } | Select-Object -First 1)
    $opp = @($statsRows | Where-Object { ([string]$_.name).ToLowerInvariant() -match 'm27|m28' } | Select-Object -First 1)
    if ($om.Count -le 0 -or $opp.Count -le 0) {
        return 0.0
    }

    $oppMass = [math]::Max(1.0, (To-Double $opp[0].resources.massin.total))
    return [math]::Round(((To-Double $om[0].resources.massin.total) / $oppMass), 4)
}

$logs = @(Get-ChildItem -Path $LogsPath -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime)
if ($logs.Count -eq 0) {
    Write-Host "No log files found for pattern: $LogsPath"
    exit 0
}

Ensure-Directory -Path $OutputDir

$eventRows = [System.Collections.ArrayList]::new()
$outcomeRows = [System.Collections.ArrayList]::new()
$timelineRows = [System.Collections.ArrayList]::new()

foreach ($log in $logs) {
    $identity = Get-LogIdentity -Log $log
    $state = New-State
    $timeline = [System.Collections.ArrayList]::new()
    $events = [System.Collections.ArrayList]::new()
    $signatures = @{}
    $lastTime = 0.0
    $eventIndex = 0
    $jsonPayload = $null
    $gameTimeSeconds = $null

    foreach ($line in [System.IO.File]::ReadLines($log.FullName)) {
        if (-not $jsonPayload -and $line -match 'GpgNetSend\s+JsonStats\s+(\{.*)$') {
            $jsonPayload = $Matches[1].Trim()
            continue
        }

        if ($line -match 'Session time:\s*([0-9:]+)\s*Game time:\s*([0-9:]+)') {
            $tokens = $Matches[2].Split(':')
            if ($tokens.Length -eq 3) {
                $gameTimeSeconds = ([int]$tokens[0] * 3600) + ([int]$tokens[1] * 60) + [int]$tokens[2]
            }
        }

        $matched = $false
        $t = $lastTime

        if ($line -match '\*OVERMIND STRAT A\d+ t=([0-9.]+) theater=([^ ]+) dir=([^ ]+) raid=([^:]+):([-0-9.]+) tempo=([^ ]+) tb=([-0-9.]+) tech=([-0-9.]+) air=(\d+) greed=(\d+) spam=(\d+) outer=(\d+) reclaim=([-0-9.]+) focus=([^ ]+) conf=([-0-9.]+) map=([-0-9.]+) press=([-0-9.]+)/([-0-9.]+)/([-0-9.]+)') {
            $t = To-Double $Matches[1]
            $lastTime = $t
            $state.t = $t
            $state.strategy_theater = $Matches[2]
            $state.strategy_dir = $Matches[3]
            $state.strategy_raid = $Matches[4]
            $state.strategy_tempo = $Matches[6]
            $state.strategy_outer = To-Int $Matches[12]
            $state.strategy_reclaim = To-Double $Matches[13]
            $state.strategy_focus = $Matches[14]
            $state.strategy_conf = To-Double $Matches[15]
            $state.map_control = To-Double $Matches[16]
            Add-TimelinePoint -Timeline $timeline -State $state
            $signature = "theater=$($state.strategy_theater)|dir=$($state.strategy_dir)|raid=$($state.strategy_raid)|tempo=$($state.strategy_tempo)|focus=$($state.strategy_focus)|outer=$($state.strategy_outer)"
            if ($signatures['strategy'] -ne $signature) {
                $eventIndex += 1
                Add-EventRow -Events $events -LogName $log.Name -RunTag $identity.RunTag -Instance $identity.Instance -EventIndex $eventIndex -Subsystem 'strategy' -ActionType 'plan_shift' -ActionKey 'theater_dir_focus' -ActionValue ("{0}:{1}:{2}" -f $state.strategy_theater, $state.strategy_dir, $state.strategy_focus) -EventTime $t -State $state -Signature $signature -RawLine $line
                $signatures['strategy'] = $signature
            }
            $matched = $true
        } elseif ($line -match '\*OVERMIND PRODDIR MODE A\d+ t=([0-9.]+) mode=([^ ]+) score=([-0-9.]+) prev=([^ ]+) prevScore=([-0-9.]+)') {
            $t = To-Double $Matches[1]
            $lastTime = $t
            $state.t = $t
            $state.prod_mode = $Matches[2]
            Add-TimelinePoint -Timeline $timeline -State $state
            $signature = "mode=$($state.prod_mode)"
            if ($signatures['production-mode'] -ne $signature) {
                $eventIndex += 1
                Add-EventRow -Events $events -LogName $log.Name -RunTag $identity.RunTag -Instance $identity.Instance -EventIndex $eventIndex -Subsystem 'production' -ActionType 'mode_shift' -ActionKey 'mode' -ActionValue $state.prod_mode -EventTime $t -State $state -Signature $signature -RawLine $line
                $signatures['production-mode'] = $signature
            }
            $matched = $true
        } elseif ($line -match '\*OVERMIND PRODDIR A\d+ t=([0-9.]+) mode=([^ ]+) obj=([^/ ]+)/([^ ]+) conf=([-0-9.]+) debt=([-0-9.]+) fac=(\d+)/(\d+)/(\d+)->(\d+)/(\d+)/(\d+).*?eng=([-0-9.]+)/([-0-9.]+)\((\d+)/(\d+)\).*?mex=(\d+):(\d+).*?upg=(\d+):([^: ]+):([-0-9.]+).*?tech=(\d+):([^ ]+)') {
            $t = To-Double $Matches[1]
            $lastTime = $t
            $state.t = $t
            $state.prod_mode = $Matches[2]
            $state.prod_obj = ("{0}/{1}" -f $Matches[3], $Matches[4])
            $state.prod_conf = To-Double $Matches[5]
            $state.fac_total = (To-Int $Matches[7]) + (To-Int $Matches[8]) + (To-Int $Matches[9])
            $state.fac_target_total = (To-Int $Matches[10]) + (To-Int $Matches[11]) + (To-Int $Matches[12])
            $state.engineer_count = To-Int $Matches[15]
            $state.engineer_need = To-Int $Matches[16]
            $state.mex_ready = To-Int $Matches[17]
            $state.mex_total = To-Int $Matches[18]
            $state.upgrade_obj = if ((To-Int $Matches[19]) -gt 0) { 'enabled' } else { 'disabled' }
            $state.upgrade_reason = $Matches[20]
            Add-TimelinePoint -Timeline $timeline -State $state
            if ($line -match 'struct=R\d+ S\d+ AA\d+ PD\d+ SH(\d+) TMD(\d+) home=(\d+)') {
                $state.prod_struct_shield = To-Int $Matches[1]
                $state.prod_struct_tmd = To-Int $Matches[2]
                $state.prod_struct_home = To-Int $Matches[3]
                $structSignature = "shield=$($state.prod_struct_shield)|tmd=$($state.prod_struct_tmd)|home=$($state.prod_struct_home)"
                if ($signatures['production-structure'] -ne $structSignature) {
                    $eventIndex += 1
                    Add-EventRow -Events $events -LogName $log.Name -RunTag $identity.RunTag -Instance $identity.Instance -EventIndex $eventIndex -Subsystem 'production' -ActionType 'structure_posture' -ActionKey 'shield_tmd_home' -ActionValue ("{0}:{1}:{2}" -f $state.prod_struct_shield, $state.prod_struct_tmd, $state.prod_struct_home) -EventTime $t -State $state -Signature $structSignature -RawLine $line
                    $signatures['production-structure'] = $structSignature
                }
            }
            $signature = "mode=$($state.prod_mode)|obj=$($state.prod_obj)|fac=$($state.fac_target_total)|mex=$($state.mex_ready)/$($state.mex_total)|upg=$($state.upgrade_reason)"
            if ($signatures['production-objective'] -ne $signature) {
                $eventIndex += 1
                Add-EventRow -Events $events -LogName $log.Name -RunTag $identity.RunTag -Instance $identity.Instance -EventIndex $eventIndex -Subsystem 'production' -ActionType 'objective_shift' -ActionKey 'objective' -ActionValue $state.prod_obj -EventTime $t -State $state -Signature $signature -RawLine $line
                $signatures['production-objective'] = $signature
            }
            $matched = $true
        } elseif ($line -match '\*OVERMIND FORCE A\d+ t=([0-9.]+) land=(\d+) guard=(\d+) acu=(\d+) acuint=(\d+) int=(\d+) raid=(\d+) outer=(\d+) art=(\d+) main=(\d+) air=(\d+) bomb=(\d+) stale=(\d+) front=(\d+) tasks=(\d+)') {
            $t = To-Double $Matches[1]
            $lastTime = $t
            $state.t = $t
            $state.force_land = To-Int $Matches[2]
            $state.force_guard = To-Int $Matches[3]
            $state.force_acu = To-Int $Matches[4]
            $state.force_acuint = To-Int $Matches[5]
            $state.force_raid = To-Int $Matches[7]
            $state.force_outer = To-Int $Matches[8]
            $state.force_main = To-Int $Matches[10]
            Add-TimelinePoint -Timeline $timeline -State $state
            $signature = "guard=$($state.force_guard)|main=$($state.force_main)|outer=$($state.force_outer)|raid=$($state.force_raid)|acu=$($state.force_acu)|acuint=$($state.force_acuint)"
            if ($signatures['force'] -ne $signature) {
                $eventIndex += 1
                Add-EventRow -Events $events -LogName $log.Name -RunTag $identity.RunTag -Instance $identity.Instance -EventIndex $eventIndex -Subsystem 'force' -ActionType 'allocation_shift' -ActionKey 'guard_main_outer_raid' -ActionValue ("g{0}-m{1}-o{2}-r{3}" -f $state.force_guard, $state.force_main, $state.force_outer, $state.force_raid) -EventTime $t -State $state -Signature $signature -RawLine $line
                $signatures['force'] = $signature
            }
            $matched = $true
        } elseif ($line -match '\*OVERMIND ENGDIR A\d+ t=([0-9.]+) recover=(\d+) threat=(\d+) facRec=(\d+) powerRec=(\d+) surp=(\d+) expand=(\d+) field=(\d+) quota=(\d+) block=([^ ]+) baseNeed=(\d+) facTask=(\d+):([^ ]+) frac=([-0-9.]+) stall=([-0-9.]+) asn=(\d+)/(\d+) structTask=(\d+):([^: ]+):([^ ]+) frac=([-0-9.]+) stall=([-0-9.]+) asn=(\d+)/(\d+) near=(\d+) pos=([-0-9.]+),([-0-9.]+)') {
            $t = To-Double $Matches[1]
            $lastTime = $t
            $state.t = $t
            $state.engineer_expand = To-Int $Matches[7]
            $state.engineer_field = To-Int $Matches[8]
            $state.engineer_quota = To-Int $Matches[9]
            $state.engineer_block = $Matches[10]
            $state.engineer_base_need = To-Int $Matches[11]
            $state.engineer_fac_task = ("{0}:{1}" -f $Matches[12], $Matches[13])
            $state.engineer_struct_task = ("{0}:{1}:{2}" -f $Matches[18], $Matches[19], $Matches[20])
            if ($line -match 'acuRep=(\d+)\/(\d+)') {
                $state.engineer_acu_repair = To-Int $Matches[1]
                $state.engineer_acu_need = To-Int $Matches[2]
                $acuSignature = "acuRepair=$($state.engineer_acu_repair)|acuNeed=$($state.engineer_acu_need)"
                if ($signatures['engineer-acu-repair'] -ne $acuSignature) {
                    $eventIndex += 1
                    Add-EventRow -Events $events -LogName $log.Name -RunTag $identity.RunTag -Instance $identity.Instance -EventIndex $eventIndex -Subsystem 'engineer' -ActionType 'acu_repair' -ActionKey 'acu_repair_dispatch' -ActionValue ("{0}:{1}" -f $state.engineer_acu_repair, $state.engineer_acu_need) -EventTime $t -State $state -Signature $acuSignature -RawLine $line
                    $signatures['engineer-acu-repair'] = $acuSignature
                }
            }
            Add-TimelinePoint -Timeline $timeline -State $state
            $signature = "expand=$($state.engineer_expand)|field=$($state.engineer_field)|quota=$($state.engineer_quota)|block=$($state.engineer_block)|fac=$($state.engineer_fac_task)|struct=$($state.engineer_struct_task)"
            if ($signatures['engineer'] -ne $signature) {
                $eventIndex += 1
                Add-EventRow -Events $events -LogName $log.Name -RunTag $identity.RunTag -Instance $identity.Instance -EventIndex $eventIndex -Subsystem 'engineer' -ActionType 'task_bias_shift' -ActionKey 'expand_field_block' -ActionValue ("e{0}-f{1}-q{2}-{3}" -f $state.engineer_expand, $state.engineer_field, $state.engineer_quota, $state.engineer_block) -EventTime $t -State $state -Signature $signature -RawLine $line
                $signatures['engineer'] = $signature
            }
            $matched = $true
        } elseif ($line -match '\*OVERMIND UPGDIR A\d+ t=([0-9.]+) obj=([^ ]+) mex=([^: ]+):([^/ ]+)/([^ ]+) cap=(\d+) inflight=(\d+) fac=([^: ]+):([^ ]+)') {
            $t = To-Double $Matches[1]
            $lastTime = $t
            $state.t = $t
            $state.upgrade_obj = $Matches[2]
            $state.upgrade_reason = ("{0}:{1}/{2}" -f $Matches[3], $Matches[4], $Matches[5])
            $state.upgrade_cap = To-Int $Matches[6]
            $state.upgrade_inflight = To-Int $Matches[7]
            $state.upgrade_fac_state = ("{0}:{1}" -f $Matches[8], $Matches[9])
            Add-TimelinePoint -Timeline $timeline -State $state
            $signature = "obj=$($state.upgrade_obj)|reason=$($state.upgrade_reason)|cap=$($state.upgrade_cap)|fac=$($state.upgrade_fac_state)"
            if ($signatures['upgrade'] -ne $signature) {
                $eventIndex += 1
                Add-EventRow -Events $events -LogName $log.Name -RunTag $identity.RunTag -Instance $identity.Instance -EventIndex $eventIndex -Subsystem 'upgrade' -ActionType 'policy_shift' -ActionKey 'upgrade_policy' -ActionValue ("{0}:{1}" -f $state.upgrade_obj, $state.upgrade_reason) -EventTime $t -State $state -Signature $signature -RawLine $line
                $signatures['upgrade'] = $signature
            }
            $matched = $true
        } elseif ($line -match '\*OVERMIND FACTCTRL A\d+ t=([0-9.]+) mode=([^ ]+) fac=(\d+) ready=(\d+) empty=(\d+) qtarget=(\d+) idle=(\d+) issued=(\d+) topped=(\d+) growth=(\d+) tgt=(\d+)/(\d+)/(\d+)') {
            $t = To-Double $Matches[1]
            $lastTime = $t
            $state.t = $t
            $state.factory_mode = $Matches[2]
            $state.fac_total = To-Int $Matches[3]
            $state.factory_ready = To-Int $Matches[4]
            $state.factory_empty = To-Int $Matches[5]
            $state.factory_qtarget = To-Int $Matches[6]
            $state.idle_factories = To-Int $Matches[7]
            $state.factory_issued = To-Int $Matches[8]
            $state.factory_growth = To-Int $Matches[10]
            $state.fac_target_total = (To-Int $Matches[11]) + (To-Int $Matches[12]) + (To-Int $Matches[13])
            Add-TimelinePoint -Timeline $timeline -State $state
            $signature = "mode=$($state.factory_mode)|q=$($state.factory_qtarget)|growth=$($state.factory_growth)|tgt=$($state.fac_target_total)|issued=$($state.factory_issued)"
            if ($signatures['factory'] -ne $signature) {
                $eventIndex += 1
                Add-EventRow -Events $events -LogName $log.Name -RunTag $identity.RunTag -Instance $identity.Instance -EventIndex $eventIndex -Subsystem 'factory' -ActionType 'queue_shift' -ActionKey 'factory_queue' -ActionValue ("{0}:{1}" -f $state.factory_mode, $state.fac_target_total) -EventTime $t -State $state -Signature $signature -RawLine $line
                $signatures['factory'] = $signature
            }
            $matched = $true
        } elseif ($line -match '\*OVERMIND ECONSCORE A\d+ t=([0-9.]+) mex=(\d+) fac=(\d+)/(\d+)/(\d+) idle=(\d+) eng=(\d+)/(\d+) demand=(\d+):([^ ]+) buckets=(\d+)/(\d+)/(\d+)/(\d+)/(\d+)/(\d+) reclaim=([-0-9.]+)/([-0-9.]+) map=([-0-9.]+) pause=(\d+) q=([^ ]+) escort=(\d+)') {
            $t = To-Double $Matches[1]
            $lastTime = $t
            $state.t = $t
            $state.mex_ready = To-Int $Matches[2]
            $state.fac_total = (To-Int $Matches[3]) + (To-Int $Matches[4]) + (To-Int $Matches[5])
            $state.idle_factories = To-Int $Matches[6]
            $state.engineer_count = To-Int $Matches[7]
            $state.engineer_need = To-Int $Matches[8]
            $state.engineer_demand = To-Int $Matches[9]
            $state.reclaim_mass = To-Double $Matches[17]
            $state.reclaim_stagnation = To-Double $Matches[18]
            $state.map_control = To-Double $Matches[19]
            Add-TimelinePoint -Timeline $timeline -State $state
            $matched = $true
        } elseif ($line -match '\*OVERMIND METRICS A\d+ goal=([^ ]+) strat=([^/]+)/([^/]+)/([^:]+):([-0-9.]+) posture=([^ ]+) pivot=([^ ]+) conf=([-0-9.]+) prod=([^ ]+) float=([-0-9.]+) estall=([-0-9.]+) mstall=([-0-9.]+) aggr=([-0-9.]+) stagn=([-0-9.]+) eco=([-0-9.]+) sat=([-0-9.]+) fbusy=([-0-9.]+) ebusy=([-0-9.]+) mexcap=(\d+) reclaimq=(\d+) reason=([^ ]+) rf=(\d+) rs=(\d+)') {
            $state.goal = $Matches[1]
            $state.strategy_dir = $Matches[2]
            $state.strategy_theater = $Matches[3]
            $state.strategy_raid = $Matches[4]
            $state.posture = $Matches[6]
            $state.pivot = $Matches[7]
            $state.prod_mode = $Matches[9]
            $state.aggression = To-Double $Matches[13]
            Add-TimelinePoint -Timeline $timeline -State $state
            $signature = "goal=$($state.goal)|posture=$($state.posture)|pivot=$($state.pivot)|prod=$($state.prod_mode)"
            if ($signatures['metrics'] -ne $signature) {
                $eventIndex += 1
                Add-EventRow -Events $events -LogName $log.Name -RunTag $identity.RunTag -Instance $identity.Instance -EventIndex $eventIndex -Subsystem 'metrics' -ActionType 'posture_shift' -ActionKey 'goal_posture' -ActionValue ("{0}:{1}:{2}" -f $state.goal, $state.posture, $state.pivot) -EventTime $lastTime -State $state -Signature $signature -RawLine $line
                $signatures['metrics'] = $signature
            }
            $matched = $true
        } elseif ($line -match '\*OVERMIND MACROCTRL A\d+ t=([0-9.]+) phase=([^ ]+) reason=([^ ]+) lock=(\d+) spam=(\d+) land=(\d+)/(\d+) mex=(\d+) pwr=(\d+) hq=(\d+) t2eng=(\d+) t2pwr=(\d+) budget=([-0-9.]+) debt=(\d+) outer=([-0-9.]+) sfwd=(\d+) contest=(\d+) depth=([-0-9.]+)') {
            $t = To-Double $Matches[1]
            $lastTime = $t
            $state.t = $t
            $state.macro_phase = $Matches[2]
            $state.macro_reason = $Matches[3]
            Add-TimelinePoint -Timeline $timeline -State $state
            $signature = "phase=$($state.macro_phase)|reason=$($state.macro_reason)"
            if ($signatures['macro'] -ne $signature) {
                $eventIndex += 1
                Add-EventRow -Events $events -LogName $log.Name -RunTag $identity.RunTag -Instance $identity.Instance -EventIndex $eventIndex -Subsystem 'macro' -ActionType 'phase_shift' -ActionKey 'phase' -ActionValue ("{0}:{1}" -f $state.macro_phase, $state.macro_reason) -EventTime $t -State $state -Signature $signature -RawLine $line
                $signatures['macro'] = $signature
            }
            $matched = $true
        } elseif ($line -match '\*OVERMIND ACU SAFETY A\d+ action=([^ ]+) dist=([-0-9.]+) esc=(\d+) lth=([-0-9.]+) hth=([-0-9.]+) hp=([-0-9.]+)') {
            $state.acu_action = $Matches[1]
            $state.acu_dist = To-Double $Matches[2]
            $state.acu_hp = To-Double $Matches[6]
            Add-TimelinePoint -Timeline $timeline -State $state
            $signature = "action=$($state.acu_action)|dist=$([int]([math]::Floor($state.acu_dist / 5.0)))|hp=$([int]([math]::Floor($state.acu_hp * 10.0)))"
            if ($signatures['acu'] -ne $signature) {
                $eventIndex += 1
                Add-EventRow -Events $events -LogName $log.Name -RunTag $identity.RunTag -Instance $identity.Instance -EventIndex $eventIndex -Subsystem 'acu' -ActionType 'safety_action' -ActionKey 'acu_action' -ActionValue $state.acu_action -EventTime $lastTime -State $state -Signature $signature -RawLine $line
                $signatures['acu'] = $signature
            }
            $matched = $true
        }

        if (-not $matched) {
            continue
        }
    }

    $timeline = @($timeline | Sort-Object { To-Double $_.t })
    $jsonStats = Parse-JsonStatsPayload -Payload $jsonPayload
    $finalMassRatio = Get-FinalMassRatio -JsonStats $jsonStats
    $finalTime = if ($gameTimeSeconds -ne $null) { To-Double $gameTimeSeconds } elseif ($timeline.Count -gt 0) { To-Double $timeline[-1].t } else { 0.0 }

    foreach ($row in $timeline) {
        $null = $timelineRows.Add([pscustomobject]@{
            log_name = $log.Name
            run_tag = $identity.RunTag
            instance = $identity.Instance
            t = [math]::Round((To-Double $row.t), 2)
            mex_ready = To-Int $row.mex_ready
            fac_total = To-Int $row.fac_total
            reclaim_mass = [math]::Round((To-Double $row.reclaim_mass), 2)
            map_control = [math]::Round((To-Double $row.map_control), 4)
            idle_factories = To-Int $row.idle_factories
            engineer_count = To-Int $row.engineer_count
            force_guard = To-Int $row.force_guard
            force_main = To-Int $row.force_main
            force_outer = To-Int $row.force_outer
            force_raid = To-Int $row.force_raid
        })
    }

    foreach ($event in $events) {
        $baseState = Get-StateAtTime -Timeline $timeline -Target (To-Double $event.event_time)
        if ($null -eq $baseState) {
            continue
        }
        foreach ($window in $Windows) {
            $targetTime = (To-Double $event.event_time) + $window
            $futureState = Get-StateAtTime -Timeline $timeline -Target $targetTime
            if ($null -eq $futureState) {
                continue
            }
            $survivedWindow = ($finalTime -ge $targetTime)
            $gameEndedWithinWindow = ($finalTime -gt 0 -and $finalTime -lt $targetTime)
            $deltaMex = (To-Double $futureState.mex_ready) - (To-Double $baseState.mex_ready)
            $deltaFactories = (To-Double $futureState.fac_total) - (To-Double $baseState.fac_total)
            $deltaReclaimMass = (To-Double $futureState.reclaim_mass) - (To-Double $baseState.reclaim_mass)
            $deltaMapControl = (To-Double $futureState.map_control) - (To-Double $baseState.map_control)
            $deltaIdleFactories = (To-Double $futureState.idle_factories) - (To-Double $baseState.idle_factories)
            $deltaEngineers = (To-Double $futureState.engineer_count) - (To-Double $baseState.engineer_count)
            $deltaGuard = (To-Double $futureState.force_guard) - (To-Double $baseState.force_guard)
            $deltaMain = (To-Double $futureState.force_main) - (To-Double $baseState.force_main)
            $deltaOuter = (To-Double $futureState.force_outer) - (To-Double $baseState.force_outer)
            $deltaRaid = (To-Double $futureState.force_raid) - (To-Double $baseState.force_raid)
            $reward = Get-EventReward -DeltaMex $deltaMex -DeltaFactories $deltaFactories -DeltaReclaimMass $deltaReclaimMass -DeltaMapControl $deltaMapControl -DeltaIdleFactories $deltaIdleFactories -DeltaEngineers $deltaEngineers -DeltaGuard $deltaGuard -DeltaMain $deltaMain -DeltaOuter $deltaOuter -DeltaRaid $deltaRaid -SurvivedWindow $survivedWindow -GameEndedWithinWindow $gameEndedWithinWindow -FinalMassRatio $finalMassRatio

            $outcomeJson = (@{
                reward = $reward
                survived_window = $survivedWindow
                game_ended_within_window = $gameEndedWithinWindow
                final_mass_ratio = $finalMassRatio
            } | ConvertTo-Json -Depth 4 -Compress)

            $null = $outcomeRows.Add([pscustomobject]@{
                log_name = $event.log_name
                run_tag = $event.run_tag
                instance = $event.instance
                event_index = $event.event_index
                subsystem = $event.subsystem
                action_type = $event.action_type
                action_value = $event.action_value
                event_time = $event.event_time
                window_seconds = $window
                reward = $reward
                delta_mex_ready = [math]::Round($deltaMex, 2)
                delta_factory_total = [math]::Round($deltaFactories, 2)
                delta_reclaim_mass = [math]::Round($deltaReclaimMass, 2)
                delta_map_control = [math]::Round($deltaMapControl, 4)
                delta_idle_factories = [math]::Round($deltaIdleFactories, 2)
                delta_engineer_count = [math]::Round($deltaEngineers, 2)
                delta_force_guard = [math]::Round($deltaGuard, 2)
                delta_force_main = [math]::Round($deltaMain, 2)
                delta_force_outer = [math]::Round($deltaOuter, 2)
                delta_force_raid = [math]::Round($deltaRaid, 2)
                survived_window = $survivedWindow
                game_ended_within_window = $gameEndedWithinWindow
                final_mass_ratio = $finalMassRatio
                outcome_json = $outcomeJson
            })
        }
    }

    foreach ($event in $events) {
        $null = $eventRows.Add($event)
    }
}

$eventsCsv = Join-Path $OutputDir 'action_events.csv'
$eventsJson = Join-Path $OutputDir 'action_events.json'
$outcomesCsv = Join-Path $OutputDir 'action_outcomes.csv'
$outcomesJson = Join-Path $OutputDir 'action_outcomes.json'
$timelineCsv = Join-Path $OutputDir 'action_timeline.csv'
$summaryMd = Join-Path $OutputDir 'action_summary.md'

@($eventRows) | Export-Csv -Path $eventsCsv -NoTypeInformation -Encoding UTF8
@($eventRows) | ConvertTo-Json -Depth 8 | Set-Content -Path $eventsJson -Encoding UTF8
@($outcomeRows) | Export-Csv -Path $outcomesCsv -NoTypeInformation -Encoding UTF8
@($outcomeRows) | ConvertTo-Json -Depth 8 | Set-Content -Path $outcomesJson -Encoding UTF8
@($timelineRows) | Export-Csv -Path $timelineCsv -NoTypeInformation -Encoding UTF8

$md = @()
$md += '# Autotune Action Summary'
$md += ''
$md += "- Logs analyzed: $($logs.Count)"
$md += "- Action events: $($eventRows.Count)"
$md += "- Action outcomes: $($outcomeRows.Count)"
$md += ''
$md += '## Event Counts By Subsystem'
$md += ''
$md += '| Subsystem | Events |'
$md += '|---|---:|'
foreach ($group in @(@($eventRows) | Group-Object subsystem | Sort-Object Count -Descending)) {
    $md += "| $($group.Name) | $($group.Count) |"
}
$md += ''
$md += '## Top Action Values By Reward'
$md += ''
$md += '| Subsystem | ActionType | ActionValue | Samples | AvgReward |'
$md += '|---|---|---|---:|---:|'
$topActionRows = @(@($outcomeRows) | Group-Object subsystem, action_type, action_value | ForEach-Object {
    $first = $_.Group[0]
    [pscustomobject]@{
        subsystem = $first.subsystem
        action_type = $first.action_type
        action_value = $first.action_value
        samples = $_.Count
        avg_reward = [math]::Round((@($_.Group | Measure-Object -Property reward -Average).Average), 2)
    }
} | Sort-Object avg_reward -Descending | Select-Object -First 20)
foreach ($row in $topActionRows) {
    $md += "| $($row.subsystem) | $($row.action_type) | $($row.action_value) | $($row.samples) | $($row.avg_reward) |"
}
$md | Set-Content -Path $summaryMd -Encoding UTF8

Write-Host "Action events CSV:   $eventsCsv"
Write-Host "Action events JSON:  $eventsJson"
Write-Host "Action outcomes CSV: $outcomesCsv"
Write-Host "Action outcomes JSON:$outcomesJson"
Write-Host "Action timeline CSV: $timelineCsv"
Write-Host "Action summary MD:   $summaryMd"
