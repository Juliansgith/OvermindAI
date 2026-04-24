local Common = import('/mods/OvermindAI/lua/AI/Overmind/EngineerDirector/Common.lua')
local Threat = import('/mods/OvermindAI/lua/AI/Overmind/EngineerDirector/Threat.lua')
local Policy = import('/mods/OvermindAI/lua/AI/Overmind/EngineerDirector/Policy.lua')
local Expansion = import('/mods/OvermindAI/lua/AI/Overmind/EngineerDirector/Expansion.lua')
local Recovery = import('/mods/OvermindAI/lua/AI/Overmind/EngineerDirector/Recovery.lua')
local Assignments = import('/mods/OvermindAI/lua/AI/Overmind/EngineerDirector/Assignments.lua')
local OvermindEconomyLedger = import('/mods/OvermindAI/lua/AI/Overmind/EconomyLedger.lua')

local T1MexCategory = categories.STRUCTURE * categories.MASSEXTRACTION * categories.TECH1
local EnemyMexCategory = categories.STRUCTURE * categories.MASSEXTRACTION
local FactoryCategory = categories.FACTORY * categories.STRUCTURE
local StructureCategory = categories.STRUCTURE - categories.FACTORY
local MexCategory = categories.STRUCTURE * categories.MASSEXTRACTION
local EnergyCategory = categories.STRUCTURE * categories.ENERGYPRODUCTION
local RadarCategory = categories.STRUCTURE * categories.RADAR
local AADefenseCategory = categories.STRUCTURE * categories.DEFENSE * categories.ANTIAIR
local DefenseCategory = categories.STRUCTURE * categories.DEFENSE
local BuilderCategory = categories.ENGINEER * categories.MOBILE + categories.COMMAND
local LandCombatCategory = categories.MOBILE * categories.LAND - categories.ENGINEER - categories.SCOUT - categories.COMMAND

local function SafeDistance2D(a, b)
    local ax = (a and a[1]) or 0
    local az = (a and a[3]) or 0
    local bx = (b and b[1]) or 0
    local bz = (b and b[3]) or 0
    local dx = ax - bx
    local dz = az - bz
    return math.sqrt((dx * dx) + (dz * dz))
end

local function SafeGetFraction(unit)
    if not unit or unit.Dead or not unit.GetFractionComplete then
        return 1
    end
    local ok, fraction = pcall(function()
        return unit:GetFractionComplete()
    end)
    if ok and type(fraction) == 'number' then
        return fraction
    end
    return 1
end

local function GetACURepairNeed(aiBrain, runtime, mainPos, now)
    if not aiBrain or not mainPos then
        return 0
    end

    local acuUnits = aiBrain:GetListOfUnits(categories.COMMAND, false, true) or {}
    local acu = acuUnits[1]
    if not acu or acu.Dead or not acu.GetPosition or not acu.GetHealth or not acu.GetMaxHealth then
        return 0
    end

    local acuPos = acu:GetPosition()
    local maxHealth = math.max(1, acu:GetMaxHealth() or 1)
    local health = acu:GetHealth() or maxHealth
    local ratio = health / maxHealth
    local crisisActive = now < (runtime.ACUCrisisUntil or -999)
        or now < (runtime.ACUCrisisEscalatedUntil or -999)
    local recentDamage = (runtime.LastAcuDamageTime or -999) >= (now - 18)
    if not crisisActive and not recentDamage and ratio >= 0.92 then
        return 0
    end
    if SafeDistance2D(acuPos, mainPos) > 240 then
        return 0
    end

    local escort = aiBrain:GetNumUnitsAroundPoint(
        categories.MOBILE * (categories.LAND + categories.AIR) - categories.ENGINEER - categories.SCOUT - categories.COMMAND,
        acuPos,
        28,
        'Ally') or 0
    local threat = aiBrain:GetThreatAtPosition(acuPos, 1, true, 'AntiSurface') or 0
    local baseNeed = (ratio < 0.9 and 1 or 0)
        + (ratio < 0.72 and 1 or 0)
        + (crisisActive and 1 or 0)
        + (recentDamage and 1 or 0)
        + ((threat >= 1.4 or escort >= 4) and 1 or 0)
    return math.max(0, math.min(4, baseNeed))
end

local function CountEngineerActivity(engineers, isIdle, isConstructing)
    local activity = {
        TotalCount = 0,
        IdleCount = 0,
        ConstructingCount = 0,
        ReclaimingCount = 0,
        AssistingCount = 0,
    }
    for _, eng in (engineers or {}) do
        if eng and not eng.Dead then
            activity.TotalCount = activity.TotalCount + 1
            if isIdle(eng) then
                activity.IdleCount = activity.IdleCount + 1
            end
            if isConstructing(eng) then
                activity.ConstructingCount = activity.ConstructingCount + 1
            end
            if eng:IsUnitState('Reclaiming') then
                activity.ReclaimingCount = activity.ReclaimingCount + 1
            end
            if eng:IsUnitState('Guarding') or eng:IsUnitState('Attached') then
                activity.AssistingCount = activity.AssistingCount + 1
            end
        end
    end
    return activity
end

local function IsEcoStructureKind(kind)
    local lower = string.lower(kind or 'none')
    return lower == 'mex' or lower == 'power'
end

local function IsDefenseStructureKind(kind)
    local lower = string.lower(kind or 'none')
    return lower ~= 'none' and not IsEcoStructureKind(lower)
end

local function ApplyStructureSticky(task, kind, fraction, assignedBuilders, now)
    if not task then
        return
    end

    local stickyDuration = 10
    if kind == 'Mex' or kind == 'Power' then
        stickyDuration = 16
    elseif kind == 'Radar' then
        stickyDuration = 14
    elseif kind == 'AA' or kind == 'Defense' then
        stickyDuration = 24
    elseif string.lower(kind or 'none') == 'structure' then
        stickyDuration = 20
    end
    if fraction >= 0.45 then
        stickyDuration = stickyDuration + 6
    end
    if fraction >= 0.72 then
        stickyDuration = stickyDuration + 10
    end

    local earlyStickyFraction = 0.35
    if kind == 'AA' or kind == 'Defense' then
        earlyStickyFraction = 0.18
    elseif string.lower(kind or 'none') == 'structure' then
        earlyStickyFraction = 0.5
    end

    if assignedBuilders > 0 or fraction >= earlyStickyFraction then
        task.StickyUntil = math.max(task.StickyUntil or -999, now + stickyDuration)
    end
    if kind == 'Power' and fraction >= 0.8 then
        task.StickyUntil = math.max(task.StickyUntil or -999, now + stickyDuration + 10)
    elseif kind == 'Power' and fraction >= 0.35 then
        task.StickyUntil = math.max(task.StickyUntil or -999, now + stickyDuration + 16)
    elseif kind == 'Mex' and fraction >= 0.35 then
        task.StickyUntil = math.max(task.StickyUntil or -999, now + stickyDuration + 14)
    end
end

local function IsStructureTaskStable(task)
    if not task or not task.Active then
        return true
    end

    local threshold = 12
    if task.Kind == 'Mex' or task.Kind == 'Power' then
        threshold = 18
    end
    return (task.AssignedBuilders or 0) >= math.max(1, math.min(2, (task.RequiredBuilders or 0)))
        and (task.StallTime or 0) < threshold
end

local function IsStructureTaskCovered(task)
    if not task or not task.Active then
        return true
    end

    if task.Kind == 'Mex' or task.Kind == 'Power' then
        return (task.AssignedBuilders or 0) >= math.max(1, (task.RequiredBuilders or 0))
            and (task.StallTime or 0) < 18
    end
    return (task.AssignedBuilders or 0) >= math.max(1, (task.RequiredBuilders or 0))
        and (task.StallTime or 0) < 12
end

local function CopyStructureTaskState(dest, source, lane)
    dest = dest or {}
    source = source or {}
    dest.Active = source.Active == true
    dest.TargetId = source.TargetId or false
    dest.TargetPos = source.TargetPos or false
    dest.TargetFraction = source.TargetFraction or 1
    dest.Kind = source.Kind or 'none'
    dest.Priority = source.Priority or 0
    dest.StickyUntil = source.StickyUntil or -999
    dest.StallTime = source.StallTime or 0
    dest.RequiredBuilders = source.RequiredBuilders or 0
    dest.AssignedBuilders = source.AssignedBuilders or 0
    dest.BuilderIds = source.BuilderIds or {}
    dest.LastProgressTime = source.LastProgressTime or false
    dest.UsedCommander = source.UsedCommander == true
    dest.CandidateDebug = source.CandidateDebug or false
    dest.Lane = lane or source.Lane or 'primary'
    return dest
end

local function FindBestUnfinishedStructureForLane(aiBrain, runtime, mainPos, lane, getStructureKind, scoreStructureTarget)
    local structures = aiBrain:GetListOfUnits(StructureCategory, false, true) or {}
    if table.getn(structures) <= 0 then
        return false, false, 1, 'none', 0
    end

    local best = false
    local bestPos = false
    local bestFraction = 1
    local bestKind = 'none'
    local bestPriority = 0
    local bestScore = -999999
    local safeExpandDistance = (runtime.EcoPolicy and runtime.EcoPolicy.SafeExpandDistance) or 680

    for _, structure in structures do
        if structure and not structure.Dead and not structure:IsUnitState('Upgrading') then
            local fraction = SafeGetFraction(structure)
            if fraction < 0.995 then
                local pos = structure.GetPosition and structure:GetPosition() or false
                if pos then
                    local kind = getStructureKind(structure)
                    local useLane = (lane == 'eco' and IsEcoStructureKind(kind))
                        or (lane == 'defense' and IsDefenseStructureKind(kind))
                    if useLane then
                        local distMain = SafeDistance2D(pos, mainPos)
                        local maxDist = IsEcoStructureKind(kind) and math.max(300, safeExpandDistance * 0.95) or 240
                        if distMain <= maxDist then
                            local score, threat = scoreStructureTarget(aiBrain, runtime, structure, kind, pos, fraction, mainPos)
                            if threat <= (IsEcoStructureKind(kind) and 3.1 or 2.8) and score > bestScore then
                                best = structure
                                bestPos = pos
                                bestFraction = fraction
                                bestKind = kind
                                bestPriority = score
                                bestScore = score
                            end
                        end
                    end
                end
            end
        end
    end

    return best, bestPos, bestFraction, bestKind, bestPriority
end

local function SelectPrimaryStructureLane(ecoTask, ecoTargetObject, defenseTask, defenseTargetObject, constraints)
    local ecoActive = ecoTask and ecoTask.Active and ecoTargetObject
    local defenseActive = defenseTask and defenseTask.Active and defenseTargetObject
    if ecoActive and defenseActive then
        if ecoTask.Kind == 'Power' and constraints.PowerBufferLow == true then
            return ecoTask, ecoTargetObject, defenseTask, defenseTargetObject
        end
        if ecoTask.Kind == 'Mex' and ((constraints.MapControl or 1) <= 0.28 or constraints.StarterPhase == true) then
            return ecoTask, ecoTargetObject, defenseTask, defenseTargetObject
        end
        if defenseTask.Kind == 'Radar' and constraints.RadarCritical == true then
            return defenseTask, defenseTargetObject, ecoTask, ecoTargetObject
        end
        if (constraints.LandPanic or constraints.AirPanic)
            and (defenseTask.Kind == 'AA' or defenseTask.Kind == 'Defense' or defenseTask.Kind == 'Structure')
            and (defenseTask.Priority or 0) >= ((ecoTask.Priority or 0) + 40) then
            return defenseTask, defenseTargetObject, ecoTask, ecoTargetObject
        end
        if (defenseTask.Priority or 0) > ((ecoTask.Priority or 0) + 120) then
            return defenseTask, defenseTargetObject, ecoTask, ecoTargetObject
        end
        return ecoTask, ecoTargetObject, defenseTask, defenseTargetObject
    elseif ecoActive then
        return ecoTask, ecoTargetObject, false, false
    elseif defenseActive then
        return defenseTask, defenseTargetObject, false, false
    end
    return false, false, false, false
end

local function FallbackGetMainPos(aiBrain, runtime)
    if aiBrain and aiBrain.BuilderManagers and aiBrain.BuilderManagers.MAIN and aiBrain.BuilderManagers.MAIN.Position then
        return aiBrain.BuilderManagers.MAIN.Position
    end
    if runtime and runtime.ZoneModel and runtime.ZoneModel.OwnMainPos then
        return runtime.ZoneModel.OwnMainPos
    end
    local sx, sz = aiBrain:GetArmyStartPos()
    return { sx, 0, sz }
end

local function FallbackGetEntityId(unit)
    if not unit or unit.Dead then
        return false
    end
    if unit.GetEntityId then
        local ok, id = pcall(function()
            return unit:GetEntityId()
        end)
        if ok and id then
            return tostring(id)
        end
    end
    return tostring(unit)
end

local function FallbackGetFraction(unit)
    if not unit or unit.Dead or not unit.GetFractionComplete then
        return 1
    end
    local ok, fraction = pcall(function()
        return unit:GetFractionComplete()
    end)
    if ok and type(fraction) == 'number' then
        return fraction
    end
    return 1
end

local function FallbackIsIdle(unit)
    local q = unit and unit.GetCommandQueue and unit:GetCommandQueue() or false
    return (not q) or table.getn(q) == 0
end

local function FallbackIsConstructing(unit)
    if not unit or unit.Dead then
        return false
    end
    return unit:IsUnitState('Building') or unit:IsUnitState('Upgrading')
end

local function ResolveMethod(moduleTable, methodName, moduleName)
    local fn = false
    if type(moduleTable) == 'table' then
        fn = rawget(moduleTable, methodName)
        if type(fn) ~= 'function' then
            local ok, resolved = pcall(function()
                return moduleTable[methodName]
            end)
            if ok and type(resolved) == 'function' then
                fn = resolved
            end
        end
    end
    if type(fn) ~= 'function' then
        if moduleName == 'Common' and methodName == 'GetMainPos' then
            return FallbackGetMainPos
        elseif moduleName == 'Common' and methodName == 'GetEntityId' then
            return FallbackGetEntityId
        elseif moduleName == 'Common' and methodName == 'GetFraction' then
            return FallbackGetFraction
        elseif moduleName == 'Common' and methodName == 'IsIdle' then
            return FallbackIsIdle
        elseif moduleName == 'Common' and methodName == 'IsConstructing' then
            return FallbackIsConstructing
        end
        error(string.format('EngineerDirectorModular missing %s[%s]', tostring(moduleName), tostring(methodName)))
    end
    return fn
end

local function OptionalMethod(moduleTable, methodName, fallback)
    local fn = false
    if type(moduleTable) == 'table' then
        fn = rawget(moduleTable, methodName)
        if type(fn) ~= 'function' then
            local ok, resolved = pcall(function()
                return moduleTable[methodName]
            end)
            if ok and type(resolved) == 'function' then
                fn = resolved
            end
        end
    end
    if type(fn) == 'function' then
        return fn
    end
    return fallback
end

function Update(aiBrain, now)
    local runtime = aiBrain.OvermindRuntime
    if not runtime then
        return
    end

    local GetMainPos = ResolveMethod(Common, 'GetMainPos', 'Common')
    local GetEntityId = ResolveMethod(Common, 'GetEntityId', 'Common')
    local GetFraction = ResolveMethod(Common, 'GetFraction', 'Common')
    local IsIdle = ResolveMethod(Common, 'IsIdle', 'Common')
    local IsConstructing = ResolveMethod(Common, 'IsConstructing', 'Common')
    local CleanupExpansionReservations = OptionalMethod(Expansion, 'CleanupExpansionReservations', function() end)
    local NeedsCriticalRadar = OptionalMethod(Policy, 'NeedsCriticalRadar', function() return false end)
    local GetRadarReservedBuilderIds = OptionalMethod(Policy, 'GetRadarReservedBuilderIds', function() return {} end)
    local FindBestUnfinishedFactory = OptionalMethod(Recovery, 'FindBestUnfinishedFactory', function() return false, false, 1, 'none', 0 end)
    local ComputeFactoryTaskRequirements = OptionalMethod(Recovery, 'ComputeFactoryTaskRequirements', function() return 1 end)
    local GetStructureKind = OptionalMethod(Recovery, 'GetStructureKind', function() return 'Structure' end)
    local ScoreStructureTarget = OptionalMethod(Recovery, 'ScoreStructureTarget', function() return -999999, 999 end)
    local ResetFactoryTask = OptionalMethod(Recovery, 'ResetFactoryTask', function(task)
        if task then
            task.Active = false
            task.TargetId = false
            task.TargetPos = false
            task.TargetFraction = 1
            task.LastProgressTime = -999
            task.StallTime = 0
            task.RequiredBuilders = 0
            task.AssignedBuilders = 0
            task.BuilderIds = {}
            task.CandidateDebug = { Total = 0, Safe = 0, Reachable = 0, Interruptible = 0 }
        end
    end)
    local ShouldForceFinishEcoStructure = OptionalMethod(Recovery, 'ShouldForceFinishEcoStructure', function() return false, false, false end)
    local FindTrackedUnfinishedStructure = OptionalMethod(Recovery, 'FindTrackedUnfinishedStructure', function() return false, false, 1, 'none', 0 end)
    local FindBestUnfinishedStructure = OptionalMethod(Recovery, 'FindBestUnfinishedStructure', function() return false, false, 1, 'none', 0 end)
    local ShouldKeepTrackedStructureTask = OptionalMethod(Recovery, 'ShouldKeepTrackedStructureTask', function() return false end)
    local ComputeStructureTaskRequirements = OptionalMethod(Recovery, 'ComputeStructureTaskRequirements', function() return 1 end)
    local ResetStructureTask = OptionalMethod(Recovery, 'ResetStructureTask', function(task)
        if task then
            task.Active = false
            task.TargetId = false
            task.TargetPos = false
            task.TargetFraction = 1
            task.LastProgressTime = -999
            task.StallTime = 0
            task.RequiredBuilders = 0
            task.AssignedBuilders = 0
            task.BuilderIds = {}
            task.CandidateDebug = { Total = 0, Safe = 0, Reachable = 0, Interruptible = 0 }
        end
    end)
    local AssignBuildersToUnfinishedFactory = OptionalMethod(Assignments, 'AssignBuildersToUnfinishedFactory', function() return 0, {}, false, { Total = 0, Safe = 0, Reachable = 0, Interruptible = 0 } end)
    local AssignBuildersToUnfinishedStructure = OptionalMethod(Assignments, 'AssignBuildersToUnfinishedStructure', function() return 0, {}, false, { Total = 0, Safe = 0, Reachable = 0, Interruptible = 0 } end)
    local ProcessEngineer = OptionalMethod(Assignments, 'ProcessEngineer', function() end)
    local DescribeStructureTaskTarget = OptionalMethod(Assignments, 'DescribeStructureTaskTarget', function() return 'none' end)
    local expansionDispatchAvailable = type(Expansion) == 'table'
        and type(rawget(Expansion, 'DispatchExpansionEngineer')) == 'function'
    runtime.EngineerDirectorExpansionDispatchAvailable = expansionDispatchAvailable
    local DispatchExpansionEngineer = OptionalMethod(Expansion, 'DispatchExpansionEngineer', function()
        runtime.LastExpansionInternalGateReason = 'impl_missing'
        return 0
    end)
    local function CallDispatchExpansionEngineer(...)
        runtime.LastExpansionInternalGateReason = 'precall'
        local issued = DispatchExpansionEngineer(...)
        if runtime.LastExpansionInternalGateReason == 'precall' then
            runtime.LastExpansionInternalGateReason = 'impl_no_state'
        end
        return issued or 0
    end

    if now - (runtime.LastEngineerDirectorTime or -999) < 3 then
        return
    end
    runtime.LastEngineerDirectorTime = now

    local engineers = aiBrain:GetListOfUnits(categories.ENGINEER * categories.MOBILE, false, true) or {}
    local policy = runtime.EcoPolicy or {}
    local mainPos = GetMainPos(aiBrain, runtime)
    local engState = runtime.EngineerState or {}
    runtime.EngineerState = engState
    local factoryTask = engState.UnfinishedFactoryTask or {}
    engState.UnfinishedFactoryTask = factoryTask
    local ecoStructureTask = engState.UnfinishedEcoStructureTask or {}
    engState.UnfinishedEcoStructureTask = ecoStructureTask
    local defenseStructureTask = engState.UnfinishedDefenseStructureTask or {}
    engState.UnfinishedDefenseStructureTask = defenseStructureTask
    local structureTask = engState.UnfinishedStructureTask or {}
    engState.UnfinishedStructureTask = structureTask
    engState.ExpansionReservations = engState.ExpansionReservations or {}
    CleanupExpansionReservations(runtime, now)

    local baseFloor = policy.BaseEngineerFloor or 3
    if now < 300 then
        baseFloor = math.max(2, baseFloor - 1)
    end
    local safeExpandDistance = policy.SafeExpandDistance or 680
    local enemyPos = runtime.PrimaryEnemyPos
    local baseEngineers = aiBrain:GetNumUnitsAroundPoint(categories.ENGINEER * categories.MOBILE, mainPos, 80, 'Ally') or 0
    local needBase = math.max(0, baseFloor - baseEngineers)
    local recovery = runtime.Recovery or {}
    local severeFactoryStarve = recovery.ForceFactoryRecovery and ((recovery.FactoryQueueStarvationTime or 0) >= 26)
    local eco = runtime.EcoState or {}
    local ecoCrash = (eco.MassStorageRatio or 0) <= 0.005 and (eco.EnergyStorageRatio or 0) <= 0.005
    local radarCritical = NeedsCriticalRadar(runtime)
    local raid = runtime.RaidDefense or {}
    local constraints = ((runtime.ProductionDirector or {}).ConstraintState or {})
    local current = ((runtime.ProductionDirector or {}).Current or {})
    local mexReady = (((current.Eco or {}).Mex or {}).Ready) or 0
    engState.PeakMexReady = math.max(engState.PeakMexReady or 0, mexReady)
    local mexLossCount = math.max(0, (engState.PeakMexReady or mexReady) - mexReady)
    local mexRebuildUrgent = mexLossCount >= 1
        or (
            ((raid.LastThreatLabel == 'mex' or raid.LastThreatLabel == 'asset')
                and (raid.UnderLandHarass or raid.UnderAirHarass))
            and mexReady <= ((constraints.StarterMexFloor or 5) + 2)
        )
    local mexExpansionUrgent = now < 1500
        and mexReady < math.max(12, (constraints.StarterMexFloor or 5) + 5)
        and not severeFactoryStarve
    local starterMexFloor = constraints.StarterMexFloor or 5
    local coreEcoCritical = mexRebuildUrgent
        or mexReady < starterMexFloor
        or (now < 600 and mexReady < math.max(6, starterMexFloor + 1))
        or mexExpansionUrgent
    if mexRebuildUrgent then
        safeExpandDistance = math.max(safeExpandDistance, 920)
    elseif mexExpansionUrgent then
        safeExpandDistance = math.max(safeExpandDistance, 860)
    end
    engState.MexEmergencyRebuild = mexRebuildUrgent and true or false
    engState.MexEmergencyActive = (mexRebuildUrgent or mexExpansionUrgent) and true or false
    if mexRebuildUrgent then
        recovery.ForceFactoryLand = true
        recovery.ForceBaseEngineerRecovery = true
    end
    local macro = runtime.MacroController or {}
    local macroPhase = macro.Phase or (((runtime.ProductionDirector or {}).MacroObjective) or 'land_factory_floor')
    local hqPressureEscape = macro.HQPressureEscape == true
    local transitionLock = macro.TransitionLocked == true
    local contestFieldMode = hqPressureEscape
        or ((((policy.ForwardContestBias == true) or (policy.ReclaimPressureMode == true)) and (macroPhase == 'mass_consolidation' or macroPhase == 'surplus_scale')))
    local planner = runtime.StrategicPlanner or {}
    local outerContestUnits = ((((runtime.ForceDirector or {}).Stats or {}).OuterContest) or 0)
    local reclaimFieldPos = planner.ReclaimFieldPos
    local reclaimFieldScore = planner.ReclaimFieldScore or 0
    local reclaimSignalMode = reclaimFieldPos
        and reclaimFieldScore >= 90
        and (planner.ReclaimFirst == true or planner.OuterRetentionActive == true or policy.ReclaimPressureMode == true)
    local currentRadar = ((((runtime.ProductionDirector or {}).Current or {}).Structures or {}).Radar) or 0
    local bomberWatch = constraints.BomberWatch == true
    local bomberPanic = ((raid.BomberPanicUntil or -999) > now) or ((raid.LastBomberEnemyCount or 0) >= 1 and raid.UnderAirHarass)
    local radarReservedBuilderIds = GetRadarReservedBuilderIds(runtime, now)
    local hqPowerRecoveryWanted = ((((runtime.UpgradeDirector or {}).Factory) or {}).PowerRecoveryWanted) == true
    local preclaimedExpand = 0
    local massTrend = eco.MassTrend or 0
    local energyTrend = eco.EnergyTrend or 0
    local expansionTrendOk = true
    if not mexExpansionUrgent then
        expansionTrendOk = massTrend > -0.7 and energyTrend > -35
    else
        expansionTrendOk = energyTrend > -70 and (massTrend > -6 or mexReady < 8 or (eco.MassStorageRatio or 0) > 0.02)
    end
    local expansionGateReason = 'none'
    local earlyExpansionSlice = now >= 60
        and mexExpansionUrgent
        and (baseEngineers >= math.max(2, baseFloor - 1) or mexReady < 8)
        and table.getn(engineers or {}) >= math.max(4, baseFloor)
        and not severeFactoryStarve
        and not ecoCrash
        and not radarCritical
        and not raid.ExposedMexUnderAirRaid
        and expansionTrendOk
    if not earlyExpansionSlice and mexExpansionUrgent then
        expansionGateReason = now < 60 and 'early_time'
            or (baseEngineers < math.max(2, baseFloor - 1) and mexReady >= 8) and 'base_floor'
            or table.getn(engineers or {}) < math.max(4, baseFloor) and 'eng_floor'
            or severeFactoryStarve and 'factory_starve'
            or ecoCrash and 'eco_crash'
            or radarCritical and 'radar'
            or raid.ExposedMexUnderAirRaid and 'air_raid'
            or not expansionTrendOk and 'trend'
            or 'early_blocked'
    end
    if earlyExpansionSlice then
        local earlyThreatCap = 1.65
        if policy.ForwardContestBias == true or policy.ContestMapMode == true then
            earlyThreatCap = 1.95
        end
        if planner.OuterRetentionActive == true or reclaimSignalMode then
            earlyThreatCap = earlyThreatCap + 0.2
        end
        expansionGateReason = 'early_called'
        preclaimedExpand = CallDispatchExpansionEngineer(aiBrain, runtime, now, engineers, mainPos, enemyPos, math.max(520, safeExpandDistance), earlyThreatCap)
    end

    local target, targetPos, fraction, domain, readyFactories = FindBestUnfinishedFactory(aiBrain, runtime, mainPos)
    local factoryTargetObject = target
    if target and targetPos then
            local targetId = GetEntityId(target)
        if factoryTask.TargetId ~= targetId or fraction > ((factoryTask.TargetFraction or 0) + 0.01) then
            factoryTask.TargetId = targetId
            factoryTask.TargetPos = targetPos
            factoryTask.TargetFraction = fraction
            factoryTask.LastProgressTime = now
        end
        factoryTask.Active = true
        factoryTask.Domain = domain
        factoryTask.ReadyFactories = readyFactories
        factoryTask.StallTime = now - (factoryTask.LastProgressTime or now)
        factoryTask.RequiredBuilders = ComputeFactoryTaskRequirements(domain, fraction, factoryTask.StallTime or 0, readyFactories, eco)
        factoryTask.TargetPos = targetPos
        factoryTask.TargetFraction = fraction

        local factoryReservedBuilderIds = radarReservedBuilderIds
        if macroPhase == 'first_t2_power' then
            factoryReservedBuilderIds = {}
            for id, value in pairs(radarReservedBuilderIds) do
                factoryReservedBuilderIds[id] = value
            end
            local techEngineers = aiBrain:GetListOfUnits(categories.ENGINEER * categories.MOBILE * (categories.TECH2 + categories.TECH3), false, true) or {}
            for _, unit in techEngineers do
                local id = GetEntityId(unit)
                if id then
                    factoryReservedBuilderIds[id] = true
                end
            end
        end

        local assignedBuilders, claimedBuilders, usedCommander, debug = AssignBuildersToUnfinishedFactory(
            aiBrain,
            runtime,
            now,
            target,
            targetPos,
            domain,
            readyFactories,
            factoryTask.StallTime or 0,
            factoryReservedBuilderIds)
        factoryTask.AssignedBuilders = assignedBuilders
        factoryTask.BuilderIds = claimedBuilders
        factoryTask.UsedCommander = usedCommander and true or false
        factoryTask.CandidateDebug = debug
    else
        ResetFactoryTask(factoryTask)
    end

    local factoryTaskCritical = factoryTask.Active
        and (((factoryTask.ReadyFactories or 0) <= 0)
            or ((factoryTask.AssignedBuilders or 0) < (factoryTask.RequiredBuilders or 0)))
    local reservedStructureBuilderIds = {}
    for id, value in pairs(radarReservedBuilderIds) do
        reservedStructureBuilderIds[id] = value
    end
    for id, value in pairs(factoryTask.BuilderIds or {}) do
        reservedStructureBuilderIds[id] = value
    end
    local structureTargetObject = false
    local ecoStructureTargetObject = false
    local defenseStructureTargetObject = false
    local forceFinishEco, forcedEcoTarget, forcedEcoKind = ShouldForceFinishEcoStructure(aiBrain, runtime, mainPos, false, false)
    local allowEcoStructureLane = (not factoryTaskCritical) or forceFinishEco
    if allowEcoStructureLane then
        local trackedStructure, trackedPos, trackedFraction, trackedKind, trackedPriority = FindTrackedUnfinishedStructure(aiBrain, ecoStructureTask)
        local structure, structurePos, structureFraction, structureKind, structurePriority = FindBestUnfinishedStructureForLane(
            aiBrain,
            runtime,
            mainPos,
            'eco',
            GetStructureKind,
            ScoreStructureTarget)

        if forceFinishEco and forcedEcoTarget and not forcedEcoTarget.Dead and IsEcoStructureKind(forcedEcoKind) then
            local forcedPos = forcedEcoTarget.GetPosition and forcedEcoTarget:GetPosition() or false
            if forcedPos then
                structure = forcedEcoTarget
                structurePos = forcedPos
                structureFraction = GetFraction(forcedEcoTarget)
                structureKind = forcedEcoKind or 'Structure'
                structurePriority = 1000 + (structureFraction * 100)
            end
        end

        if trackedStructure and trackedPos and IsEcoStructureKind(trackedKind) then
            local trackedTargetId = GetEntityId(trackedStructure)
            local bestTargetId = structure and GetEntityId(structure) or false
            if ShouldKeepTrackedStructureTask(
                now,
                ecoStructureTask,
                trackedTargetId,
                trackedKind,
                trackedFraction,
                trackedPriority or 0,
                bestTargetId,
                structureKind,
                structurePriority or 0,
                radarCritical) then
                structure = trackedStructure
                structurePos = trackedPos
                structureFraction = trackedFraction
                structureKind = trackedKind
                structurePriority = trackedPriority
            end
        end

        if structure and structurePos and IsEcoStructureKind(structureKind) then
            ecoStructureTargetObject = structure
            local targetId = GetEntityId(structure)
            if ecoStructureTask.TargetId ~= targetId or structureFraction > ((ecoStructureTask.TargetFraction or 0) + 0.01) then
                ecoStructureTask.TargetId = targetId
                ecoStructureTask.TargetPos = structurePos
                ecoStructureTask.TargetFraction = structureFraction
                ecoStructureTask.LastProgressTime = now
            end
            ecoStructureTask.Active = true
            ecoStructureTask.Kind = structureKind
            ecoStructureTask.Priority = structurePriority
            ecoStructureTask.StallTime = now - (ecoStructureTask.LastProgressTime or now)
            ecoStructureTask.RequiredBuilders = ComputeStructureTaskRequirements(structureKind, structureFraction, ecoStructureTask.StallTime or 0, eco)
            ecoStructureTask.TargetPos = structurePos
            ecoStructureTask.TargetFraction = structureFraction
            ecoStructureTask.Lane = 'eco'

            local assignedBuilders, claimedBuilders, usedCommander, debug = AssignBuildersToUnfinishedStructure(
                aiBrain,
                runtime,
                now,
                structure,
                structurePos,
                structureKind,
                ecoStructureTask.StallTime or 0,
                reservedStructureBuilderIds)

            if assignedBuilders <= 0
                and trackedStructure
                and trackedPos
                and IsEcoStructureKind(trackedKind)
                and GetEntityId(trackedStructure) ~= targetId then
                local fallbackAssigned, fallbackClaimed, fallbackCommander, fallbackDebug = AssignBuildersToUnfinishedStructure(
                    aiBrain,
                    runtime,
                    now,
                    trackedStructure,
                    trackedPos,
                    trackedKind,
                    ecoStructureTask.StallTime or 0,
                    reservedStructureBuilderIds)
                if fallbackAssigned > 0 then
                    structure = trackedStructure
                    ecoStructureTargetObject = trackedStructure
                    structurePos = trackedPos
                    structureFraction = trackedFraction
                    structureKind = trackedKind
                    structurePriority = trackedPriority
                    targetId = GetEntityId(trackedStructure)
                    ecoStructureTask.TargetId = targetId
                    ecoStructureTask.TargetPos = trackedPos
                    ecoStructureTask.TargetFraction = trackedFraction
                    ecoStructureTask.Kind = trackedKind
                    ecoStructureTask.Priority = trackedPriority
                    assignedBuilders = fallbackAssigned
                    claimedBuilders = fallbackClaimed
                    usedCommander = fallbackCommander
                    debug = fallbackDebug
                end
            end

            ecoStructureTask.AssignedBuilders = assignedBuilders
            ecoStructureTask.BuilderIds = claimedBuilders
            ecoStructureTask.UsedCommander = usedCommander and true or false
            ecoStructureTask.CandidateDebug = debug
            ApplyStructureSticky(ecoStructureTask, structureKind, structureFraction, assignedBuilders, now)
        else
            ResetStructureTask(ecoStructureTask)
            ecoStructureTask.Lane = 'eco'
        end
    else
        ResetStructureTask(ecoStructureTask)
        ecoStructureTask.Lane = 'eco'
    end

    local reservedDefenseBuilderIds = {}
    for id, value in pairs(reservedStructureBuilderIds) do
        reservedDefenseBuilderIds[id] = value
    end
    for id, value in pairs(ecoStructureTask.BuilderIds or {}) do
        reservedDefenseBuilderIds[id] = value
    end

    local allowDefenseStructureLane = not transitionLock and (
        not factoryTaskCritical
        or radarCritical
        or constraints.RadarCritical == true
        or constraints.LandPanic == true
        or constraints.AirPanic == true
        or constraints.BomberWatch == true
        or constraints.BomberPanic == true
        or constraints.CriticalStructure == true
    )
    if allowDefenseStructureLane then
        local trackedStructure, trackedPos, trackedFraction, trackedKind, trackedPriority = FindTrackedUnfinishedStructure(aiBrain, defenseStructureTask)
        local structure, structurePos, structureFraction, structureKind, structurePriority = FindBestUnfinishedStructureForLane(
            aiBrain,
            runtime,
            mainPos,
            'defense',
            GetStructureKind,
            ScoreStructureTarget)

        if trackedStructure and trackedPos and IsDefenseStructureKind(trackedKind) then
            local trackedTargetId = GetEntityId(trackedStructure)
            local bestTargetId = structure and GetEntityId(structure) or false
            if ShouldKeepTrackedStructureTask(
                now,
                defenseStructureTask,
                trackedTargetId,
                trackedKind,
                trackedFraction,
                trackedPriority or 0,
                bestTargetId,
                structureKind,
                structurePriority or 0,
                radarCritical) then
                structure = trackedStructure
                structurePos = trackedPos
                structureFraction = trackedFraction
                structureKind = trackedKind
                structurePriority = trackedPriority
            end
        end

        if structure and structurePos and IsDefenseStructureKind(structureKind) then
            defenseStructureTargetObject = structure
            local targetId = GetEntityId(structure)
            if defenseStructureTask.TargetId ~= targetId or structureFraction > ((defenseStructureTask.TargetFraction or 0) + 0.01) then
                defenseStructureTask.TargetId = targetId
                defenseStructureTask.TargetPos = structurePos
                defenseStructureTask.TargetFraction = structureFraction
                defenseStructureTask.LastProgressTime = now
            end
            defenseStructureTask.Active = true
            defenseStructureTask.Kind = structureKind
            defenseStructureTask.Priority = structurePriority
            defenseStructureTask.StallTime = now - (defenseStructureTask.LastProgressTime or now)
            defenseStructureTask.RequiredBuilders = ComputeStructureTaskRequirements(structureKind, structureFraction, defenseStructureTask.StallTime or 0, eco)
            defenseStructureTask.TargetPos = structurePos
            defenseStructureTask.TargetFraction = structureFraction
            defenseStructureTask.Lane = 'defense'

            local assignedBuilders, claimedBuilders, usedCommander, debug = AssignBuildersToUnfinishedStructure(
                aiBrain,
                runtime,
                now,
                structure,
                structurePos,
                structureKind,
                defenseStructureTask.StallTime or 0,
                reservedDefenseBuilderIds)

            if assignedBuilders <= 0
                and trackedStructure
                and trackedPos
                and IsDefenseStructureKind(trackedKind)
                and GetEntityId(trackedStructure) ~= targetId then
                local fallbackAssigned, fallbackClaimed, fallbackCommander, fallbackDebug = AssignBuildersToUnfinishedStructure(
                    aiBrain,
                    runtime,
                    now,
                    trackedStructure,
                    trackedPos,
                    trackedKind,
                    defenseStructureTask.StallTime or 0,
                    reservedDefenseBuilderIds)
                if fallbackAssigned > 0 then
                    structure = trackedStructure
                    defenseStructureTargetObject = trackedStructure
                    structurePos = trackedPos
                    structureFraction = trackedFraction
                    structureKind = trackedKind
                    structurePriority = trackedPriority
                    targetId = GetEntityId(trackedStructure)
                    defenseStructureTask.TargetId = targetId
                    defenseStructureTask.TargetPos = trackedPos
                    defenseStructureTask.TargetFraction = trackedFraction
                    defenseStructureTask.Kind = trackedKind
                    defenseStructureTask.Priority = trackedPriority
                    assignedBuilders = fallbackAssigned
                    claimedBuilders = fallbackClaimed
                    usedCommander = fallbackCommander
                    debug = fallbackDebug
                end
            end

            defenseStructureTask.AssignedBuilders = assignedBuilders
            defenseStructureTask.BuilderIds = claimedBuilders
            defenseStructureTask.UsedCommander = usedCommander and true or false
            defenseStructureTask.CandidateDebug = debug
            ApplyStructureSticky(defenseStructureTask, structureKind, structureFraction, assignedBuilders, now)
        else
            ResetStructureTask(defenseStructureTask)
            defenseStructureTask.Lane = 'defense'
        end
    else
        ResetStructureTask(defenseStructureTask)
        defenseStructureTask.Lane = 'defense'
    end

    local primaryStructureTask, primaryStructureTargetObject = SelectPrimaryStructureLane(
        ecoStructureTask,
        ecoStructureTargetObject,
        defenseStructureTask,
        defenseStructureTargetObject,
        constraints)
    if primaryStructureTask then
        local lane = (primaryStructureTask == ecoStructureTask) and 'eco' or 'defense'
        CopyStructureTaskState(structureTask, primaryStructureTask, lane)
        structureTargetObject = primaryStructureTargetObject
    else
        ResetStructureTask(structureTask)
        structureTask.Lane = 'primary'
    end

    local factoryTaskStable = (not factoryTask.Active)
        or (
            (factoryTask.AssignedBuilders or 0) >= math.max(1, math.min(2, (factoryTask.RequiredBuilders or 0)))
            and (factoryTask.StallTime or 0) < 18
        )
    local ecoStructureTaskStable = IsStructureTaskStable(ecoStructureTask)
    local defenseStructureTaskStable = IsStructureTaskStable(defenseStructureTask)
    local structureTaskStable = ecoStructureTaskStable and defenseStructureTaskStable
    local desiredReclaimQuota = policy.EngineerReclaimQuota or 0
    local firstReclaimBaseReady = baseEngineers >= math.max(2, baseFloor - 1)
    local fieldBaseReady = baseEngineers >= math.max(3, baseFloor)
    local fieldPriorityOverride = reclaimSignalMode
        and reclaimFieldScore >= 130
        and firstReclaimBaseReady
        and mexReady >= math.max(4, starterMexFloor - 1)
        and not mexRebuildUrgent
    local reclaimStarveOverride = desiredReclaimQuota > 0
        and reclaimFieldScore >= 140
        and table.getn(engineers or {}) >= 7
    engState.ReclaimFieldStickyUntil = engState.ReclaimFieldStickyUntil or -999
    engState.ReclaimFieldStickyQuota = engState.ReclaimFieldStickyQuota or 0
    local fieldStickyActive = now < (engState.ReclaimFieldStickyUntil or -999)
    local fieldTaskQuota = 0
    if (contestFieldMode or reclaimSignalMode or desiredReclaimQuota > 0)
        and reclaimFieldPos
        and (fieldBaseReady or fieldPriorityOverride or (desiredReclaimQuota > 0 and firstReclaimBaseReady))
        and not ecoCrash
        and (not severeFactoryStarve or reclaimStarveOverride)
        and (factoryTaskStable or fieldPriorityOverride or desiredReclaimQuota > 0)
        and (structureTaskStable or fieldPriorityOverride or desiredReclaimQuota > 0) then
        if ((planner.ReclaimFirst == true or planner.OuterRetentionActive == true or outerContestUnits > 0) or desiredReclaimQuota > 0)
            and reclaimFieldScore >= 90 then
            fieldTaskQuota = math.max(1, desiredReclaimQuota)
        end
        if reclaimFieldScore >= 150
            and baseEngineers >= (baseFloor + 1) then
            fieldTaskQuota = math.max(fieldTaskQuota, 2)
        end
        if reclaimFieldScore >= 260
            and desiredReclaimQuota >= 2
            and baseEngineers >= (baseFloor + 2) then
            fieldTaskQuota = math.max(fieldTaskQuota, 3)
        end
    end
    if fieldTaskQuota > 0 then
        engState.ReclaimFieldStickyUntil = now + 48
        engState.ReclaimFieldStickyQuota = math.max(engState.ReclaimFieldStickyQuota or 0, fieldTaskQuota)
        fieldStickyActive = true
    elseif fieldStickyActive
        and (contestFieldMode or reclaimSignalMode or desiredReclaimQuota > 0)
        and reclaimFieldPos
        and (fieldBaseReady or fieldPriorityOverride or (desiredReclaimQuota > 0 and firstReclaimBaseReady))
        and not ecoCrash
        and (not severeFactoryStarve or reclaimStarveOverride)
        and (factoryTaskStable or fieldPriorityOverride or desiredReclaimQuota > 0)
        and (structureTaskStable or fieldPriorityOverride or desiredReclaimQuota > 0) then
        fieldTaskQuota = math.max(1, engState.ReclaimFieldStickyQuota or 1)
    else
        engState.ReclaimFieldStickyUntil = -999
        engState.ReclaimFieldStickyQuota = 0
        fieldStickyActive = false
    end
    local allowTechBuilderReclaim = fieldTaskQuota > 0
        and not coreEcoCritical
        and not transitionLock
        and not (macroPhase == 'first_land_hq' or macroPhase == 'first_t2_engineer' or macroPhase == 'first_t2_power')
        and baseEngineers >= math.max(baseFloor + 1, 4)
        and (planner.ReclaimFirst == true or planner.OuterRetentionActive == true)

    local ctx = {
        bomberPanic = bomberPanic,
        constraints = constraints,
        contestFieldMode = (contestFieldMode or reclaimSignalMode or desiredReclaimQuota > 0) and true or false,
        coreEcoCritical = coreEcoCritical,
        dispatchedExpand = preclaimedExpand,
        ecoStructureTargetObject = ecoStructureTargetObject,
        ecoStructureTask = ecoStructureTask,
        enemyPos = enemyPos,
        factoryTargetObject = factoryTargetObject,
        factoryTask = factoryTask,
        forcedFactoryRecover = factoryTask.AssignedBuilders or 0,
        defenseStructureTargetObject = defenseStructureTargetObject,
        defenseStructureTask = defenseStructureTask,
        hqPowerRecoveryWanted = hqPowerRecoveryWanted,
        homeDefenseCritical = defenseStructureTask.Active and (
            defenseStructureTask.Kind == 'AA'
            or defenseStructureTask.Kind == 'Defense'
            or defenseStructureTask.Kind == 'Radar'
            or string.lower(defenseStructureTask.Kind or 'none') == 'structure'
        ) or false,
        macroNeedPowerRecovery = macro.NeedPowerRecovery == true,
        macroPhase = macroPhase,
        mainPos = mainPos,
        mapCollapse = (constraints.MapControl or 1) <= 0.28 or mexReady <= math.max(5, (constraints.StarterMexFloor or 5)) or mexRebuildUrgent,
        needBase = needBase,
        powerRecoveryCount = 0,
        acuRepairCount = 0,
        radarReservedBuilderIds = radarReservedBuilderIds,
        radarCritical = radarCritical,
        raid = raid,
        reclaimEnemyMex = 0,
        reclaimField = 0,
        reclaimFieldPos = reclaimFieldPos,
        recoverCount = 0,
        safeExpandDistance = safeExpandDistance,
        severeFactoryStarve = severeFactoryStarve,
        structureReclaimPreempts = 0,
        structureTargetObject = structureTargetObject,
        structureTask = structureTask,
        surplusSpendCount = 0,
        techTransitionCritical = macroPhase == 'first_land_hq'
            or macroPhase == 'first_t2_engineer'
            or macroPhase == 'first_t2_power',
        threatenedCount = 0,
        transitionLock = transitionLock,
        fieldTaskQuota = fieldTaskQuota,
        allowTechBuilderReclaim = allowTechBuilderReclaim,
        fieldPriorityOverride = fieldPriorityOverride,
        mexReady = mexReady,
        mexRebuildUrgent = mexRebuildUrgent,
        starterMexFloor = starterMexFloor,
    }
    local factoryTaskCovered = (not factoryTask.Active)
        or (
            (factoryTask.AssignedBuilders or 0) >= math.max(1, (factoryTask.RequiredBuilders or 0))
            and (factoryTask.StallTime or 0) < 16
        )
    local structureTaskCovered = IsStructureTaskCovered(ecoStructureTask) and IsStructureTaskCovered(defenseStructureTask)
    ctx.fieldTaskWindow = (contestFieldMode or reclaimSignalMode or desiredReclaimQuota > 0)
        and (not severeFactoryStarve or reclaimStarveOverride)
        and not ecoCrash
        and (factoryTaskStable or fieldPriorityOverride or desiredReclaimQuota > 0)
        and (structureTaskStable or fieldPriorityOverride or desiredReclaimQuota > 0)
        and (fieldBaseReady or fieldPriorityOverride or (desiredReclaimQuota > 0 and firstReclaimBaseReady))
        and fieldTaskQuota > 0
    for _, eng in engineers do
        ProcessEngineer(aiBrain, runtime, eng, now, ctx)
    end

    local radarOrderActive = next(radarReservedBuilderIds) ~= nil
    local allowExpandWhileRadarPending = radarCritical
        and not structureTask.Active
        and radarOrderActive
        and table.getn(engineers or {}) >= math.max(baseFloor + 3, 6)

    local expansionOverride = engState.MexEmergencyActive == true
        or (policy.ForwardContestBias == true and mexReady < 12)
        or (planner.OuterRetentionActive == true and mexReady < 14)
        or (policy.EngineerExpansionQuota or 0) >= 2
    local canDispatchEconOk = expansionOverride
        or ((eco.MassTrend or 0) > -0.55 and (eco.EnergyTrend or 0) > -28)
    local canDispatchBaseOk = baseEngineers >= math.max(2, baseFloor - 2)
        or expansionOverride
    local canDispatchExpand = now >= 60
        and not severeFactoryStarve
        and not ecoCrash
        and (not recovery.ForceBaseEngineerRecovery or expansionOverride)
        and (not factoryTask.Active or expansionOverride)
        and (not structureTask.Active or expansionOverride)
        and (not radarCritical or allowExpandWhileRadarPending)
        and (not (bomberWatch and currentRadar <= 0) or allowExpandWhileRadarPending)
        and not raid.ExposedMexUnderAirRaid
        and not (bomberPanic and table.getn(engineers or {}) <= math.max(4, baseFloor + 1))
        and canDispatchBaseOk
        and canDispatchEconOk
    if canDispatchExpand then
        local threatCap = 1.2
        if now >= 240 then
            threatCap = 1.35
        end
        if (runtime.ZoneModel and (runtime.ZoneModel.MapControl or 0) < 0.26) or now >= 420 then
            threatCap = 1.55
        end
        if (policy.ForwardContestBias == true) or hqPressureEscape then
            threatCap = threatCap + 0.15
        end
        if expansionOverride then
            threatCap = threatCap + 0.25
        end
        expansionGateReason = 'called'
        ctx.dispatchedExpand = (ctx.dispatchedExpand or 0)
            + CallDispatchExpansionEngineer(aiBrain, runtime, now, engineers, mainPos, enemyPos, math.max(420, safeExpandDistance), threatCap)
    elseif expansionOverride and expansionGateReason == 'none' then
        expansionGateReason = now < 60 and 'time'
            or severeFactoryStarve and 'factory_starve'
            or ecoCrash and 'eco_crash'
            or (recovery.ForceBaseEngineerRecovery and not expansionOverride) and 'base_recovery'
            or (factoryTask.Active and not expansionOverride) and 'factory_task'
            or (structureTask.Active and not expansionOverride) and 'structure_task'
            or (radarCritical and not allowExpandWhileRadarPending) and 'radar'
            or ((bomberWatch and currentRadar <= 0) and not allowExpandWhileRadarPending) and 'bomber_watch'
            or raid.ExposedMexUnderAirRaid and 'air_raid'
            or (bomberPanic and table.getn(engineers or {}) <= math.max(4, baseFloor + 1)) and 'bomber_panic'
            or not canDispatchBaseOk and 'base_floor'
            or not canDispatchEconOk and 'trend'
            or 'blocked'
    end
    runtime.LastExpansionGateReason = expansionGateReason

    local factoryCounts = current.Factories or {}
    local readyFactories = factoryCounts.Ready
        or (((factoryCounts.Land or {}).Ready) or 0)
            + (((factoryCounts.Air or {}).Ready) or 0)
            + (((factoryCounts.Navy or {}).Ready) or 0)
    local totalEngineers = table.getn(engineers or {})
    local timeEngineerFloor = 6
    if now >= 300 then
        timeEngineerFloor = 9
    end
    if now >= 600 then
        timeEngineerFloor = 12
    end
    if now >= 960 then
        timeEngineerFloor = 16
    end
    local scaledEngineerFloor = math.max(
        constraints.StarterEngineerFloor or 6,
        timeEngineerFloor,
        math.floor((readyFactories or 1) * ((policy.EngineerFactoryRatio or 1.0) + 2.1)))
    if (policy.EngineerReclaimQuota or 0) > 0 or policy.ReclaimPressureMode == true then
        scaledEngineerFloor = scaledEngineerFloor + 2
    end
    if engState.MexEmergencyActive == true then
        scaledEngineerFloor = scaledEngineerFloor + 2
    end

    local demand = runtime.EngineerDemand or {}
    runtime.EngineerDemand = demand
    local acuRepairWanted = GetACURepairNeed(aiBrain, runtime, mainPos, now)
    demand.LastUpdate = now
    demand.PendingFactoryOrders = 0
    demand.InitialMexBuildersWanted = (now < 420 and mexReady < math.max(4, constraints.StarterMexFloor or 4))
        and math.max(1, math.min(3, math.max(4, constraints.StarterMexFloor or 4) - mexReady))
        or 0
    demand.FactoryFinishWanted = factoryTask.Active and math.max(0, (factoryTask.RequiredBuilders or 0) - (factoryTask.AssignedBuilders or 0)) or 0
    demand.StructureFinishWanted = math.max(0, (ecoStructureTask.RequiredBuilders or 0) - (ecoStructureTask.AssignedBuilders or 0))
        + math.max(0, (defenseStructureTask.RequiredBuilders or 0) - (defenseStructureTask.AssignedBuilders or 0))
    demand.BaseWanted = math.max(0, baseFloor - baseEngineers)
    demand.ReclaimWanted = math.max(0, fieldTaskQuota - (ctx.reclaimField or 0))
    demand.ExpansionWanted = math.max(0, (policy.EngineerExpansionQuota or 1) - (ctx.dispatchedExpand or 0))
    if not canDispatchExpand and not engState.MexEmergencyActive then
        demand.ExpansionWanted = math.min(demand.ExpansionWanted, 1)
    end
    demand.PowerWanted = (hqPowerRecoveryWanted or macro.NeedPowerRecovery == true or constraints.PowerBufferLow == true)
        and math.max(1, (ecoStructureTask.Active and ecoStructureTask.Kind == 'Power')
            and math.max(0, (ecoStructureTask.RequiredBuilders or 0) - (ecoStructureTask.AssignedBuilders or 0))
            or 1)
        or 0
    demand.ACURepairWanted = acuRepairWanted
    demand.SpareWanted = math.max(0, scaledEngineerFloor - totalEngineers)
    demand.TotalWanted = math.max(
        demand.SpareWanted,
        demand.InitialMexBuildersWanted
            + demand.FactoryFinishWanted
            + demand.StructureFinishWanted
            + demand.BaseWanted
            + demand.ReclaimWanted
            + demand.ExpansionWanted
            + demand.PowerWanted
            + demand.ACURepairWanted)
    demand.CurrentEngineers = totalEngineers
    demand.TargetEngineers = scaledEngineerFloor
    demand.Reason = demand.InitialMexBuildersWanted > 0 and 'opening_mex'
        or demand.FactoryFinishWanted > 0 and 'factory_finish'
        or demand.StructureFinishWanted > 0 and (structureTask.Kind or 'structure_finish')
        or demand.ACURepairWanted > 0 and 'acu_repair'
        or demand.ReclaimWanted > 0 and 'reclaim'
        or demand.ExpansionWanted > 0 and 'expansion'
        or demand.PowerWanted > 0 and 'power'
        or demand.SpareWanted > 0 and 'floor'
        or 'satisfied'

    runtime.LastEngineerRecovered = ctx.recoverCount
    runtime.LastEngineerThreatRecalls = ctx.threatenedCount
    runtime.LastEngineerFactoryRecalls = ctx.forcedFactoryRecover
    runtime.LastEngineerStructureRecover = (ecoStructureTask.AssignedBuilders or 0) + (defenseStructureTask.AssignedBuilders or 0)
    runtime.LastEngineerExpandDispatch = ctx.dispatchedExpand
    runtime.LastEngineerEnemyMexReclaim = ctx.reclaimEnemyMex
    runtime.LastEngineerReclaimField = ctx.reclaimField
    runtime.LastEngineerPowerRecovery = ctx.powerRecoveryCount
    runtime.LastEngineerSurplusSpend = ctx.surplusSpendCount
    runtime.LastEngineerACURepair = ctx.acuRepairCount

    local activity = CountEngineerActivity(engineers, IsIdle, IsConstructing)
    activity.BaseEngineers = baseEngineers
    activity.NeedBase = math.max(0, baseFloor - baseEngineers)
    activity.RecoverCount = ctx.recoverCount
    activity.ThreatRecallCount = ctx.threatenedCount
    activity.FactoryRecoverCount = ctx.forcedFactoryRecover
    activity.StructureRecoverCount = (ecoStructureTask.AssignedBuilders or 0) + (defenseStructureTask.AssignedBuilders or 0)
    activity.ExpansionDispatchCount = ctx.dispatchedExpand
    activity.ReclaimFieldCount = ctx.reclaimField
    activity.ReclaimEnemyMexCount = ctx.reclaimEnemyMex
    activity.PowerRecoveryCount = ctx.powerRecoveryCount
    activity.SurplusSpendCount = ctx.surplusSpendCount
    activity.ACURepairCount = ctx.acuRepairCount
    activity.ReclaimQuota = fieldTaskQuota
    activity.ExpansionCandidates = runtime.LastExpansionCandidateCount or 0
    activity.ExpansionBusySkip = runtime.LastExpansionBusySkipCount or 0
    activity.ExpansionNoTarget = runtime.LastExpansionNoTargetCount or 0
    activity.ExpansionEscortBlocked = runtime.LastExpansionEscortBlockedCount or 0
    activity.ExpansionGateReason = runtime.LastExpansionGateReason or 'none'
    activity.ExpansionInternalGate = runtime.LastExpansionInternalGateReason or 'none'
    activity.ExpansionDispatchAvailable = runtime.EngineerDirectorExpansionDispatchAvailable == true
    local blockedReason = severeFactoryStarve and 'factory_starve'
        or ecoCrash and 'eco_crash'
        or fieldTaskQuota <= 0 and 'no_reclaim_quota'
        or 'none'
    activity.BlockedReason = blockedReason
    OvermindEconomyLedger.PublishEngineerActivity(aiBrain, runtime, now, activity)

    local shouldLog = (ctx.recoverCount + ctx.threatenedCount + ctx.forcedFactoryRecover + ctx.dispatchedExpand + ctx.reclaimEnemyMex + ctx.reclaimField) > 0
        or ctx.powerRecoveryCount > 0
        or ctx.acuRepairCount > 0
        or ctx.surplusSpendCount > 0
        or factoryTask.Active
        or ecoStructureTask.Active
        or defenseStructureTask.Active
        or demand.ExpansionWanted > 0
        or demand.ReclaimWanted > 0
    if shouldLog and (now - (runtime.LastEngineerDirectorLogTime or -999)) >= 20 then
        runtime.LastEngineerDirectorLogTime = now
        local structureTaskMode = structureTask.Active and DescribeStructureTaskTarget(structureTargetObject) or 'none'
        local structureNearby = 0
        local sx = 0
        local sz = 0
        if structureTask.Active and structureTask.TargetPos then
            sx = structureTask.TargetPos[1] or 0
            sz = structureTask.TargetPos[3] or 0
            structureNearby = aiBrain:GetNumUnitsAroundPoint(categories.ENGINEER * categories.MOBILE, structureTask.TargetPos, 18, 'Ally') or 0
        end
        LOG(string.format('*OVERMIND ENGDIR A%d t=%.1f recover=%d threat=%d facRec=%d powerRec=%d surp=%d expand=%d gate=%s inner=%s expAvail=%d cand=%d busy=%d noT=%d esc=%d field=%d quota=%d block=%s baseNeed=%d facTask=%d:%s frac=%.2f stall=%.1f asn=%d/%d structTask=%d:%s:%s frac=%.2f stall=%.1f asn=%d/%d eco=%d:%s asn=%d/%d def=%d:%s asn=%d/%d near=%d pos=%.1f,%.1f acuRep=%d/%d',
            aiBrain:GetArmyIndex(),
            now,
            ctx.recoverCount,
            ctx.threatenedCount,
            ctx.forcedFactoryRecover,
            ctx.powerRecoveryCount,
            ctx.surplusSpendCount,
            ctx.dispatchedExpand,
            runtime.LastExpansionGateReason or 'none',
            runtime.LastExpansionInternalGateReason or 'none',
            runtime.EngineerDirectorExpansionDispatchAvailable and 1 or 0,
            runtime.LastExpansionCandidateCount or 0,
            runtime.LastExpansionBusySkipCount or 0,
            runtime.LastExpansionNoTargetCount or 0,
            runtime.LastExpansionEscortBlockedCount or 0,
            ctx.reclaimField,
            fieldTaskQuota,
            blockedReason,
            math.max(0, baseFloor - baseEngineers),
            factoryTask.Active and 1 or 0,
            factoryTask.Domain or 'none',
            factoryTask.TargetFraction or 1,
            factoryTask.StallTime or 0,
            factoryTask.AssignedBuilders or 0,
            factoryTask.RequiredBuilders or 0,
            structureTask.Active and 1 or 0,
            structureTask.Kind or 'none',
            structureTaskMode,
            structureTask.TargetFraction or 1,
            structureTask.StallTime or 0,
            structureTask.AssignedBuilders or 0,
            structureTask.RequiredBuilders or 0,
            ecoStructureTask.Active and 1 or 0,
            ecoStructureTask.Kind or 'none',
            ecoStructureTask.AssignedBuilders or 0,
            ecoStructureTask.RequiredBuilders or 0,
            defenseStructureTask.Active and 1 or 0,
            defenseStructureTask.Kind or 'none',
            defenseStructureTask.AssignedBuilders or 0,
            defenseStructureTask.RequiredBuilders or 0,
            structureNearby,
            sx,
            sz,
            ctx.acuRepairCount or 0,
            demand.ACURepairWanted or 0))
    end
end
