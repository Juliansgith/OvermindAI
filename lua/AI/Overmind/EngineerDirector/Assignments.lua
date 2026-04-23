local Common = import('/mods/OvermindAI/lua/AI/Overmind/EngineerDirector/Common.lua')
local Threat = import('/mods/OvermindAI/lua/AI/Overmind/EngineerDirector/Threat.lua')
local Reclaim = import('/mods/OvermindAI/lua/AI/Overmind/EngineerDirector/Reclaim.lua')
local Recovery = import('/mods/OvermindAI/lua/AI/Overmind/EngineerDirector/Recovery.lua')
local OvermindMemory = import('/mods/OvermindAI/lua/AI/Overmind/Memory.lua')

local BuilderCategory = categories.ENGINEER * categories.MOBILE + categories.COMMAND


local M = {}

local function ScoreFactoryBuilder(unit, dist, busy, alreadyAssigned, isCommander, qLen, criticalDomain)
    local score = -dist
    if alreadyAssigned then
        score = score + 320
    elseif not busy then
        score = score + 140
    else
        score = score + math.max(0, 42 - (qLen * 6))
    end
    if isCommander then
        score = score + ((criticalDomain == 'Land') and 55 or 15)
    end
    return score
end


local function ScoreStructureBuilder(dist, busy, alreadyAssigned, isCommander, qLen, kind)
    local score = -dist
    if alreadyAssigned then
        score = score + 320
    elseif not busy then
        score = score + 150
    else
        score = score + math.max(0, 46 - (qLen * 8))
    end
    if isCommander then
        if kind == 'Mex' or kind == 'Power' or kind == 'Radar' then
            score = score + 30
        else
            score = score + 12
        end
    end
    return score
end

local function AssignBuildersToUnfinishedFactory(aiBrain, runtime, now, target, targetPos, domain, readyFactories, stallTime, reservedBuilderIds)
    local builders = aiBrain:GetListOfUnits(BuilderCategory, false, true) or {}
    if table.getn(builders) <= 0 then
        return 0, {}, false, { Total = 0, Safe = 0, Reachable = 0, Interruptible = 0 }
    end

    local eco = runtime.EcoState or {}
    local recovery = runtime.Recovery or {}
    local mainPos = Common.GetMainPos(aiBrain, runtime)
    local targetThreat = aiBrain:GetThreatAtPosition(targetPos, 1, true, 'AntiSurface') or 0
    local openingFactoryFloor = string.lower(domain or 'none') == 'land'
        and readyFactories <= 0
        and now < 180
        and mainPos
        and Common.Distance2D(targetPos, mainPos) <= 120
        and not Threat.HasEnemyCombatNear(aiBrain, targetPos, 42)
    local stickyLandFinish = string.lower(domain or 'none') == 'land'
        and mainPos
        and Common.Distance2D(targetPos, mainPos) <= 260
        and Common.GetFraction(target) >= 0.18
        and not Threat.HasEnemyCombatNear(aiBrain, targetPos, 52)
    local requiredBuilders = Recovery.ComputeFactoryTaskRequirements(domain, Common.GetFraction(target), stallTime, readyFactories, eco)
    if openingFactoryFloor then
        requiredBuilders = math.max(2, math.min(3, requiredBuilders))
    elseif stickyLandFinish then
        requiredBuilders = math.max(requiredBuilders, math.min(4, readyFactories <= 1 and 3 or 2))
    end
    local forceInterrupt = stallTime >= 4 or readyFactories <= 0 or recovery.ForceFactoryRecovery or openingFactoryFloor or stickyLandFinish

    local dispatchRadius = 240
    if stallTime >= 6 then
        dispatchRadius = 420
    end
    if stallTime >= 14 then
        dispatchRadius = 760
    end
    if stallTime >= 28 then
        dispatchRadius = 960
    end
    if stickyLandFinish then
        dispatchRadius = math.max(dispatchRadius, 620)
    end

    local interruptQCap = 0
    if forceInterrupt then
        interruptQCap = 2
    end
    if stallTime >= 10 then
        interruptQCap = 5
    end
    if readyFactories <= 0 and domain == 'Land' then
        interruptQCap = math.max(interruptQCap, 8)
    end
    if stickyLandFinish then
        interruptQCap = math.max(interruptQCap, 6)
    end

    local candidates = {}
    local debug = {
        Total = 0,
        Safe = 0,
        Reachable = 0,
        Interruptible = 0,
    }
    local targetId = Common.GetEntityId(target)

    for _, unit in builders do
        if unit and not unit.Dead then
            debug.Total = debug.Total + 1
            local entityId = Common.GetEntityId(unit)
            if not (reservedBuilderIds and entityId and reservedBuilderIds[entityId]) then
                local pos = unit.GetPosition and unit:GetPosition() or false
                if pos then
                    local dist = Common.Distance2D(pos, targetPos)
                    local q = unit.GetCommandQueue and unit:GetCommandQueue() or false
                    local qLen = q and table.getn(q) or 0
                    local busy = qLen > 0 or unit:IsUnitState('Building') or unit:IsUnitState('Repairing') or unit:IsUnitState('Upgrading')
                    local isCommander = EntityCategoryContains(categories.COMMAND, unit)
                    local localThreat = aiBrain:GetThreatAtPosition(pos, 1, true, 'AntiSurface') or 0
                    local safeCap = isCommander and 3.4 or 2.8
                    if stallTime >= 18 then
                        safeCap = safeCap + 0.6
                    end
                    if stickyLandFinish then
                        safeCap = safeCap + 0.5
                    end
                    local safe = localThreat <= safeCap and targetThreat <= (safeCap + 0.8)
                    local openerSafe = openingFactoryFloor
                        and mainPos
                        and Common.Distance2D(pos, mainPos) <= 155
                        and dist <= 145
                        and not Threat.HasEnemyCombatNear(aiBrain, pos, 40)
                    if openerSafe then
                        safe = true
                    end
                    if isCommander and mainPos and Common.Distance2D(pos, mainPos) > 190 then
                        safe = false
                    end

                    if safe then
                        debug.Safe = debug.Safe + 1
                        local reachableRadius = dispatchRadius
                        if isCommander then
                            reachableRadius = math.min(reachableRadius, 220)
                        elseif stickyLandFinish then
                            reachableRadius = math.max(reachableRadius, 640)
                        end
                        local focus = unit.GetFocusUnit and unit:GetFocusUnit() or false
                        local alreadyAssigned = focus and (Common.GetEntityId(focus) == targetId)
                        local interruptible = alreadyAssigned or (not busy) or (forceInterrupt and qLen <= interruptQCap and not unit:IsUnitState('Upgrading'))
                        local reachable = dist <= reachableRadius or alreadyAssigned
                        if reachable then
                            debug.Reachable = debug.Reachable + 1
                        end
                        if reachable and interruptible then
                            debug.Interruptible = debug.Interruptible + 1
                            table.insert(candidates, {
                                Unit = unit,
                                Busy = busy,
                                AlreadyAssigned = alreadyAssigned and true or false,
                                IsCommander = isCommander and true or false,
                                Score = ScoreFactoryBuilder(unit, dist, busy, alreadyAssigned, isCommander, qLen, domain)
                                    + ((openingFactoryFloor and isCommander) and 240 or 0)
                                    + ((openingFactoryFloor and not isCommander and dist <= 90) and 80 or 0)
                                    + ((stickyLandFinish and not isCommander and dist <= 160) and 90 or 0),
                            })
                        end
                    end
                end
            end
        end
    end

    table.sort(candidates, function(a, b)
        return (a.Score or -999999) > (b.Score or -999999)
    end)

    local claimed = {}
    local assigned = 0
    local usedCommander = false
    for _, candidate in candidates do
        if assigned >= requiredBuilders then
            break
        end

        local unit = candidate.Unit
        local entityId = Common.GetEntityId(unit)
        if entityId and not claimed[entityId] then
            claimed[entityId] = true
            assigned = assigned + 1
            if candidate.IsCommander then
                usedCommander = true
            end
            if not candidate.AlreadyAssigned then
                if candidate.Busy and IssueClearCommands then
                    IssueClearCommands({ unit })
                end
                if IssueRepair then
                    IssueRepair({ unit }, target)
                elseif IssueGuard then
                    IssueGuard({ unit }, target)
                end
            end
        end
    end

    if usedCommander then
        runtime.ACUSafetyLockUntil = math.max(runtime.ACUSafetyLockUntil or -999, now + 9)
        runtime.ACUHardBuildLockUntil = math.max(runtime.ACUHardBuildLockUntil or -999, now + 14)
    end

    return assigned, claimed, usedCommander, debug
end

local function AssignBuildersToUnfinishedStructure(aiBrain, runtime, now, target, targetPos, kind, stallTime, reservedBuilderIds)
    local builders = aiBrain:GetListOfUnits(BuilderCategory, false, true) or {}
    if table.getn(builders) <= 0 then
        return 0, {}, false, { Total = 0, Safe = 0, Reachable = 0, Interruptible = 0 }
    end

    local eco = runtime.EcoState or {}
    local mainPos = Common.GetMainPos(aiBrain, runtime)
    local targetThreat = aiBrain:GetThreatAtPosition(targetPos, 1, true, 'AntiSurface') or 0
    local radarCritical = Recovery.NeedsCriticalRadar(runtime)
    local bomberWatch, bomberPanic, exposedMexAirRaid = Threat.ComputeAirThreatFlags(runtime, now)
    local raid = runtime.RaidDefense or {}
    local airThreatened = bomberWatch or bomberPanic or raid.UnderAirHarass or exposedMexAirRaid
    local targetFraction = Common.GetFraction(target)
    local requiredBuilders = Recovery.ComputeStructureTaskRequirements(kind, targetFraction, stallTime, eco)
    local kindLower = string.lower(kind or 'none')
    local forceFinishPower = kind == 'Power'
        and targetFraction >= 0.8
        and (
            (eco.MassStorageRatio or 0) >= 0.12
            or (eco.MassTrend or 0) >= 0.02
            or (eco.EnergyStorageRatio or 0) <= 0.35
            or (((runtime.ProductionDirector or {}).ConstraintState or {}).PowerBufferLow == true)
        )
    local forceInterrupt = stallTime >= 8 or kind == 'Mex' or kind == 'Power' or (kind == 'Radar' and radarCritical)
    if forceFinishPower then
        requiredBuilders = math.max(2, requiredBuilders)
        forceInterrupt = true
    end
    if (kindLower == 'aa' or kindLower == 'defense') and (targetFraction >= 0.15 or stallTime >= 4) then
        requiredBuilders = math.max(2, requiredBuilders)
        forceInterrupt = true
    elseif kindLower == 'structure' and (targetFraction >= 0.45 or stallTime >= 6) then
        requiredBuilders = math.max(2, requiredBuilders)
        forceInterrupt = true
    end
    if kind == 'Radar' and radarCritical then
        requiredBuilders = math.max(2, math.min(3, requiredBuilders + 1))
        forceInterrupt = true
    elseif kind == 'Radar' and airThreatened then
        requiredBuilders = math.max(2, requiredBuilders)
        forceInterrupt = true
    elseif kind == 'AA' and (bomberWatch or bomberPanic or exposedMexAirRaid) then
        requiredBuilders = math.max(2, requiredBuilders)
        forceInterrupt = true
    end

    local dispatchRadius = 220
    if kind == 'Mex' then
        dispatchRadius = 340
    end
    if forceFinishPower then
        dispatchRadius = dispatchRadius + 120
    end
    if kindLower == 'aa' or kindLower == 'defense' then
        dispatchRadius = dispatchRadius + 100
    elseif kindLower == 'structure' and targetFraction >= 0.45 then
        dispatchRadius = dispatchRadius + 120
    end
    if kind == 'Radar' and radarCritical then
        dispatchRadius = dispatchRadius + 180
    elseif kind == 'Radar' and airThreatened then
        dispatchRadius = dispatchRadius + 120
    elseif kind == 'AA' and (bomberWatch or bomberPanic or exposedMexAirRaid) then
        dispatchRadius = dispatchRadius + 100
    end
    if stallTime >= 12 then
        dispatchRadius = dispatchRadius + 140
    end
    if stallTime >= 24 then
        dispatchRadius = dispatchRadius + 220
    end

    local interruptQCap = forceInterrupt and 2 or 0
    if stallTime >= 20 then
        interruptQCap = math.max(interruptQCap, 4)
    end
    if forceFinishPower then
        interruptQCap = math.max(interruptQCap, 4)
    end
    if kindLower == 'aa' or kindLower == 'defense' or (kindLower == 'structure' and targetFraction >= 0.45) then
        interruptQCap = math.max(interruptQCap, 4)
    end
    if kind == 'Radar' and radarCritical then
        interruptQCap = math.max(interruptQCap, 5)
    elseif kind == 'Radar' and airThreatened then
        interruptQCap = math.max(interruptQCap, 4)
    elseif kind == 'AA' and (bomberWatch or bomberPanic or exposedMexAirRaid) then
        interruptQCap = math.max(interruptQCap, 4)
    end

    local candidates = {}
    local debug = {
        Total = 0,
        Safe = 0,
        Reachable = 0,
        Interruptible = 0,
    }
    local targetId = Common.GetEntityId(target)

    for _, unit in builders do
        if unit and not unit.Dead then
            local entityId = Common.GetEntityId(unit)
            if not (reservedBuilderIds and entityId and reservedBuilderIds[entityId]) then
                debug.Total = debug.Total + 1
                local pos = unit.GetPosition and unit:GetPosition() or false
                if pos then
                    local dist = Common.Distance2D(pos, targetPos)
                    local q = unit.GetCommandQueue and unit:GetCommandQueue() or false
                    local qLen = q and table.getn(q) or 0
                    local busy = qLen > 0 or unit:IsUnitState('Building') or unit:IsUnitState('Repairing') or unit:IsUnitState('Upgrading')
                    local isCommander = EntityCategoryContains(categories.COMMAND, unit)
                    local localThreat = aiBrain:GetThreatAtPosition(pos, 1, true, 'AntiSurface') or 0
                    local safeCap = isCommander and 3.2 or 2.6
                    if kind == 'Mex' then
                        safeCap = safeCap + 0.4
                    end
                    if stallTime >= 18 then
                        safeCap = safeCap + 0.5
                    end
                    local safe = localThreat <= safeCap and targetThreat <= (safeCap + 0.8)
                    if isCommander and mainPos and Common.Distance2D(pos, mainPos) > 170 then
                        safe = false
                    end

                    if safe then
                        debug.Safe = debug.Safe + 1
                        local reachableRadius = isCommander and math.min(dispatchRadius, 200) or dispatchRadius
                        local focus = unit.GetFocusUnit and unit:GetFocusUnit() or false
                        local alreadyAssigned = focus and (Common.GetEntityId(focus) == targetId)
                        local interruptible = alreadyAssigned or (not busy) or (forceInterrupt and qLen <= interruptQCap and not unit:IsUnitState('Upgrading'))
                        local reachable = dist <= reachableRadius or alreadyAssigned
                        if reachable then
                            debug.Reachable = debug.Reachable + 1
                        end
                        if reachable and interruptible then
                            debug.Interruptible = debug.Interruptible + 1
                            table.insert(candidates, {
                                Unit = unit,
                                Busy = busy,
                                AlreadyAssigned = alreadyAssigned and true or false,
                                IsCommander = isCommander and true or false,
                                Score = ScoreStructureBuilder(dist, busy, alreadyAssigned, isCommander, qLen, kind),
                            })
                        end
                    end
                end
            end
        end
    end

    table.sort(candidates, function(a, b)
        return (a.Score or -999999) > (b.Score or -999999)
    end)

    local claimed = {}
    local assigned = 0
    local usedCommander = false
    for _, candidate in candidates do
        if assigned >= requiredBuilders then
            break
        end

        local unit = candidate.Unit
        local entityId = Common.GetEntityId(unit)
        if entityId and not claimed[entityId] then
            claimed[entityId] = true
            assigned = assigned + 1
            if candidate.IsCommander then
                usedCommander = true
            end
            if not candidate.AlreadyAssigned then
                if candidate.Busy and IssueClearCommands then
                    IssueClearCommands({ unit })
                end
                if IssueRepair then
                    IssueRepair({ unit }, target)
                elseif IssueGuard then
                    IssueGuard({ unit }, target)
                end
            end
        end
    end

    if usedCommander then
        runtime.ACUSafetyLockUntil = math.max(runtime.ACUSafetyLockUntil or -999, now + 8)
    end

    return assigned, claimed, usedCommander, debug
end

local function GetPriorityUpgradeAssistTarget(aiBrain, runtime, mainPos)
    if not aiBrain or not mainPos then
        return false, false
    end

    local upgradeDirector = runtime and runtime.UpgradeDirector or false
    if upgradeDirector then
        local directedExtractor = upgradeDirector.Extractor or false
        if directedExtractor and directedExtractor.Enabled == true and directedExtractor.TargetUnit and not directedExtractor.TargetUnit.Dead and directedExtractor.TargetUnit:IsUnitState('Upgrading') then
            return directedExtractor.TargetUnit, true
        end

        local directedFactory = upgradeDirector.Factory or false
        if directedFactory and directedFactory.Enabled == true and directedFactory.TargetUnit and not directedFactory.TargetUnit.Dead and directedFactory.TargetUnit:IsUnitState('Upgrading') then
            return directedFactory.TargetUnit, true
        end
    end

    local best = false
    local bestScore = -999999
    local isUpgradeTarget = false
    local candidates = aiBrain:GetListOfUnits(categories.STRUCTURE + categories.FACTORY, false, true) or {}
    for _, unit in candidates do
        if unit and not unit.Dead and unit:IsUnitState('Upgrading') then
            local pos = unit.GetPosition and unit:GetPosition() or false
            if pos then
                local dist = Common.Distance2D(pos, mainPos)
                if dist <= 360 then
                    local score = 0
                    if EntityCategoryContains(categories.MASSEXTRACTION, unit) then
                        score = score + 260
                    elseif EntityCategoryContains(categories.FACTORY * categories.LAND, unit) then
                        score = score + 240
                    elseif EntityCategoryContains(categories.FACTORY, unit) then
                        score = score + 180
                    else
                        score = score + 120
                    end
                    score = score - dist
                    if score > bestScore then
                        bestScore = score
                        best = unit
                        isUpgradeTarget = true
                    end
                end
            end
        end
    end

    return best, isUpgradeTarget
end

local function GetPriorityRepairTarget(aiBrain, runtime, mainPos)
    if not aiBrain or not mainPos then
        return false
    end

    local best = false
    local bestScore = -999999
    local candidates = aiBrain:GetListOfUnits(categories.STRUCTURE + categories.FACTORY, false, true) or {}
    for _, unit in candidates do
        if unit and not unit.Dead and not unit:IsUnitState('BeingBuilt') and not unit:IsUnitState('Upgrading') then
            local health = unit.GetHealth and unit:GetHealth() or 0
            local maxHealth = unit.GetMaxHealth and unit:GetMaxHealth() or 0
            if maxHealth > 0 and health > 0 and health < (maxHealth * 0.92) then
                local pos = unit.GetPosition and unit:GetPosition() or false
                if pos then
                    local dist = Common.Distance2D(pos, mainPos)
                    if dist <= 320 then
                        local score = ((1 - (health / maxHealth)) * 220)
                        if EntityCategoryContains(categories.FACTORY, unit) then
                            score = score + 180
                        elseif EntityCategoryContains(categories.MASSEXTRACTION, unit) then
                            score = score + 150
                        elseif EntityCategoryContains(categories.RADAR, unit) then
                            score = score + 120
                        elseif EntityCategoryContains(categories.DEFENSE + categories.ANTIAIR, unit) then
                            score = score + 100
                        else
                            score = score + 60
                        end
                        score = score - dist
                        if score > bestScore then
                            bestScore = score
                            best = unit
                        end
                    end
                end
            end
        end
    end

    return best
end

local function GetPriorityBuildAssistTarget(aiBrain, runtime, mainPos)
    if not aiBrain or not mainPos then
        return false
    end

    local best = false
    local bestScore = -999999
    local candidates = aiBrain:GetListOfUnits(categories.STRUCTURE + categories.FACTORY, false, true) or {}
    for _, unit in candidates do
        if unit and not unit.Dead and unit:IsUnitState('BeingBuilt') and not unit:IsUnitState('Upgrading') then
            local pos = unit.GetPosition and unit:GetPosition() or false
            if pos then
                local dist = Common.Distance2D(pos, mainPos)
                if dist <= 360 then
                    local score = 0
                    if EntityCategoryContains(categories.FACTORY * categories.LAND, unit) then
                        score = score + 260
                    elseif EntityCategoryContains(categories.MASSEXTRACTION, unit) then
                        score = score + 240
                    elseif EntityCategoryContains(categories.ENERGYPRODUCTION, unit) then
                        score = score + 210
                    elseif EntityCategoryContains(categories.DEFENSE + categories.ANTIAIR, unit) then
                        score = score + 160
                    elseif EntityCategoryContains(categories.FACTORY, unit) then
                        score = score + 150
                    else
                        score = score + 100
                    end
                    score = score + ((1 - Common.GetFraction(unit)) * 80)
                    score = score - dist
                    if score > bestScore then
                        bestScore = score
                        best = unit
                    end
                end
            end
        end
    end

    return best
end

local function TryAssignAssistOrRepair(aiBrain, runtime, eng, target, isUpgrade, now)
    if not eng or eng.Dead or not target or target.Dead then
        return false
    end

    local mainPos = Common.GetMainPos(aiBrain, runtime)
    local engPos = eng.GetPosition and eng:GetPosition() or false
    local targetPos = target.GetPosition and target:GetPosition() or false
    if engPos and targetPos then
        local targetThreat = aiBrain:GetThreatAtPosition(targetPos, 1, true, 'AntiSurface') or 0
        local localThreat = aiBrain:GetThreatAtPosition(engPos, 1, true, 'AntiSurface') or 0
        local routeRisk = OvermindMemory.GetRouteRisk(aiBrain, engPos, targetPos, 4, 40)
        local targetEnemyCombat = Threat.HasEnemyCombatNear(aiBrain, targetPos, 26)
        local routeEnemyCombat = Threat.HasEnemyCombatNear(aiBrain, engPos, 20)
        local nearMain = mainPos and Common.Distance2D(targetPos, mainPos) <= 140
        if (targetEnemyCombat and not nearMain)
            or routeEnemyCombat
            or targetThreat > (nearMain and 2.0 or 1.1)
            or localThreat > 2.2
            or routeRisk > (nearMain and 3.0 or 1.9) then
            return false
        end
    end

    if IssueClearCommands then
        IssueClearCommands({ eng })
    end

    if isUpgrade then
        if IssueGuard then
            IssueGuard({ eng }, target)
            return true
        elseif IssueRepair then
            IssueRepair({ eng }, target)
            return true
        end
    else
        if IssueRepair then
            IssueRepair({ eng }, target)
            return true
        elseif IssueGuard then
            IssueGuard({ eng }, target)
            return true
        end
    end

    return false
end

local function DescribeStructureTaskTarget(target)
    if not target or target.Dead then
        return 'none'
    end
    if target:IsUnitState('Upgrading') then
        return 'upgrade'
    end
    if target:IsUnitState('BeingBuilt') then
        return 'build'
    end
    if target.GetHealth and target.GetMaxHealth then
        local maxHealth = math.max(1, target:GetMaxHealth() or 1)
        local health = target:GetHealth() or maxHealth
        if health < (maxHealth * 0.995) then
            return 'repair'
        end
    end
    return 'resume'
end

local function ProcessEngineer(aiBrain, runtime, eng, now, ctx)
    if not eng or eng.Dead then
        return
    end

    local entityId = Common.GetEntityId(eng)
    local claimedByFactoryTask = ctx.factoryTask.Active and entityId and ctx.factoryTask.BuilderIds and ctx.factoryTask.BuilderIds[entityId]
    local claimedByStructureTask = ctx.structureTask.Active and entityId and ctx.structureTask.BuilderIds and ctx.structureTask.BuilderIds[entityId]
    local claimedByRadarOrder = entityId and ctx.radarReservedBuilderIds[entityId]
    if claimedByFactoryTask or claimedByStructureTask or claimedByRadarOrder then
        return
    end

    local pos = eng:GetPosition()
    if not pos then
        return
    end

    local dist = Common.Distance2D(pos, ctx.mainPos)
    local localThreat = aiBrain:GetThreatAtPosition(pos, 1, true, 'AntiSurface') or 0
    local escort = aiBrain:GetNumUnitsAroundPoint(categories.MOBILE * (categories.LAND + categories.AIR) - categories.ENGINEER - categories.SCOUT - categories.COMMAND, pos, 26, 'Ally') or 0
    local isIdle = Common.IsIdle(eng)
    local constructing = Common.IsConstructing(eng)
    local acted = false

    if isIdle and not constructing then
        if ctx.structureTask.Active
            and (ctx.structureTask.Kind == 'Power' or ctx.structureTask.Kind == 'Mex')
            and (ctx.macroPhase ~= 'starter_mex_claim' or ctx.structureTask.Kind == 'Power')
            and ctx.structureTargetObject
            and (
                not ctx.fieldTaskWindow
                or ctx.reclaimField >= ctx.fieldTaskQuota
                or ctx.needBase > 0
                or (ctx.structureTask.AssignedBuilders or 0) < math.max(1, math.min(2, (ctx.structureTask.RequiredBuilders or 0)))
            )
            and localThreat < 2.2
            and dist <= 360
            and TryAssignAssistOrRepair(aiBrain, runtime, eng, ctx.structureTargetObject, false, now) then
            if ctx.structureTask.Kind == 'Power' then
                ctx.powerRecoveryCount = ctx.powerRecoveryCount + 1
            else
                ctx.surplusSpendCount = ctx.surplusSpendCount + 1
            end
            acted = true
        elseif ctx.macroPhase == 'starter_mex_claim'
            and localThreat < 2.05
            and dist <= 420
            and Recovery.TryOpenSurplusExpansionBuild(aiBrain, runtime, eng, ctx.mainPos, ctx.enemyPos, ctx.safeExpandDistance, now) then
            ctx.dispatchedExpand = ctx.dispatchedExpand + 1
            acted = true
        elseif (ctx.macroPhase == 'bootstrap_factory' or ctx.macroPhase == 'land_factory_floor')
            and ctx.factoryTask.Active
            and ctx.factoryTargetObject
            and localThreat < 2.2
            and dist <= 360
            and TryAssignAssistOrRepair(aiBrain, runtime, eng, ctx.factoryTargetObject, false, now) then
            ctx.forcedFactoryRecover = ctx.forcedFactoryRecover + 1
            acted = true
        elseif (ctx.macroPhase == 'first_land_hq' or ctx.macroPhase == 'first_t2_engineer' or ctx.macroPhase == 'first_t2_power') then
            local assistTarget, isUpgradeTarget = GetPriorityUpgradeAssistTarget(aiBrain, runtime, ctx.mainPos)
            if assistTarget
                and localThreat < 2.2
                and dist <= 360
                and TryAssignAssistOrRepair(aiBrain, runtime, eng, assistTarget, isUpgradeTarget, now) then
                ctx.surplusSpendCount = ctx.surplusSpendCount + 1
                acted = true
            elseif (ctx.hqPowerRecoveryWanted or ctx.macroNeedPowerRecovery)
                and localThreat < 2.2
                and dist <= 360 then
                local powerTarget = Recovery.GetPriorityPowerRecoveryTarget(aiBrain, runtime, ctx.mainPos, ctx.structureTargetObject, ctx.structureTask)
                if powerTarget and TryAssignAssistOrRepair(aiBrain, runtime, eng, powerTarget, false, now) then
                    ctx.powerRecoveryCount = ctx.powerRecoveryCount + 1
                    acted = true
                elseif Recovery.TryOpenPowerRecoveryBuild(aiBrain, runtime, eng, ctx.mainPos, now) then
                    ctx.powerRecoveryCount = ctx.powerRecoveryCount + 1
                    acted = true
                end
            elseif ctx.factoryTask.Active
                and ctx.factoryTargetObject
                and localThreat < 2.2
                and dist <= 360
                and TryAssignAssistOrRepair(aiBrain, runtime, eng, ctx.factoryTargetObject, false, now) then
                ctx.forcedFactoryRecover = ctx.forcedFactoryRecover + 1
                acted = true
            end
        elseif ctx.contestFieldMode
            and ctx.fieldTaskWindow
            and ctx.reclaimField < ctx.fieldTaskQuota
            and ctx.needBase <= 0
            and Reclaim.TryReclaimFieldZone(aiBrain, runtime, eng, ctx.reclaimFieldPos, now) then
            ctx.reclaimField = ctx.reclaimField + 1
            acted = true
        elseif ctx.contestFieldMode
            and ctx.fieldTaskWindow
            and ctx.reclaimField < ctx.fieldTaskQuota
            and ctx.needBase <= 0
            and localThreat < 1.8
            and dist <= 380
            and Recovery.TryOpenSurplusExpansionBuild(aiBrain, runtime, eng, ctx.mainPos, ctx.enemyPos, ctx.safeExpandDistance, now) then
            ctx.dispatchedExpand = ctx.dispatchedExpand + 1
            acted = true
        elseif ctx.contestFieldMode
            and ctx.fieldTaskWindow
            and ctx.reclaimField < ctx.fieldTaskQuota
            and ctx.needBase <= 0
            and localThreat < 1.9
            and dist <= 420
            and Reclaim.TryReclaimEnemyMex(aiBrain, runtime, eng, now) then
            ctx.reclaimEnemyMex = ctx.reclaimEnemyMex + 1
            acted = true
        end
    end

    if (not acted)
        and isIdle
        and not constructing
        and (ctx.constraints.PowerBufferLow == true or ctx.hqPowerRecoveryWanted or Recovery.ShouldScaleBaseEco(runtime, now))
        and localThreat < 2.2
        and dist <= 360 then
        local powerTarget = Recovery.GetPriorityPowerRecoveryTarget(aiBrain, runtime, ctx.mainPos, ctx.structureTargetObject, ctx.structureTask)
        if powerTarget and TryAssignAssistOrRepair(aiBrain, runtime, eng, powerTarget, false, now) then
            ctx.powerRecoveryCount = ctx.powerRecoveryCount + 1
            acted = true
        elseif Recovery.TryOpenPowerRecoveryBuild(aiBrain, runtime, eng, ctx.mainPos, now) then
            ctx.powerRecoveryCount = ctx.powerRecoveryCount + 1
            acted = true
        end
    end

    if (not acted)
        and ctx.factoryTask.Active
        and ctx.factoryTargetObject
        and (ctx.factoryTask.AssignedBuilders or 0) < (ctx.factoryTask.RequiredBuilders or 0)
        and localThreat < 2.2
        and dist <= 360
        and not eng:IsUnitState('Upgrading')
        and ((isIdle and not constructing) or (not constructing and Common.GetCommandQueueLength(eng) <= 2))
        and TryAssignAssistOrRepair(aiBrain, runtime, eng, ctx.factoryTargetObject, false, now) then
        if entityId then
            ctx.factoryTask.BuilderIds = ctx.factoryTask.BuilderIds or {}
            ctx.factoryTask.BuilderIds[entityId] = true
        end
        ctx.factoryTask.AssignedBuilders = math.min((ctx.factoryTask.RequiredBuilders or 0), (ctx.factoryTask.AssignedBuilders or 0) + 1)
        ctx.forcedFactoryRecover = ctx.forcedFactoryRecover + 1
        acted = true
    end

    if (not acted)
        and isIdle
        and not constructing
        and ctx.structureTask.Active
        and ctx.structureTargetObject
        and (ctx.structureTask.AssignedBuilders or 0) < (ctx.structureTask.RequiredBuilders or 0)
        and localThreat < 2.2
        and dist <= 320
        and TryAssignAssistOrRepair(aiBrain, runtime, eng, ctx.structureTargetObject, false, now) then
        if entityId then
            ctx.structureTask.BuilderIds = ctx.structureTask.BuilderIds or {}
            ctx.structureTask.BuilderIds[entityId] = true
        end
        ctx.structureTask.AssignedBuilders = math.min((ctx.structureTask.RequiredBuilders or 0), (ctx.structureTask.AssignedBuilders or 0) + 1)
        acted = true
    end

    if (not acted)
        and isIdle
        and not constructing
        and ctx.structureTask.Active
        and ctx.structureTargetObject
        and (ctx.structureTask.Kind == 'Mex' or ctx.structureTask.Kind == 'Power')
        and Recovery.ShouldPersistentSurplusSpend(runtime, now)
        and localThreat < 2.0
        and dist <= 360
        and TryAssignAssistOrRepair(aiBrain, runtime, eng, ctx.structureTargetObject, false, now) then
        ctx.surplusSpendCount = ctx.surplusSpendCount + 1
        acted = true
    end

    if (not acted) and isIdle and not constructing then
        local assistTarget, isUpgradeTarget = GetPriorityUpgradeAssistTarget(aiBrain, runtime, ctx.mainPos)
        if assistTarget and localThreat < 2.2 and dist <= 360 and TryAssignAssistOrRepair(aiBrain, runtime, eng, assistTarget, isUpgradeTarget, now) then
            ctx.surplusSpendCount = ctx.surplusSpendCount + 1
            acted = true
        end
    end

    if (not acted)
        and isIdle
        and not constructing
        and (not ctx.transitionLock)
        and (Recovery.ShouldPersistentSurplusSpend(runtime, now) or Recovery.ShouldScaleBaseEco(runtime, now))
        and localThreat < 2.0
        and dist <= 360 then
        local buildAssistTarget = GetPriorityBuildAssistTarget(aiBrain, runtime, ctx.mainPos)
        if buildAssistTarget and TryAssignAssistOrRepair(aiBrain, runtime, eng, buildAssistTarget, false, now) then
            ctx.surplusSpendCount = ctx.surplusSpendCount + 1
            acted = true
        end
    end

    if (not acted) and isIdle and not constructing then
        local repairTarget = GetPriorityRepairTarget(aiBrain, runtime, ctx.mainPos)
        if repairTarget and localThreat < 2.2 and dist <= 360 and TryAssignAssistOrRepair(aiBrain, runtime, eng, repairTarget, false, now) then
            acted = true
        end
    end

    if (not acted)
        and isIdle
        and not constructing
        and Recovery.ShouldPersistentSurplusSpend(runtime, now)
        and localThreat < 1.8
        and dist <= 260 then
        if Recovery.TryOpenSurplusExpansionBuild(aiBrain, runtime, eng, ctx.mainPos, ctx.enemyPos, ctx.safeExpandDistance, now) then
            ctx.dispatchedExpand = ctx.dispatchedExpand + 1
            ctx.surplusSpendCount = ctx.surplusSpendCount + 1
            acted = true
        elseif Recovery.ShouldScaleBaseEco(runtime, now) and Recovery.TryOpenPowerRecoveryBuild(aiBrain, runtime, eng, ctx.mainPos, now) then
            ctx.powerRecoveryCount = ctx.powerRecoveryCount + 1
            ctx.surplusSpendCount = ctx.surplusSpendCount + 1
            acted = true
        end
    end

    if isIdle
        and not constructing
        and (not acted)
        and Reclaim.TryReclaimFieldZone(aiBrain, runtime, eng, ctx.reclaimFieldPos, now) then
        ctx.reclaimField = ctx.reclaimField + 1
        acted = true
    end

    if isIdle
        and not constructing
        and (not acted)
        and not (Recovery.ShouldPersistentSurplusSpend(runtime, now) or Recovery.ShouldScaleBaseEco(runtime, now))
        and Reclaim.TryReclaimEnemyMex(aiBrain, runtime, eng, now) then
        ctx.reclaimEnemyMex = ctx.reclaimEnemyMex + 1
        acted = true
    end

    local farUnsafe = dist > math.max(230, ctx.safeExpandDistance * 0.88) and localThreat > 2 and escort < 3
    local earlyOverextend = now < 420 and dist > math.min(350, ctx.safeExpandDistance * 0.82) and escort < 2 and localThreat > 1.1
    local enemySideRisk = false
    if ctx.enemyPos then
        local distEnemy = Common.Distance2D(pos, ctx.enemyPos)
        enemySideRisk = dist > 160 and distEnemy < (dist * 0.95) and escort < 3
    end
    local severeThreat = localThreat > 3.3 and escort < 3
    local airRaidRisk = (ctx.bomberPanic or ctx.raid.ExposedMexUnderAirRaid)
        and dist > 110
        and escort < 2
        and (
            localThreat > 0.8
            or (ctx.raid.ExposedMexThreatPos and Common.Distance2D(pos, ctx.raid.ExposedMexThreatPos) < 70)
        )

    if (not acted) and (severeThreat or farUnsafe or (not constructing and (earlyOverextend or enemySideRisk))) then
        if Common.RecallEngineer(runtime, eng, ctx.mainPos, now, 'threatened') then
            ctx.threatenedCount = ctx.threatenedCount + 1
        end
    elseif (not acted) and not constructing and airRaidRisk then
        if Common.RecallEngineer(runtime, eng, ctx.mainPos, now, 'air_raid') then
            ctx.threatenedCount = ctx.threatenedCount + 1
        end
    elseif (not acted) and not constructing and ctx.needBase > 0 and dist > 130 and isIdle and localThreat < 1.9 then
        if Common.RecallEngineer(runtime, eng, ctx.mainPos, now, 'base_floor') then
            ctx.recoverCount = ctx.recoverCount + 1
            ctx.needBase = ctx.needBase - 1
        end
    elseif (not acted) and not constructing and ctx.factoryTask.Active and (ctx.factoryTask.AssignedBuilders or 0) < (ctx.factoryTask.RequiredBuilders or 0) and dist > 140 and localThreat < 1.6 and ctx.forcedFactoryRecover < math.max(2, ctx.factoryTask.RequiredBuilders or 0) then
        if Common.RecallEngineer(runtime, eng, ctx.mainPos, now, 'factory_task') then
            ctx.forcedFactoryRecover = ctx.forcedFactoryRecover + 1
        end
    elseif (not acted) and not constructing and ctx.severeFactoryStarve and dist > 140 and localThreat < 1.6 and ctx.forcedFactoryRecover < 2 then
        if Common.RecallEngineer(runtime, eng, ctx.mainPos, now, 'factory_starve') then
            ctx.forcedFactoryRecover = ctx.forcedFactoryRecover + 1
        end
    end
end


M.ScoreFactoryBuilder = ScoreFactoryBuilder
M.ScoreStructureBuilder = ScoreStructureBuilder
M.AssignBuildersToUnfinishedFactory = AssignBuildersToUnfinishedFactory
M.AssignBuildersToUnfinishedStructure = AssignBuildersToUnfinishedStructure
M.GetPriorityUpgradeAssistTarget = GetPriorityUpgradeAssistTarget
M.GetPriorityRepairTarget = GetPriorityRepairTarget
M.GetPriorityBuildAssistTarget = GetPriorityBuildAssistTarget
M.TryAssignAssistOrRepair = TryAssignAssistOrRepair
M.DescribeStructureTaskTarget = DescribeStructureTaskTarget
M.ProcessEngineer = ProcessEngineer
return M


