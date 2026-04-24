local Common = import('/mods/OvermindAI/lua/AI/Overmind/EngineerDirector/Common.lua')
local Threat = import('/mods/OvermindAI/lua/AI/Overmind/EngineerDirector/Threat.lua')
local Reclaim = import('/mods/OvermindAI/lua/AI/Overmind/EngineerDirector/Reclaim.lua')
local Recovery = import('/mods/OvermindAI/lua/AI/Overmind/EngineerDirector/Recovery.lua')
local OvermindMechanicTune = import('/mods/OvermindAI/lua/AI/Overmind/MechanicTune.lua')
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

local function GetPriorityACURepairTarget(aiBrain, runtime, mainPos, engPos, now)
    if not aiBrain or not mainPos then
        return false
    end

    local mechanic = OvermindMechanicTune.GetConfig(aiBrain)
    local commanders = aiBrain:GetListOfUnits(categories.COMMAND, false, true) or {}
    local acu = false
    for _, unit in commanders do
        if unit and not unit.Dead then
            acu = unit
            break
        end
    end
    if not acu then
        return false
    end

    local acuPos = acu.GetPosition and acu:GetPosition() or false
    local acuHealth = acu.GetHealth and acu:GetHealth() or 0
    local acuMaxHealth = acu.GetMaxHealth and acu:GetMaxHealth() or 0
    if not acuPos or acuMaxHealth <= 0 or acuHealth <= 0 then
        return false
    end

    local healthRatio = acuHealth / acuMaxHealth
    local crisisActive = now < (runtime.ACUCrisisUntil or -999)
        or now < (runtime.ACUCrisisEscalatedUntil or -999)
        or now < (runtime.ACUProtectUntil or -999)
    local recentDamage = (runtime.LastAcuDamageTime or -999) >= (now - 28)
    local emergencyTask = (((runtime.ForceDirector or {}).Tasks or {}).acu_emergency_intercept) or false
    local emergencyWanted = emergencyTask and (((emergencyTask.DesiredUnits or 0) > 0) or ((emergencyTask.CurrentUnits or 0) > 0))
    local priorityBias = math.max(-0.12, math.min(0.18, (mechanic.EngineerACURepairPriorityBias or 0) / 1000))
    local healthThreshold = 0.94 + (mechanic.EngineerACURepairHealthBias or 0) - priorityBias
    local mainDistanceCap = 220 + (mechanic.EngineerACURepairDistanceBias or 0)
    local engineerDistanceCap = 340 + (mechanic.EngineerACURepairDistanceBias or 0)
    local targetThreat = aiBrain:GetThreatAtPosition(acuPos, 1, true, 'AntiSurface') or 0
    local threatCap = 2.3 + (mechanic.EngineerACURepairThreatBias or 0) + (crisisActive and 0.4 or 0)
    if crisisActive or recentDamage or healthRatio < 0.82 then
        mainDistanceCap = 380 + (mechanic.EngineerACURepairDistanceBias or 0)
        engineerDistanceCap = 560 + (mechanic.EngineerACURepairDistanceBias or 0)
        threatCap = 4.2 + (mechanic.EngineerACURepairThreatBias or 0)
    elseif emergencyWanted then
        mainDistanceCap = 300 + (mechanic.EngineerACURepairDistanceBias or 0)
        engineerDistanceCap = 460 + (mechanic.EngineerACURepairDistanceBias or 0)
        threatCap = 3.2 + (mechanic.EngineerACURepairThreatBias or 0)
    end

    if not crisisActive and not recentDamage and not emergencyWanted and healthRatio >= healthThreshold then
        return false
    end
    if Common.Distance2D(acuPos, mainPos) > mainDistanceCap then
        return false
    end
    if engPos and Common.Distance2D(acuPos, engPos) > engineerDistanceCap then
        return false
    end
    if targetThreat > threatCap and not (crisisActive and healthRatio < 0.70) then
        return false
    end

    return acu
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

    local mechanic = OvermindMechanicTune.GetConfig(aiBrain)
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
        local isACUTarget = EntityCategoryContains(categories.COMMAND, target)
        local targetThreatCap = (nearMain and 2.0 or 1.1) + (mechanic.EngineerRepairThreatBias or 0)
        local localThreatCap = 2.2 + (mechanic.EngineerRepairThreatBias or 0)
        local routeRiskCap = (nearMain and 3.0 or 1.9) + (mechanic.EngineerRepairRouteRiskBias or 0)
        if isACUTarget then
            local acuHealthRatio = 1
            if target.GetHealth and target.GetMaxHealth then
                local maxHealth = math.max(1, target:GetMaxHealth() or 1)
                acuHealthRatio = math.max(0, math.min(1, (target:GetHealth() or maxHealth) / maxHealth))
            end
            targetThreatCap = targetThreatCap + 0.7 + (mechanic.EngineerACURepairThreatBias or 0)
            localThreatCap = localThreatCap + 0.55 + (mechanic.EngineerACURepairThreatBias or 0)
            routeRiskCap = routeRiskCap + 0.7 + (mechanic.EngineerRepairRouteRiskBias or 0)
            local acuCrisisRepair = now
                and (
                    now < (runtime.ACUCrisisUntil or -999)
                    or now < (runtime.ACUCrisisEscalatedUntil or -999)
                    or now < (runtime.ACUProtectUntil or -999)
                    or (runtime.LastAcuDamageTime or -999) >= (now - 28)
                )
            if acuCrisisRepair then
                if acuHealthRatio < 0.72 then
                    targetThreatCap = math.max(targetThreatCap, 120)
                    localThreatCap = math.max(localThreatCap, 12)
                    routeRiskCap = math.max(routeRiskCap, 9)
                elseif acuHealthRatio < 0.84 then
                    targetThreatCap = math.max(targetThreatCap, 28)
                    localThreatCap = math.max(localThreatCap, 6)
                    routeRiskCap = math.max(routeRiskCap, 5.5)
                else
                    targetThreatCap = targetThreatCap + 1.4
                    localThreatCap = localThreatCap + 1.0
                    routeRiskCap = routeRiskCap + 1.8
                end
            end
        end
        if (targetEnemyCombat and not nearMain and not isACUTarget)
            or (routeEnemyCombat and not isACUTarget)
            or targetThreat > targetThreatCap
            or localThreat > localThreatCap
            or routeRisk > routeRiskCap then
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

local function IsTechEngineer(unit)
    return unit
        and not unit.Dead
        and EntityCategoryContains(categories.ENGINEER * categories.MOBILE * (categories.TECH2 + categories.TECH3), unit)
end

local function IsEcoStructureKind(kind)
    local lower = string.lower(kind or 'none')
    return lower == 'mex' or lower == 'power'
end

local function GetPriorityEcoStructureTask(ctx)
    if ctx.ecoStructureTask and ctx.ecoStructureTask.Active and ctx.ecoStructureTargetObject then
        return ctx.ecoStructureTask, ctx.ecoStructureTargetObject
    end
    if ctx.structureTask and ctx.structureTask.Active and ctx.structureTargetObject and IsEcoStructureKind(ctx.structureTask.Kind) then
        return ctx.structureTask, ctx.structureTargetObject
    end
    return false, false
end

local function GetPriorityDefenseStructureTask(ctx)
    if ctx.defenseStructureTask and ctx.defenseStructureTask.Active and ctx.defenseStructureTargetObject then
        return ctx.defenseStructureTask, ctx.defenseStructureTargetObject
    end
    if ctx.structureTask
        and ctx.structureTask.Active
        and ctx.structureTargetObject
        and not IsEcoStructureKind(ctx.structureTask.Kind) then
        return ctx.structureTask, ctx.structureTargetObject
    end
    return false, false
end

local function ProcessEngineer(aiBrain, runtime, eng, now, ctx)
    if not eng or eng.Dead then
        return
    end

    local entityId = Common.GetEntityId(eng)
    local claimedByFactoryTask = ctx.factoryTask.Active and entityId and ctx.factoryTask.BuilderIds and ctx.factoryTask.BuilderIds[entityId]
    local claimedByEcoStructureTask = ctx.ecoStructureTask and ctx.ecoStructureTask.Active and entityId and ctx.ecoStructureTask.BuilderIds and ctx.ecoStructureTask.BuilderIds[entityId]
    local claimedByDefenseStructureTask = ctx.defenseStructureTask and ctx.defenseStructureTask.Active and entityId and ctx.defenseStructureTask.BuilderIds and ctx.defenseStructureTask.BuilderIds[entityId]
    local claimedByStructureTask = claimedByEcoStructureTask or claimedByDefenseStructureTask
        or (ctx.structureTask.Active and entityId and ctx.structureTask.BuilderIds and ctx.structureTask.BuilderIds[entityId])
    local claimedByRadarOrder = entityId and ctx.radarReservedBuilderIds[entityId]
    local isTechBuilder = IsTechEngineer(eng)
    local canPreemptStructureForReclaim = claimedByStructureTask
        and not claimedByFactoryTask
        and not claimedByRadarOrder
        and ctx.contestFieldMode
        and ctx.fieldTaskWindow
        and ctx.reclaimField < ctx.fieldTaskQuota
        and (ctx.structureReclaimPreempts or 0) < 1
        and ctx.needBase <= 0
        and not ctx.mexRebuildUrgent
        and not ctx.techTransitionCritical
        and not ctx.mapCollapse
        and not isTechBuilder
        and not (ctx.structureTask.Kind == 'Power' and ctx.constraints.PowerBufferLow == true)
    if canPreemptStructureForReclaim
        and Reclaim.TryReclaimFieldZone(aiBrain, runtime, eng, ctx.reclaimFieldPos, now) then
        ctx.reclaimField = ctx.reclaimField + 1
        ctx.structureReclaimPreempts = (ctx.structureReclaimPreempts or 0) + 1
        return
    end

    local pos = eng:GetPosition()
    if not pos then
        return
    end

    local dist = Common.Distance2D(pos, ctx.mainPos)
    local localThreat = aiBrain:GetThreatAtPosition(pos, 1, true, 'AntiSurface') or 0
    local isIdle = Common.IsIdle(eng)
    local constructing = Common.IsConstructing(eng)
    local acuRepairTarget = GetPriorityACURepairTarget(aiBrain, runtime, ctx.mainPos, pos, now)
    local acuRepairUrgent = acuRepairTarget
        and (
            now < (runtime.ACUCrisisUntil or -999)
            or now < (runtime.ACUCrisisEscalatedUntil or -999)
            or now < (runtime.ACUProtectUntil or -999)
            or ((runtime.LastAcuDamageTime or -999) >= (now - 28))
        )
    local acuRepairHealthRatio = 1
    if acuRepairTarget and acuRepairTarget.GetHealth and acuRepairTarget.GetMaxHealth then
        local maxHealth = math.max(1, acuRepairTarget:GetMaxHealth() or 1)
        acuRepairHealthRatio = math.max(0, math.min(1, (acuRepairTarget:GetHealth() or maxHealth) / maxHealth))
    end
    local acuRepairHard = acuRepairTarget and (acuRepairUrgent or acuRepairHealthRatio < 0.84)
    local acuRepairSlotsOpen = (ctx.acuRepairWanted or 0) > (ctx.acuRepairCount or 0)

    if acuRepairHard
        and acuRepairSlotsOpen
        and not constructing
        and (isIdle or Common.GetCommandQueueLength(eng) <= (acuRepairHealthRatio < 0.72 and 5 or 3))
        and localThreat < ((acuRepairHealthRatio < 0.72 or acuRepairUrgent) and 4.2 or 3.2)
        and dist <= ((acuRepairHealthRatio < 0.72 or acuRepairUrgent) and 560 or 460)
        and TryAssignAssistOrRepair(aiBrain, runtime, eng, acuRepairTarget, false, now) then
        if claimedByFactoryTask and ctx.factoryTask.BuilderIds and entityId then
            ctx.factoryTask.BuilderIds[entityId] = nil
            ctx.factoryTask.AssignedBuilders = math.max(0, (ctx.factoryTask.AssignedBuilders or 1) - 1)
        end
        if claimedByEcoStructureTask and ctx.ecoStructureTask and ctx.ecoStructureTask.BuilderIds and entityId then
            ctx.ecoStructureTask.BuilderIds[entityId] = nil
            ctx.ecoStructureTask.AssignedBuilders = math.max(0, (ctx.ecoStructureTask.AssignedBuilders or 1) - 1)
        end
        if claimedByDefenseStructureTask and ctx.defenseStructureTask and ctx.defenseStructureTask.BuilderIds and entityId then
            ctx.defenseStructureTask.BuilderIds[entityId] = nil
            ctx.defenseStructureTask.AssignedBuilders = math.max(0, (ctx.defenseStructureTask.AssignedBuilders or 1) - 1)
        end
        if claimedByStructureTask and ctx.structureTask.BuilderIds and entityId then
            ctx.structureTask.BuilderIds[entityId] = nil
            ctx.structureTask.AssignedBuilders = math.max(0, (ctx.structureTask.AssignedBuilders or 1) - 1)
        end
        runtime.LastEngineerACURepairTime = now
        ctx.acuRepairCount = (ctx.acuRepairCount or 0) + 1
        return
    end

    if ctx.factoryGrowthDebt
        and not ctx.factoryTask.Active
        and not claimedByFactoryTask
        and not claimedByStructureTask
        and not claimedByRadarOrder
        and isIdle
        and not constructing then
        ctx.factoryGrowthIdleReserve = ctx.factoryGrowthIdleReserve or 0
        if ctx.factoryGrowthIdleReserve < 2 then
            -- Keep a small reserve for high-priority factory builders without freezing
            -- every idle engineer out of reclaim and expansion work.
            ctx.factoryGrowthIdleReserve = ctx.factoryGrowthIdleReserve + 1
            return
        end
    end

    if Common.IsReadyBuilder(eng)
        and EntityCategoryContains(categories.ENGINEER * categories.MOBILE * (categories.TECH2 + categories.TECH3), eng)
        and Recovery.TryOpenFirstT2PowerBuild(aiBrain, runtime, eng, ctx.mainPos, now) then
        if claimedByFactoryTask and ctx.factoryTask.BuilderIds and entityId then
            ctx.factoryTask.BuilderIds[entityId] = nil
            ctx.factoryTask.AssignedBuilders = math.max(0, (ctx.factoryTask.AssignedBuilders or 1) - 1)
        end
        ctx.powerRecoveryCount = ctx.powerRecoveryCount + 1
        return
    end

    if claimedByFactoryTask or claimedByStructureTask or claimedByRadarOrder then
        return
    end

    local escort = aiBrain:GetNumUnitsAroundPoint(categories.MOBILE * (categories.LAND + categories.AIR) - categories.ENGINEER - categories.SCOUT - categories.COMMAND, pos, 26, 'Ally') or 0
    local acted = false
    local upgradeAssistTarget = false
    local upgradeAssistIsUpgrade = false
    local ecoStructureAssistTask, ecoStructureAssistTarget = GetPriorityEcoStructureTask(ctx)
    local defenseStructureAssistTask, defenseStructureAssistTarget = GetPriorityDefenseStructureTask(ctx)

    if isIdle and not constructing and (isTechBuilder or ctx.mapCollapse or ctx.techTransitionCritical) then
        upgradeAssistTarget, upgradeAssistIsUpgrade = GetPriorityUpgradeAssistTarget(aiBrain, runtime, ctx.mainPos)
    end
    local factoryBootstrapCritical = ctx.factoryTask.Active and ((ctx.factoryTask.ReadyFactories or 0) <= 0)
    local techBuilderPriorityWork = isTechBuilder and (
        ctx.coreEcoCritical
        or ctx.mapCollapse
        or ctx.techTransitionCritical
        or ctx.transitionLock
        or ecoStructureAssistTask
        or defenseStructureAssistTask
        or upgradeAssistTarget
        or Recovery.ShouldScaleBaseEco(runtime, now)
        or Recovery.ShouldPersistentSurplusSpend(runtime, now)
    )

    if isIdle and not constructing and techBuilderPriorityWork then
        if upgradeAssistTarget
            and localThreat < 2.2
            and dist <= 380
            and TryAssignAssistOrRepair(aiBrain, runtime, eng, upgradeAssistTarget, upgradeAssistIsUpgrade, now) then
            ctx.surplusSpendCount = ctx.surplusSpendCount + 1
            acted = true
        elseif ecoStructureAssistTarget
            and localThreat < 2.2
            and dist <= 380
            and TryAssignAssistOrRepair(aiBrain, runtime, eng, ecoStructureAssistTarget, false, now) then
            if ecoStructureAssistTask and ecoStructureAssistTask.Kind == 'Power' then
                ctx.powerRecoveryCount = ctx.powerRecoveryCount + 1
            else
                ctx.surplusSpendCount = ctx.surplusSpendCount + 1
            end
            acted = true
        elseif (ctx.hqPowerRecoveryWanted or ctx.macroNeedPowerRecovery or Recovery.ShouldScaleBaseEco(runtime, now))
            and localThreat < 2.2
            and dist <= 380 then
            local powerTarget = Recovery.GetPriorityPowerRecoveryTarget(aiBrain, runtime, ctx.mainPos, ecoStructureAssistTarget or ctx.structureTargetObject, ecoStructureAssistTask or ctx.structureTask)
            if powerTarget and TryAssignAssistOrRepair(aiBrain, runtime, eng, powerTarget, false, now) then
                ctx.powerRecoveryCount = ctx.powerRecoveryCount + 1
                acted = true
            elseif Recovery.TryOpenPowerRecoveryBuild(aiBrain, runtime, eng, ctx.mainPos, now) then
                ctx.powerRecoveryCount = ctx.powerRecoveryCount + 1
                acted = true
            end
        elseif ctx.coreEcoCritical
            and (not ctx.containmentCrisis or (ctx.mexReady or 0) < (ctx.containmentExpansionFloor or 8))
            and not factoryBootstrapCritical
            and localThreat < 2.1
            and dist <= 520
            and Recovery.TryOpenSurplusExpansionBuild(aiBrain, runtime, eng, ctx.mainPos, ctx.enemyPos, ctx.safeExpandDistance, now) then
            ctx.dispatchedExpand = ctx.dispatchedExpand + 1
            acted = true
        end
    end

    if isIdle and not constructing and not acted then
        if (ctx.mapCollapse or (ctx.mexReady or 0) <= 7 or ctx.contestFieldMode)
            and not isTechBuilder
            and ctx.needBase <= 0
            and localThreat < 2.0
            and Reclaim.TryReclaimNearby(aiBrain, runtime, eng, now, now < 660 and 72 or 84, 0.75, {
                MaxThreat = now < 660 and 2.05 or 2.35,
                EnemyRadius = now < 660 and 22 or 26,
                MinEscort = 0,
                MinTotalMass = now < 660 and 5 or 8,
                MaxTargets = now < 660 and 28 or 36,
            }) then
            ctx.reclaimField = ctx.reclaimField + 1
            acted = true
        elseif ecoStructureAssistTask
            and ecoStructureAssistTarget
            and (ecoStructureAssistTask.Kind == 'Power' or ecoStructureAssistTask.Kind == 'Mex')
            and (ctx.macroPhase ~= 'starter_mex_claim' or ecoStructureAssistTask.Kind == 'Power')
            and (
                not ctx.fieldTaskWindow
                or ctx.reclaimField >= ctx.fieldTaskQuota
                or ctx.needBase > 0
                or (ecoStructureAssistTask.AssignedBuilders or 0) < math.max(1, math.min(2, (ecoStructureAssistTask.RequiredBuilders or 0)))
                or isTechBuilder
                or ctx.mapCollapse
            )
            and localThreat < 2.2
            and dist <= 360
            and TryAssignAssistOrRepair(aiBrain, runtime, eng, ecoStructureAssistTarget, false, now) then
            if ecoStructureAssistTask.Kind == 'Power' then
                ctx.powerRecoveryCount = ctx.powerRecoveryCount + 1
            else
                ctx.surplusSpendCount = ctx.surplusSpendCount + 1
            end
            acted = true
        elseif defenseStructureAssistTask
            and defenseStructureAssistTarget
            and (ctx.homeDefenseCritical or ctx.radarCritical or ctx.transitionLock)
            and localThreat < 2.3
            and dist <= 320
            and TryAssignAssistOrRepair(aiBrain, runtime, eng, defenseStructureAssistTarget, false, now) then
            acted = true
        elseif (ctx.mapCollapse or (ctx.mexReady or 0) <= 6 or ctx.contestFieldMode)
            and ctx.needBase <= 0
            and localThreat < 1.65
            and not (isTechBuilder and techBuilderPriorityWork and not ctx.allowTechBuilderReclaim)
            and Reclaim.TryReclaimNearby(aiBrain, runtime, eng, now, now < 660 and 72 or 84, 0.75, {
                MaxThreat = now < 660 and 1.65 or 1.95,
                EnemyRadius = now < 660 and 26 or 30,
                MinTotalMass = now < 660 and 5 or 8,
                MaxTargets = now < 660 and 18 or 24,
            }) then
            ctx.reclaimField = ctx.reclaimField + 1
            acted = true
        elseif ctx.macroPhase == 'starter_mex_claim'
            and (not ctx.containmentCrisis or (ctx.mexReady or 0) < (ctx.containmentExpansionFloor or 8))
            and localThreat < 2.05
            and dist <= 420
            and Recovery.TryOpenSurplusExpansionBuild(aiBrain, runtime, eng, ctx.mainPos, ctx.enemyPos, ctx.safeExpandDistance, now) then
            ctx.dispatchedExpand = ctx.dispatchedExpand + 1
            acted = true
        elseif ctx.mexRebuildUrgent
            and (not ctx.containmentCrisis or (ctx.mexReady or 0) < (ctx.containmentExpansionFloor or 8))
            and localThreat < 2.0
            and dist <= 460
            and Recovery.TryOpenSurplusExpansionBuild(aiBrain, runtime, eng, ctx.mainPos, ctx.enemyPos, ctx.safeExpandDistance, now) then
            ctx.dispatchedExpand = ctx.dispatchedExpand + 1
            acted = true
        elseif ctx.coreEcoCritical
            and (not ctx.containmentCrisis or (ctx.mexReady or 0) < (ctx.containmentExpansionFloor or 8))
            and not factoryBootstrapCritical
            and localThreat < 2.05
            and dist <= 520
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
        elseif (ctx.macroPhase == 'first_land_hq' or ctx.macroPhase == 'first_t2_engineer' or ctx.macroPhase == 'first_t2_power' or ctx.mapCollapse) then
            if Common.IsReadyBuilder(eng)
                and EntityCategoryContains(categories.ENGINEER * categories.MOBILE * (categories.TECH2 + categories.TECH3), eng)
                and localThreat < 2.2
                and dist <= 360
                and Recovery.TryOpenFirstT2PowerBuild(aiBrain, runtime, eng, ctx.mainPos, now) then
                ctx.powerRecoveryCount = ctx.powerRecoveryCount + 1
                acted = true
            elseif upgradeAssistTarget
                and localThreat < 2.2
                and dist <= 360
                and TryAssignAssistOrRepair(aiBrain, runtime, eng, upgradeAssistTarget, upgradeAssistIsUpgrade, now) then
                ctx.surplusSpendCount = ctx.surplusSpendCount + 1
                acted = true
            elseif (ctx.hqPowerRecoveryWanted or ctx.macroNeedPowerRecovery)
                and localThreat < 2.2
                and dist <= 360 then
                local powerTarget = Recovery.GetPriorityPowerRecoveryTarget(aiBrain, runtime, ctx.mainPos, ecoStructureAssistTarget or ctx.structureTargetObject, ecoStructureAssistTask or ctx.structureTask)
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
            and not (ctx.factoryTask.Active and (ctx.factoryTask.AssignedBuilders or 0) <= 0 and (ctx.macroPhase == 'bootstrap_factory' or ctx.macroPhase == 'land_factory_floor'))
            and not (isTechBuilder and techBuilderPriorityWork and not ctx.allowTechBuilderReclaim)
            and Reclaim.TryReclaimFieldZone(aiBrain, runtime, eng, ctx.reclaimFieldPos, now) then
            ctx.reclaimField = ctx.reclaimField + 1
            acted = true
        elseif (ctx.mexReady or 0) >= 4
            and ctx.needBase <= 0
            and localThreat < 1.6
            and not (isTechBuilder and techBuilderPriorityWork and not ctx.allowTechBuilderReclaim)
            and Reclaim.TryReclaimNearby(aiBrain, runtime, eng, now, now < 420 and 48 or 56, 1.0, {
                MaxThreat = now < 420 and 1.45 or 1.85,
                EnemyRadius = now < 420 and 24 or 28,
                MinTotalMass = now < 420 and 6 or 10,
                MaxTargets = now < 420 and 16 or 24,
            }) then
            ctx.reclaimField = ctx.reclaimField + 1
            acted = true
        elseif ctx.contestFieldMode
            and ctx.fieldTaskWindow
            and ctx.reclaimField < ctx.fieldTaskQuota
            and ctx.needBase <= 0
            and not (isTechBuilder and techBuilderPriorityWork and not ctx.allowTechBuilderReclaim)
            and Reclaim.TryReclaimFieldZone(aiBrain, runtime, eng, ctx.reclaimFieldPos, now) then
            ctx.reclaimField = ctx.reclaimField + 1
            acted = true
        elseif ctx.contestFieldMode
            and ctx.fieldTaskWindow
            and ctx.reclaimField < ctx.fieldTaskQuota
            and (not ctx.containmentCrisis or (ctx.mexReady or 0) < (ctx.containmentExpansionFloor or 8))
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
        local powerTarget = Recovery.GetPriorityPowerRecoveryTarget(
            aiBrain,
            runtime,
            ctx.mainPos,
            ecoStructureAssistTarget or ctx.structureTargetObject,
            ecoStructureAssistTask or ctx.structureTask)
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
        and localThreat < 2.2
        and dist <= 320 then
        local laneTask = false
        local laneTarget = false
        if ecoStructureAssistTask
            and ecoStructureAssistTarget
            and (ecoStructureAssistTask.AssignedBuilders or 0) < (ecoStructureAssistTask.RequiredBuilders or 0) then
            laneTask = ecoStructureAssistTask
            laneTarget = ecoStructureAssistTarget
        elseif defenseStructureAssistTask
            and defenseStructureAssistTarget
            and (defenseStructureAssistTask.AssignedBuilders or 0) < (defenseStructureAssistTask.RequiredBuilders or 0) then
            laneTask = defenseStructureAssistTask
            laneTarget = defenseStructureAssistTarget
        elseif ctx.structureTask.Active
            and ctx.structureTargetObject
            and (ctx.structureTask.AssignedBuilders or 0) < (ctx.structureTask.RequiredBuilders or 0) then
            laneTask = ctx.structureTask
            laneTarget = ctx.structureTargetObject
        end
        if laneTask
            and laneTarget
            and TryAssignAssistOrRepair(aiBrain, runtime, eng, laneTarget, false, now) then
            if entityId then
                laneTask.BuilderIds = laneTask.BuilderIds or {}
                laneTask.BuilderIds[entityId] = true
            end
            laneTask.AssignedBuilders = math.min((laneTask.RequiredBuilders or 0), (laneTask.AssignedBuilders or 0) + 1)
            acted = true
        end
    end

    if (not acted)
        and isIdle
        and not constructing
        and ecoStructureAssistTask
        and ecoStructureAssistTarget
        and (ecoStructureAssistTask.Kind == 'Mex' or ecoStructureAssistTask.Kind == 'Power')
        and Recovery.ShouldPersistentSurplusSpend(runtime, now)
        and localThreat < 2.0
        and dist <= 360
        and TryAssignAssistOrRepair(aiBrain, runtime, eng, ecoStructureAssistTarget, false, now) then
        ctx.surplusSpendCount = ctx.surplusSpendCount + 1
        acted = true
    end

    if (not acted) and isIdle and not constructing then
        if not upgradeAssistTarget then
            upgradeAssistTarget, upgradeAssistIsUpgrade = GetPriorityUpgradeAssistTarget(aiBrain, runtime, ctx.mainPos)
        end
        if upgradeAssistTarget and localThreat < 2.2 and dist <= 360 and TryAssignAssistOrRepair(aiBrain, runtime, eng, upgradeAssistTarget, upgradeAssistIsUpgrade, now) then
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
        if acuRepairTarget
            and (ctx.acuRepairWanted or 0) > (ctx.acuRepairCount or 0)
            and localThreat < 3.3
            and dist <= 500
            and TryAssignAssistOrRepair(aiBrain, runtime, eng, acuRepairTarget, false, now) then
            runtime.LastEngineerACURepairTime = now
            ctx.acuRepairCount = (ctx.acuRepairCount or 0) + 1
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
            and (not ctx.containmentCrisis or (ctx.mexReady or 0) < (ctx.containmentExpansionFloor or 8))
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
        and localThreat < 1.9
        and not (isTechBuilder and techBuilderPriorityWork and not ctx.allowTechBuilderReclaim)
        and Reclaim.TryReclaimNearby(aiBrain, runtime, eng, now, ctx.contestFieldMode and 58 or 44, 1.0, {
            MaxThreat = ctx.contestFieldMode and 2.1 or 1.55,
            EnemyRadius = ctx.contestFieldMode and 30 or 24,
            MinTotalMass = ctx.contestFieldMode and 10 or 8,
            MaxTargets = ctx.contestFieldMode and 24 or 16,
        }) then
        ctx.reclaimField = ctx.reclaimField + 1
        acted = true
    end

    if isIdle
        and not constructing
        and (not acted)
        and not (isTechBuilder and techBuilderPriorityWork and not ctx.allowTechBuilderReclaim)
        and Reclaim.TryReclaimFieldZone(aiBrain, runtime, eng, ctx.reclaimFieldPos, now) then
        ctx.reclaimField = ctx.reclaimField + 1
        acted = true
    end

    if isIdle
        and not constructing
        and (not acted)
        and not (Recovery.ShouldPersistentSurplusSpend(runtime, now) or Recovery.ShouldScaleBaseEco(runtime, now))
        and not (isTechBuilder and techBuilderPriorityWork and not ctx.allowTechBuilderReclaim)
        and Reclaim.TryReclaimEnemyMex(aiBrain, runtime, eng, now) then
        ctx.reclaimEnemyMex = ctx.reclaimEnemyMex + 1
        acted = true
    end

    if (not acted)
        and isTechBuilder
        and techBuilderPriorityWork
        and not constructing
        and dist > 120
        and localThreat < 1.9 then
        if Common.RecallEngineer(runtime, eng, ctx.mainPos, now, 'tech_priority') then
            ctx.recoverCount = ctx.recoverCount + 1
            acted = true
        end
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

local ModuleEnv = getfenv(1)
rawset(ModuleEnv, 'ScoreFactoryBuilder', ScoreFactoryBuilder)
rawset(ModuleEnv, 'ScoreStructureBuilder', ScoreStructureBuilder)
rawset(ModuleEnv, 'AssignBuildersToUnfinishedFactory', AssignBuildersToUnfinishedFactory)
rawset(ModuleEnv, 'AssignBuildersToUnfinishedStructure', AssignBuildersToUnfinishedStructure)
rawset(ModuleEnv, 'GetPriorityUpgradeAssistTarget', GetPriorityUpgradeAssistTarget)
rawset(ModuleEnv, 'GetPriorityRepairTarget', GetPriorityRepairTarget)
rawset(ModuleEnv, 'GetPriorityBuildAssistTarget', GetPriorityBuildAssistTarget)
rawset(ModuleEnv, 'TryAssignAssistOrRepair', TryAssignAssistOrRepair)
rawset(ModuleEnv, 'DescribeStructureTaskTarget', DescribeStructureTaskTarget)
rawset(ModuleEnv, 'ProcessEngineer', ProcessEngineer)
return M


