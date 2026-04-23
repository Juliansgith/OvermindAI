local Common = import('/mods/OvermindAI/lua/AI/Overmind/EngineerDirector/Common.lua')
local Threat = import('/mods/OvermindAI/lua/AI/Overmind/EngineerDirector/Threat.lua')
local Policy = import('/mods/OvermindAI/lua/AI/Overmind/EngineerDirector/Policy.lua')
local Expansion = import('/mods/OvermindAI/lua/AI/Overmind/EngineerDirector/Expansion.lua')
local Recovery = import('/mods/OvermindAI/lua/AI/Overmind/EngineerDirector/Recovery.lua')
local Assignments = import('/mods/OvermindAI/lua/AI/Overmind/EngineerDirector/Assignments.lua')

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
        end
        error(string.format('EngineerDirectorModular missing %s[%s]', tostring(moduleName), tostring(methodName)))
    end
    return fn
end

function Update(aiBrain, now)
    local runtime = aiBrain.OvermindRuntime
    if not runtime then
        return
    end

    local GetMainPos = ResolveMethod(Common, 'GetMainPos', 'Common')
    local GetEntityId = ResolveMethod(Common, 'GetEntityId', 'Common')
    local GetFraction = ResolveMethod(Common, 'GetFraction', 'Common')
    local CleanupExpansionReservations = (type(Expansion) == 'table' and Expansion.CleanupExpansionReservations) or function() end
    local NeedsCriticalRadar = (type(Policy) == 'table' and Policy.NeedsCriticalRadar) or function() return false end
    local GetRadarReservedBuilderIds = (type(Policy) == 'table' and Policy.GetRadarReservedBuilderIds) or function() return {} end
    local FindBestUnfinishedFactory = (type(Recovery) == 'table' and Recovery.FindBestUnfinishedFactory) or function() return false, false, 1, 'none', 0 end
    local ComputeFactoryTaskRequirements = (type(Recovery) == 'table' and Recovery.ComputeFactoryTaskRequirements) or function() return 1 end
    local ResetFactoryTask = (type(Recovery) == 'table' and Recovery.ResetFactoryTask) or function(task)
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
    end
    local ShouldForceFinishEcoStructure = (type(Recovery) == 'table' and Recovery.ShouldForceFinishEcoStructure) or function() return false, false, false end
    local FindTrackedUnfinishedStructure = (type(Recovery) == 'table' and Recovery.FindTrackedUnfinishedStructure) or function() return false, false, 1, 'none', 0 end
    local FindBestUnfinishedStructure = (type(Recovery) == 'table' and Recovery.FindBestUnfinishedStructure) or function() return false, false, 1, 'none', 0 end
    local ShouldKeepTrackedStructureTask = (type(Recovery) == 'table' and Recovery.ShouldKeepTrackedStructureTask) or function() return false end
    local ComputeStructureTaskRequirements = (type(Recovery) == 'table' and Recovery.ComputeStructureTaskRequirements) or function() return 1 end
    local ResetStructureTask = (type(Recovery) == 'table' and Recovery.ResetStructureTask) or function(task)
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
    end
    local AssignBuildersToUnfinishedFactory = (type(Assignments) == 'table' and Assignments.AssignBuildersToUnfinishedFactory) or function() return 0, {}, false, { Total = 0, Safe = 0, Reachable = 0, Interruptible = 0 } end
    local AssignBuildersToUnfinishedStructure = (type(Assignments) == 'table' and Assignments.AssignBuildersToUnfinishedStructure) or function() return 0, {}, false, { Total = 0, Safe = 0, Reachable = 0, Interruptible = 0 } end
    local ProcessEngineer = (type(Assignments) == 'table' and Assignments.ProcessEngineer) or function() end
    local DescribeStructureTaskTarget = (type(Assignments) == 'table' and Assignments.DescribeStructureTaskTarget) or function() return 'none' end
    local DispatchExpansionEngineer = (type(Expansion) == 'table' and Expansion.DispatchExpansionEngineer) or function() return 0 end

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
    if mexRebuildUrgent then
        safeExpandDistance = math.max(safeExpandDistance, 920)
    elseif mexExpansionUrgent then
        safeExpandDistance = math.max(safeExpandDistance, 860)
    end
    engState.MexEmergencyRebuild = mexRebuildUrgent and true or false
    engState.MexEmergencyActive = (mexRebuildUrgent or mexExpansionUrgent) and true or false
    if mexRebuildUrgent then
        recovery.ForceDefenseRecovery = true
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
    local currentRadar = ((((runtime.ProductionDirector or {}).Current or {}).Structures or {}).Radar) or 0
    local bomberWatch = constraints.BomberWatch == true
    local bomberPanic = ((raid.BomberPanicUntil or -999) > now) or ((raid.LastBomberEnemyCount or 0) >= 1 and raid.UnderAirHarass)
    local radarReservedBuilderIds = GetRadarReservedBuilderIds(runtime, now)
    local hqPowerRecoveryWanted = ((((runtime.UpgradeDirector or {}).Factory) or {}).PowerRecoveryWanted) == true

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

        local assignedBuilders, claimedBuilders, usedCommander, debug = AssignBuildersToUnfinishedFactory(
            aiBrain,
            runtime,
            now,
            target,
            targetPos,
            domain,
            readyFactories,
            factoryTask.StallTime or 0,
            radarReservedBuilderIds)
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
    local forceFinishEco, forcedEcoTarget, forcedEcoKind = ShouldForceFinishEcoStructure(aiBrain, runtime, mainPos, false, false)
    if (not factoryTaskCritical) or forceFinishEco then
        local trackedStructure, trackedPos, trackedFraction, trackedKind, trackedPriority = FindTrackedUnfinishedStructure(aiBrain, structureTask)
        local structure, structurePos, structureFraction, structureKind, structurePriority = FindBestUnfinishedStructure(aiBrain, runtime, mainPos)

        if forceFinishEco and forcedEcoTarget and not forcedEcoTarget.Dead then
            local forcedPos = forcedEcoTarget.GetPosition and forcedEcoTarget:GetPosition() or false
            if forcedPos then
                structure = forcedEcoTarget
                structurePos = forcedPos
                structureFraction = GetFraction(forcedEcoTarget)
                structureKind = forcedEcoKind or 'Structure'
                structurePriority = 1000 + (structureFraction * 100)
            end
        end

        if trackedStructure and trackedPos then
            local trackedTargetId = GetEntityId(trackedStructure)
            local bestTargetId = structure and GetEntityId(structure) or false
            if ShouldKeepTrackedStructureTask(
                now,
                structureTask,
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

        if structure and structurePos then
            structureTargetObject = structure
            local targetId = GetEntityId(structure)
            if structureTask.TargetId ~= targetId or structureFraction > ((structureTask.TargetFraction or 0) + 0.01) then
                structureTask.TargetId = targetId
                structureTask.TargetPos = structurePos
                structureTask.TargetFraction = structureFraction
                structureTask.LastProgressTime = now
            end
            structureTask.Active = true
            structureTask.Kind = structureKind
            structureTask.Priority = structurePriority
            structureTask.StallTime = now - (structureTask.LastProgressTime or now)
            structureTask.RequiredBuilders = ComputeStructureTaskRequirements(structureKind, structureFraction, structureTask.StallTime or 0, eco)
            structureTask.TargetPos = structurePos
            structureTask.TargetFraction = structureFraction

            local assignedBuilders, claimedBuilders, usedCommander, debug = AssignBuildersToUnfinishedStructure(
                aiBrain,
                runtime,
                now,
                structure,
                structurePos,
                structureKind,
                structureTask.StallTime or 0,
                reservedStructureBuilderIds)

            if assignedBuilders <= 0
                and trackedStructure
                and trackedPos
                and GetEntityId(trackedStructure) ~= targetId then
                local fallbackAssigned, fallbackClaimed, fallbackCommander, fallbackDebug = AssignBuildersToUnfinishedStructure(
                    aiBrain,
                    runtime,
                    now,
                    trackedStructure,
                    trackedPos,
                    trackedKind,
                    structureTask.StallTime or 0,
                    reservedStructureBuilderIds)
                if fallbackAssigned > 0 then
                    structure = trackedStructure
                    structureTargetObject = trackedStructure
                    structurePos = trackedPos
                    structureFraction = trackedFraction
                    structureKind = trackedKind
                    structurePriority = trackedPriority
                    targetId = GetEntityId(trackedStructure)
                    structureTask.TargetId = targetId
                    structureTask.TargetPos = trackedPos
                    structureTask.TargetFraction = trackedFraction
                    structureTask.Kind = trackedKind
                    structureTask.Priority = trackedPriority
                    assignedBuilders = fallbackAssigned
                    claimedBuilders = fallbackClaimed
                    usedCommander = fallbackCommander
                    debug = fallbackDebug
                end
            end

            structureTask.AssignedBuilders = assignedBuilders
            structureTask.BuilderIds = claimedBuilders
            structureTask.UsedCommander = usedCommander and true or false
            structureTask.CandidateDebug = debug
            local stickyDuration = 10
            if structureKind == 'Mex' or structureKind == 'Power' then
                stickyDuration = 16
            elseif structureKind == 'Radar' then
                stickyDuration = 14
            elseif structureKind == 'AA' or structureKind == 'Defense' then
                stickyDuration = 24
            elseif string.lower(structureKind or 'none') == 'structure' then
                stickyDuration = 20
            end
            if structureFraction >= 0.45 then
                stickyDuration = stickyDuration + 6
            end
            if structureFraction >= 0.72 then
                stickyDuration = stickyDuration + 10
            end
            local earlyStickyFraction = 0.35
            if structureKind == 'AA' or structureKind == 'Defense' then
                earlyStickyFraction = 0.18
            elseif string.lower(structureKind or 'none') == 'structure' then
                earlyStickyFraction = 0.5
            end
            if assignedBuilders > 0 or structureFraction >= earlyStickyFraction then
                structureTask.StickyUntil = math.max(structureTask.StickyUntil or -999, now + stickyDuration)
            end
            if structureKind == 'Power' and structureFraction >= 0.8 then
                structureTask.StickyUntil = math.max(structureTask.StickyUntil or -999, now + stickyDuration + 10)
            elseif structureKind == 'Power' and structureFraction >= 0.35 then
                structureTask.StickyUntil = math.max(structureTask.StickyUntil or -999, now + stickyDuration + 16)
            elseif structureKind == 'Mex' and structureFraction >= 0.35 then
                structureTask.StickyUntil = math.max(structureTask.StickyUntil or -999, now + stickyDuration + 14)
            end
            if transitionLock
                and structureTask.Active
                and (structureTask.Kind == 'AA' or structureTask.Kind == 'Defense' or string.lower(structureTask.Kind or 'none') == 'structure')
                and not radarCritical then
                ResetStructureTask(structureTask)
                structureTargetObject = false
            end
        else
            ResetStructureTask(structureTask)
        end
    else
        ResetStructureTask(structureTask)
    end

    if structureTask.Active and structureTask.TargetId then
        local trackedStructure, trackedPos = FindTrackedUnfinishedStructure(aiBrain, structureTask)
        if trackedStructure and trackedPos then
            structureTargetObject = trackedStructure
        end
    end

    local factoryTaskStable = (not factoryTask.Active)
        or (
            (factoryTask.AssignedBuilders or 0) >= math.max(1, math.min(2, (factoryTask.RequiredBuilders or 0)))
            and (factoryTask.StallTime or 0) < 18
        )
    local structureTaskStable = (not structureTask.Active)
        or (
            (structureTask.AssignedBuilders or 0) >= math.max(1, math.min(2, (structureTask.RequiredBuilders or 0)))
            and (structureTask.StallTime or 0) < 20
        )
    local fieldBaseReady = baseEngineers >= math.max(3, baseFloor)
    engState.ReclaimFieldStickyUntil = engState.ReclaimFieldStickyUntil or -999
    engState.ReclaimFieldStickyQuota = engState.ReclaimFieldStickyQuota or 0
    local fieldStickyActive = now < (engState.ReclaimFieldStickyUntil or -999)
    local fieldTaskQuota = 0
    if contestFieldMode
        and reclaimFieldPos
        and fieldBaseReady
        and not ecoCrash
        and not severeFactoryStarve
        and factoryTaskStable
        and structureTaskStable then
        if (planner.ReclaimFirst == true or planner.OuterRetentionActive == true or outerContestUnits > 0)
            and reclaimFieldScore >= 90 then
            fieldTaskQuota = 1
        end
        if reclaimFieldScore >= 180
            and outerContestUnits >= 1
            and baseEngineers >= (baseFloor + 2) then
            fieldTaskQuota = 2
        end
    end
    if fieldTaskQuota > 0 then
        engState.ReclaimFieldStickyUntil = now + 48
        engState.ReclaimFieldStickyQuota = math.max(engState.ReclaimFieldStickyQuota or 0, fieldTaskQuota)
        fieldStickyActive = true
    elseif fieldStickyActive
        and contestFieldMode
        and reclaimFieldPos
        and fieldBaseReady
        and not ecoCrash
        and not severeFactoryStarve
        and factoryTaskStable
        and structureTaskStable then
        fieldTaskQuota = math.max(1, engState.ReclaimFieldStickyQuota or 1)
    else
        engState.ReclaimFieldStickyUntil = -999
        engState.ReclaimFieldStickyQuota = 0
        fieldStickyActive = false
    end

    local ctx = {
        bomberPanic = bomberPanic,
        constraints = constraints,
        contestFieldMode = contestFieldMode,
        dispatchedExpand = 0,
        enemyPos = enemyPos,
        factoryTargetObject = factoryTargetObject,
        factoryTask = factoryTask,
        forcedFactoryRecover = factoryTask.AssignedBuilders or 0,
        hqPowerRecoveryWanted = hqPowerRecoveryWanted,
        macroNeedPowerRecovery = macro.NeedPowerRecovery == true,
        macroPhase = macroPhase,
        mainPos = mainPos,
        needBase = needBase,
        powerRecoveryCount = 0,
        radarReservedBuilderIds = radarReservedBuilderIds,
        raid = raid,
        reclaimEnemyMex = 0,
        reclaimField = 0,
        reclaimFieldPos = reclaimFieldPos,
        recoverCount = 0,
        safeExpandDistance = safeExpandDistance,
        severeFactoryStarve = severeFactoryStarve,
        structureTargetObject = structureTargetObject,
        structureTask = structureTask,
        surplusSpendCount = 0,
        threatenedCount = 0,
        transitionLock = transitionLock,
        fieldTaskQuota = fieldTaskQuota,
        mexRebuildUrgent = mexRebuildUrgent,
    }
    local factoryTaskCovered = (not factoryTask.Active)
        or (
            (factoryTask.AssignedBuilders or 0) >= math.max(1, (factoryTask.RequiredBuilders or 0))
            and (factoryTask.StallTime or 0) < 16
        )
    local structureTaskCovered = (not structureTask.Active)
        or (
            (structureTask.Kind == 'Mex' or structureTask.Kind == 'Power')
            and (structureTask.AssignedBuilders or 0) >= math.max(1, (structureTask.RequiredBuilders or 0))
            and (structureTask.StallTime or 0) < 18
        )
        or (
            (structureTask.Kind ~= 'Mex' and structureTask.Kind ~= 'Power')
            and (structureTask.AssignedBuilders or 0) >= math.max(1, (structureTask.RequiredBuilders or 0))
            and (structureTask.StallTime or 0) < 12
        )
    ctx.fieldTaskWindow = contestFieldMode
        and not severeFactoryStarve
        and not ecoCrash
        and factoryTaskStable
        and structureTaskStable
        and fieldBaseReady
        and fieldTaskQuota > 0
    for _, eng in engineers do
        ProcessEngineer(aiBrain, runtime, eng, now, ctx)
    end

    local radarOrderActive = next(radarReservedBuilderIds) ~= nil
    local allowExpandWhileRadarPending = radarCritical
        and not structureTask.Active
        and radarOrderActive
        and table.getn(engineers or {}) >= math.max(baseFloor + 3, 6)

    local canDispatchExpand = now >= 60
        and not severeFactoryStarve
        and not ecoCrash
        and not recovery.ForceBaseEngineerRecovery
        and not factoryTask.Active
        and not structureTask.Active
        and (not radarCritical or allowExpandWhileRadarPending)
        and (not (bomberWatch and currentRadar <= 0) or allowExpandWhileRadarPending)
        and not raid.ExposedMexUnderAirRaid
        and not (bomberPanic and table.getn(engineers or {}) <= math.max(4, baseFloor + 1))
        and baseEngineers >= math.max(2, baseFloor - 2)
        and (eco.MassTrend or 0) > -0.55
        and (eco.EnergyTrend or 0) > -28
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
        ctx.dispatchedExpand = DispatchExpansionEngineer(aiBrain, runtime, now, engineers, mainPos, enemyPos, math.max(420, safeExpandDistance), threatCap)
    end

    runtime.LastEngineerRecovered = ctx.recoverCount
    runtime.LastEngineerThreatRecalls = ctx.threatenedCount
    runtime.LastEngineerFactoryRecalls = ctx.forcedFactoryRecover
    runtime.LastEngineerStructureRecover = structureTask.AssignedBuilders or 0
    runtime.LastEngineerExpandDispatch = ctx.dispatchedExpand
    runtime.LastEngineerEnemyMexReclaim = ctx.reclaimEnemyMex
    runtime.LastEngineerReclaimField = ctx.reclaimField
    runtime.LastEngineerPowerRecovery = ctx.powerRecoveryCount
    runtime.LastEngineerSurplusSpend = ctx.surplusSpendCount

    local shouldLog = (ctx.recoverCount + ctx.threatenedCount + ctx.forcedFactoryRecover + ctx.dispatchedExpand + ctx.reclaimEnemyMex + ctx.reclaimField) > 0
        or ctx.powerRecoveryCount > 0
        or ctx.surplusSpendCount > 0
        or factoryTask.Active
        or structureTask.Active
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
        LOG(string.format('*OVERMIND ENGDIR A%d t=%.1f recover=%d threat=%d facRec=%d powerRec=%d surp=%d expand=%d field=%d baseNeed=%d facTask=%d:%s frac=%.2f stall=%.1f asn=%d/%d structTask=%d:%s:%s frac=%.2f stall=%.1f asn=%d/%d near=%d pos=%.1f,%.1f',
            aiBrain:GetArmyIndex(),
            now,
            ctx.recoverCount,
            ctx.threatenedCount,
            ctx.forcedFactoryRecover,
            ctx.powerRecoveryCount,
            ctx.surplusSpendCount,
            ctx.dispatchedExpand,
            ctx.reclaimField,
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
            structureNearby,
            sx,
            sz))
    end
end
