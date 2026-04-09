local OvermindMemory = import('/mods/OvermindAI/lua/AI/Overmind/Memory.lua')
local OvermindCombatExecution = import('/mods/OvermindAI/lua/AI/Overmind/CombatExecution.lua')

local PressureCategory = categories.MOBILE * (categories.LAND + categories.AIR) - categories.ENGINEER - categories.SCOUT - categories.COMMAND
local LandPressureCategory = categories.MOBILE * categories.LAND - categories.ENGINEER - categories.SCOUT - categories.COMMAND
local LandDirectEscortCategory = categories.MOBILE * categories.LAND * categories.DIRECTFIRE - categories.ENGINEER - categories.SCOUT - categories.COMMAND
local LandIndirectCategory = categories.MOBILE * categories.LAND * categories.INDIRECTFIRE - categories.ENGINEER - categories.SCOUT - categories.COMMAND
local LandAACategory = categories.MOBILE * categories.LAND * categories.ANTIAIR - categories.ENGINEER - categories.SCOUT - categories.COMMAND

local function Distance2D(a, b)
    local dx = (a[1] or 0) - (b[1] or 0)
    local dz = (a[3] or 0) - (b[3] or 0)
    return math.sqrt((dx * dx) + (dz * dz))
end

local function LerpPos(a, b, t)
    if not a or not b then
        return b or a
    end
    local clampedT = math.max(0, math.min(1, t or 0.5))
    return {
        a[1] + ((b[1] - a[1]) * clampedT),
        0,
        a[3] + ((b[3] - a[3]) * clampedT),
    }
end

local function BuildDetourPoint(fromPos, toPos, sideBias)
    if not fromPos or not toPos then
        return toPos or fromPos
    end
    local mid = LerpPos(fromPos, toPos, 0.5)
    local dx = (toPos[1] or 0) - (fromPos[1] or 0)
    local dz = (toPos[3] or 0) - (fromPos[3] or 0)
    local mag = math.sqrt((dx * dx) + (dz * dz))
    if mag < 0.001 then
        return mid
    end
    local nx = -dz / mag
    local nz = dx / mag
    local side = (math.mod((sideBias or 1), 2) == 0) and -1 or 1
    local offset = 24
    return {
        (mid[1] or 0) + (nx * offset * side),
        0,
        (mid[3] or 0) + (nz * offset * side),
    }
end

local function RetreatFromEnemy(homePos, enemyPos, factor)
    if not homePos then
        return false
    end
    if not enemyPos then
        return homePos
    end

    local k = factor or 0.35
    return {
        (homePos[1] or 0) + (((homePos[1] or 0) - (enemyPos[1] or 0)) * k),
        0,
        (homePos[3] or 0) + (((homePos[3] or 0) - (enemyPos[3] or 0)) * k),
    }
end

local function MoveAwayFromEnemy(pos, enemyPos, distance)
    if not pos or not enemyPos then
        return pos
    end
    local dx = (pos[1] or 0) - (enemyPos[1] or 0)
    local dz = (pos[3] or 0) - (enemyPos[3] or 0)
    local mag = math.sqrt((dx * dx) + (dz * dz))
    if mag < 0.001 then
        return { (pos[1] or 0) + distance, 0, (pos[3] or 0) }
    end
    local scale = (distance or 12) / mag
    return {
        (pos[1] or 0) + (dx * scale),
        0,
        (pos[3] or 0) + (dz * scale),
    }
end

local function IsBrainValid(brain)
    return brain and not brain:IsDefeated()
end

local function GetBrainAnchorPosition(aiBrain)
    if aiBrain.BuilderManagers and aiBrain.BuilderManagers['MAIN'] and aiBrain.BuilderManagers['MAIN'].Position then
        return aiBrain.BuilderManagers['MAIN'].Position
    end

    local acu = aiBrain:GetListOfUnits(categories.COMMAND, false, true)
    if acu and table.getn(acu) > 0 then
        return acu[1]:GetPosition()
    end

    return false
end

local function IsRetreatTargetSafe(aiBrain, targetPos, localThreat, forceStats)
    if not aiBrain or not targetPos then
        return false
    end
    local targetThreat = aiBrain:GetThreatAtPosition(targetPos, 2, true, 'AntiSurface') or 0
    local targetEnemy = aiBrain:GetNumUnitsAroundPoint(PressureCategory, targetPos, 34, 'Enemy') or 0
    local targetAlly = aiBrain:GetNumUnitsAroundPoint(PressureCategory, targetPos, 34, 'Ally') or 0
    local baseGuard = (forceStats and forceStats.BaseGuard) or 0
    if targetEnemy == 0 and targetThreat <= math.max(2.0, localThreat + 0.8) then
        return true
    end
    if targetThreat > math.max(localThreat + 1.8, 4.0) then
        return false
    end
    return (targetAlly + baseGuard) >= math.max(4, targetEnemy + 2)
end

local function GetSafeRetreatTarget(aiBrain, acuPos, homePos, enemyPos, localThreat, forceStats, sideBias)
    if not homePos then
        return false
    end
    if IsRetreatTargetSafe(aiBrain, homePos, localThreat, forceStats) then
        return homePos
    end

    local candidates = {
        LerpPos(acuPos, homePos, 0.45),
        LerpPos(acuPos, homePos, 0.6),
        BuildDetourPoint(acuPos, homePos, sideBias),
    }
    if enemyPos then
        table.insert(candidates, RetreatFromEnemy(homePos, enemyPos, 0.22))
    end

    local best = false
    local bestThreat = 9999
    for _, candidate in candidates do
        if candidate then
            local candidateThreat = aiBrain:GetThreatAtPosition(candidate, 2, true, 'AntiSurface') or 0
            local candidateEnemy = aiBrain:GetNumUnitsAroundPoint(PressureCategory, candidate, 30, 'Enemy') or 0
            local candidateAlly = aiBrain:GetNumUnitsAroundPoint(PressureCategory, candidate, 30, 'Ally') or 0
            local baseGuard = (forceStats and forceStats.BaseGuard) or 0
            if candidateThreat < bestThreat and (candidateEnemy == 0 or (candidateAlly + baseGuard) >= candidateEnemy) then
                best = candidate
                bestThreat = candidateThreat
            end
        end
    end

    return best or homePos
end

local function GetNearestEnemyBasePosition(aiBrain, ownPos)
    local nearestPos = false
    local nearestDist = 100000

    for _, enemyBrain in ArmyBrains do
        local isEnemy = false
        if IsEnemy then
            isEnemy = IsEnemy(enemyBrain:GetArmyIndex(), aiBrain:GetArmyIndex())
        end

        if enemyBrain ~= aiBrain and IsBrainValid(enemyBrain) and isEnemy then
            local enemyPos = GetBrainAnchorPosition(enemyBrain)
            if enemyPos then
                local dist = Distance2D(ownPos, enemyPos)
                if dist < nearestDist then
                    nearestDist = dist
                    nearestPos = enemyPos
                end
            end
        end
    end

    return nearestPos
end

function RefreshStrategicState(aiBrain, now)
    local runtime = aiBrain.OvermindRuntime
    if not runtime then
        return
    end

    local ownPos = GetBrainAnchorPosition(aiBrain)
    if not ownPos then
        return
    end

    runtime.OwnMainPos = ownPos
    local intel = runtime.IntelModel or {}
    runtime.PrimaryEnemyPos = intel.EnemyMainPos or GetNearestEnemyBasePosition(aiBrain, ownPos)
    if runtime.StrategyFocusPos then
        runtime.PrimaryEnemyPos = runtime.StrategyFocusPos
    elseif intel.BestRaidPos and runtime.StrategyGoal == 'raid' then
        runtime.PrimaryEnemyPos = intel.BestRaidPos
    elseif intel.BestExpansionPos and runtime.StrategyGoal == 'expand' then
        runtime.PrimaryEnemyPos = intel.BestExpansionPos
    elseif runtime.ZoneModel and runtime.ZoneModel.BestRaidPos and runtime.StrategyGoal == 'raid' then
        runtime.PrimaryEnemyPos = runtime.ZoneModel.BestRaidPos
    elseif runtime.ZoneModel and runtime.ZoneModel.BestExpansionPos and runtime.StrategyGoal == 'expand' then
        runtime.PrimaryEnemyPos = runtime.ZoneModel.BestExpansionPos
    end
    runtime.CombatMomentum = OvermindMemory.GetCombatMomentum(aiBrain)
    runtime.LastStrategicRefresh = now

    if runtime.PrimaryEnemyPos then
        local enemyStrength = (runtime.OpponentModel and runtime.OpponentModel.Mobile) or 6
        OvermindMemory.RecordEnemySighting(aiBrain, runtime.PrimaryEnemyPos, math.max(0.8, enemyStrength / 20))
        runtime.LastEnemyContactTime = now
    end
end

function RunPressureCycle(aiBrain, now)
    return OvermindCombatExecution.RunPressureCycle(aiBrain, now)
end

local function GetACU(aiBrain)
    local acu = aiBrain:GetListOfUnits(categories.COMMAND, false, true)
    if acu and table.getn(acu) > 0 and acu[1] and not acu[1].Dead then
        return acu[1]
    end
    return false
end

function EnforceCommanderSafety(aiBrain, now)
    local runtime = aiBrain.OvermindRuntime
    if not runtime then
        return
    end

    local acu = GetACU(aiBrain)
    if not acu then
        return
    end

    local homePos = runtime.OwnMainPos or GetBrainAnchorPosition(aiBrain)
    local acuPos = acu:GetPosition()
    if not homePos or not acuPos then
        return
    end

    local distance = Distance2D(acuPos, homePos)
    local factoryCount = aiBrain:GetCurrentUnits(categories.FACTORY * categories.STRUCTURE) or 0
    local combatCount = aiBrain:GetCurrentUnits(PressureCategory) or 0
    local escortCount = aiBrain:GetNumUnitsAroundPoint(PressureCategory, acuPos, 32, 'Ally') or 0
    local enemyRaiders = aiBrain:GetNumUnitsAroundPoint(PressureCategory, acuPos, 34, 'Enemy') or 0
    local localThreat = aiBrain:GetThreatAtPosition(acuPos, 2, true, 'AntiSurface') or 0
    local homeThreat = aiBrain:GetThreatAtPosition(homePos, 2, true, 'AntiSurface') or 0
    local forceStats = ((runtime.ForceDirector or {}).Stats) or {}
    local healthRatio = 1
    if acu.GetHealth and acu.GetMaxHealth then
        local maxHealth = math.max(1, acu:GetMaxHealth() or 1)
        healthRatio = (acu:GetHealth() or maxHealth) / maxHealth
    end

    local policy = runtime.EcoPolicy or {}
    local openingLockTime = math.max(320, policy.OpeningLockTime or 420)
    local openingMaxDistance = math.min(policy.AcuOpeningMaxDistance or 20, 14)
    local midMaxDistance = math.min(policy.AcuMidMaxDistance or 36, 24)
    local lateMaxDistance = math.min(policy.AcuLateMaxDistance or 62, 42)

    local openingLock = now < openingLockTime and (factoryCount < 3 or combatCount < 20)
    local underThreat = localThreat > math.max(3, homeThreat + 1.5)
    local lowHealth = healthRatio < 0.78
    local underEscorted = escortCount < 5 and distance > (openingMaxDistance + 2)
    local hardAnchor = now < 520 and distance > (openingMaxDistance + 4) and escortCount < 10
    local raid = runtime.RaidDefense or {}
    local raidRecall = (raid.UnderLandHarass or raid.UnderAirHarass)
        and distance > 14
        and (escortCount < 8 or enemyRaiders > 1 or localThreat > (homeThreat + 3.5))
    local enemyContactUnsafe = enemyRaiders >= 1
        and escortCount < 7
        and distance > 10
        and (enemyRaiders >= 2 or localThreat > (homeThreat + 2.0))
    local maxDistance = lateMaxDistance
    if now < 720 then
        maxDistance = midMaxDistance
    end
    if openingLock then
        maxDistance = openingMaxDistance
    end
    if now < 360 then
        maxDistance = math.min(maxDistance, openingMaxDistance)
    end
    local heavilyEscortedForward = escortCount >= 10
        and healthRatio >= 0.84
        and enemyRaiders <= 2
        and localThreat <= (homeThreat + 3.6)
    local stableEscortedForward = escortCount >= 6
        and healthRatio >= 0.80
        and enemyRaiders <= 2
        and localThreat <= (homeThreat + 2.8)
    if runtime.ACURoleMaxDistance then
        local leashAllowance = 6
        if heavilyEscortedForward then
            leashAllowance = 12
        elseif stableEscortedForward then
            leashAllowance = 8
        end
        maxDistance = math.min(maxDistance, runtime.ACURoleMaxDistance + leashAllowance)
    end

    local explicitPush = runtime.ACURole == 'push' and escortCount >= 12 and localThreat < (homeThreat + 1.6)
    local earlyHardLeash = now < 380 and distance > 16 and escortCount < 8 and not explicitPush
    local strictLeashActive = now < (runtime.ACUStrictLeashUntil or -999)
    if strictLeashActive then
        maxDistance = math.min(maxDistance, heavilyEscortedForward and 18 or 16)
    end
    local longRoamUnsafe = distance > math.max(54, maxDistance + 18)
        and escortCount < 12
        and healthRatio >= 0.86
        and enemyRaiders <= 1
        and localThreat <= (homeThreat + 1.0)
        and not lowHealth

    local catastrophicDistance = math.max(maxDistance + (heavilyEscortedForward and 14 or 8), heavilyEscortedForward and 34 or 24)
    local hardOverextendDistance = distance > catastrophicDistance
        or (distance > 16 and now < 1200 and escortCount <= 3 and enemyRaiders > 0)
        or (distance > 14 and now < 720 and escortCount <= 2)

    local shouldRecall = distance > maxDistance and (openingLock or underThreat or lowHealth or underEscorted or hardAnchor or raidRecall or enemyContactUnsafe)
    if earlyHardLeash then
        shouldRecall = true
    end
    if longRoamUnsafe then
        shouldRecall = true
    end
    if hardOverextendDistance then
        shouldRecall = true
    end

    local q = acu.GetCommandQueue and acu:GetCommandQueue() or false
    local isIdle = (not q or table.getn(q) == 0)
    local isConstructing = acu:IsUnitState('Building') or acu:IsUnitState('Upgrading')
    local idleFar = isIdle and distance > math.max(15, maxDistance + 3)
    local constraints = ((runtime.ProductionDirector or {}).ConstraintState) or {}
    local starterSafeLeash = constraints.StarterPhase
        and not constraints.ConfirmedHarass
        and not raid.UnderLandHarass
        and not raid.UnderAirHarass
        and localThreat <= (homeThreat + 1.0)
        and enemyRaiders <= 0
        and distance <= math.max(22, maxDistance + 6)

    local lastPos = runtime.LastAcuPos or acuPos
    local moved = Distance2D(acuPos, lastPos)
    if moved > 1.5 then
        runtime.LastAcuMoveTime = now
        runtime.LastAcuPos = { acuPos[1], acuPos[2], acuPos[3] }
    elseif not runtime.LastAcuMoveTime then
        runtime.LastAcuMoveTime = now
        runtime.LastAcuPos = { acuPos[1], acuPos[2], acuPos[3] }
    end
    local stuckFar = distance > math.max(22, maxDistance + 3) and (now - (runtime.LastAcuMoveTime or now)) > 8
    local noMansLand = distance > 20 and (localThreat > 0.8 or enemyRaiders > 0) and escortCount <= 4
    local retreatTargetSafe = IsRetreatTargetSafe(aiBrain, homePos, localThreat, forceStats)
    local escortCollapsed = escortCount <= math.min(4, math.max(2, enemyRaiders))
    local threatCollapse = localThreat > (homeThreat + 3.4)
    local catastrophicOverextend = hardOverextendDistance and (lowHealth or escortCollapsed or threatCollapse or noMansLand or not retreatTargetSafe)
    local insideDefendedSpace = distance <= math.max(12, math.min(20, maxDistance + 2))
        and (escortCount >= 3 or (forceStats.BaseGuard or 0) >= 4)
        and localThreat <= (homeThreat + 1.2)
        and enemyRaiders <= 1
    local defendedButStatic = distance <= math.max(18, maxDistance + 4)
        and (escortCount >= 4 or (forceStats.BaseGuard or 0) >= 5)
        and localThreat <= (homeThreat + 1.8)
        and enemyRaiders <= 1
    if insideDefendedSpace and not lowHealth and not catastrophicOverextend and not enemyContactUnsafe and not raidRecall then
        shouldRecall = false
        earlyHardLeash = false
        noMansLand = false
        stuckFar = false
    end
    if starterSafeLeash and not lowHealth and not catastrophicOverextend and not enemyContactUnsafe and not raidRecall then
        shouldRecall = false
        earlyHardLeash = false
        idleFar = false
        noMansLand = false
        stuckFar = false
    end
    if defendedButStatic and not lowHealth and not catastrophicOverextend and not enemyContactUnsafe and not raidRecall then
        stuckFar = false
    end
    local alreadySafeAtHome = insideDefendedSpace
        and distance <= math.max(12, maxDistance + 1.5)
        and escortCount >= 3
        and healthRatio >= 0.82
        and localThreat <= (homeThreat + 1.8)
    if alreadySafeAtHome and not lowHealth and not catastrophicOverextend then
        shouldRecall = false
        idleFar = false
        stuckFar = false
        noMansLand = false
        enemyContactUnsafe = false
        raidRecall = false
    end
    local stableEscortedPerimeter = distance <= math.max(18, maxDistance + 6)
        and escortCount >= 4
        and healthRatio >= 0.8
        and localThreat <= (homeThreat + 3.2)
        and not lowHealth
        and not catastrophicOverextend
    local heavilyEscortedNearHome = distance <= math.max(16, maxDistance + 4)
        and escortCount >= 8
        and healthRatio >= 0.84
        and localThreat <= (homeThreat + 4.0)
        and enemyRaiders <= 2
        and not lowHealth
        and not catastrophicOverextend
    local moderateEscortedLeash = stableEscortedForward
        and distance <= math.max(28, maxDistance + 8)
        and localThreat <= (homeThreat + 3.6)
        and not catastrophicOverextend
    local secureEscortedPosture = distance <= math.max(24, maxDistance + 8)
        and escortCount >= 10
        and healthRatio >= 0.86
        and enemyRaiders <= 1
        and localThreat <= (homeThreat + 2.2)
        and not lowHealth
        and not catastrophicOverextend
    local leashReposition = distance > math.max(maxDistance + 2, 20)
        and not shouldRecall
        and not lowHealth
        and escortCount >= 4
        and localThreat <= (homeThreat + 2.6)
        and not enemyContactUnsafe
        and not raidRecall
        and not noMansLand
    if stableEscortedPerimeter and not enemyContactUnsafe and not noMansLand then
        shouldRecall = false
        idleFar = false
        stuckFar = false
        earlyHardLeash = false
        raidRecall = false
    end
    if heavilyEscortedNearHome and not enemyContactUnsafe and not noMansLand then
        shouldRecall = false
        idleFar = false
        stuckFar = false
        earlyHardLeash = false
        raidRecall = false
        enemyContactUnsafe = false
    end
    if moderateEscortedLeash and not enemyContactUnsafe and not noMansLand and not raidRecall then
        shouldRecall = false
        idleFar = false
        stuckFar = false
        earlyHardLeash = false
    end
    if secureEscortedPosture then
        shouldRecall = false
        idleFar = false
        stuckFar = false
        earlyHardLeash = false
        noMansLand = false
        enemyContactUnsafe = false
        raidRecall = false
        underThreat = false
    end

    local canInterruptConstruction = catastrophicOverextend
        or enemyContactUnsafe
        or lowHealth
        or underThreat
        or raidRecall
        or noMansLand
    if isConstructing and not canInterruptConstruction then
        runtime.LastAcuDistanceFromBase = distance
        return
    end

    if shouldRecall or idleFar or stuckFar or noMansLand or enemyContactUnsafe or raidRecall or leashReposition then
        local lastRecall = runtime.LastAcuRecallTime or -100
        local recallCooldown = 4.0
        if raidRecall or enemyContactUnsafe then
            recallCooldown = 2.2
        end
        if catastrophicOverextend then
            recallCooldown = 1.4
        end
        local severeDanger = lowHealth or localThreat > (homeThreat + 2.2) or enemyContactUnsafe or raidRecall or noMansLand or catastrophicOverextend
        local sinceRecall = now - lastRecall
        local distanceAfterRecall = runtime.LastAcuRecallDistance or 9999
        local closingToBase = distance <= (distanceAfterRecall - 1.2)
        local settlingNearBase = closingToBase and distance <= math.max(14, maxDistance + 2)
        local retreatingSuccessfully = closingToBase
            and q
            and table.getn(q) > 0
            and escortCount >= 8
            and healthRatio >= 0.82
            and localThreat <= ((runtime.LastAcuRecallLocalThreat or localThreat) + 4.0)
        local recallAction = 'threat_recall'
        if catastrophicOverextend then
            recallAction = 'panic_leash_recall'
        elseif leashReposition then
            recallAction = 'leash_reposition'
        elseif stuckFar then
            recallAction = 'stuck_recall'
        elseif noMansLand then
            recallAction = 'nml_recall'
        elseif enemyContactUnsafe then
            recallAction = 'enemy_contact_recall'
        elseif raidRecall then
            recallAction = 'raid_cover_recall'
        elseif earlyHardLeash then
            recallAction = 'early_leash_recall'
        elseif idleFar then
            recallAction = 'idle_far_recall'
        elseif longRoamUnsafe then
            recallAction = 'long_roam_recall'
        elseif openingLock or hardAnchor then
            recallAction = 'opening_recall'
        elseif lowHealth then
            recallAction = 'low_health_recall'
        end
        local recallReasonTimes = runtime.AcuRecallReasonTimes or {}
        runtime.AcuRecallReasonTimes = recallReasonTimes
        local lastReasonTime = recallReasonTimes[recallAction] or -100
        local sinceReason = now - lastReasonTime
        local reasonCooldown = 10.0
        if recallAction == 'panic_leash_recall' then
            reasonCooldown = 6.0
        elseif recallAction == 'low_health_recall' then
            reasonCooldown = 4.0
        elseif recallAction == 'enemy_contact_recall' then
            reasonCooldown = 7.0
        elseif recallAction == 'raid_cover_recall' then
            reasonCooldown = 10.0
        elseif recallAction == 'threat_recall' then
            reasonCooldown = 12.0
        elseif recallAction == 'opening_recall' or recallAction == 'idle_far_recall' then
            reasonCooldown = 16.0
        elseif recallAction == 'long_roam_recall' then
            reasonCooldown = 20.0
        elseif recallAction == 'early_leash_recall' then
            reasonCooldown = 14.0
        elseif recallAction == 'stuck_recall' then
            reasonCooldown = 9.0
        elseif recallAction == 'leash_reposition' then
            reasonCooldown = 8.0
        end
        local worseningThreat = localThreat >= ((runtime.LastAcuRecallLocalThreat or localThreat) + 2.5)
            or homeThreat >= ((runtime.LastAcuRecallHomeThreat or homeThreat) + 1.5)
            or enemyRaiders >= ((runtime.LastAcuRecallEnemyRaiders or enemyRaiders) + 1)
        local recallEscalated = catastrophicOverextend
            or (severeDanger and (lowHealth or enemyContactUnsafe or localThreat > (homeThreat + 2.8)))
            or stuckFar
        if recallAction == 'leash_reposition' then
            recallEscalated = false
        end
        if heavilyEscortedForward and not lowHealth and not enemyContactUnsafe and not noMansLand then
            recallEscalated = catastrophicOverextend or stuckFar
        end
        if retreatingSuccessfully and not recallEscalated then
            runtime.LastAcuDistanceFromBase = distance
            return
        end
        if insideDefendedSpace and not recallEscalated then
            runtime.LastAcuDistanceFromBase = distance
            return
        end
        if alreadySafeAtHome and sinceRecall < 22 then
            runtime.LastAcuDistanceFromBase = distance
            return
        end
        if stableEscortedPerimeter and not recallEscalated and sinceRecall < 24 then
            runtime.LastAcuDistanceFromBase = distance
            return
        end
        if heavilyEscortedNearHome and not recallEscalated and sinceRecall < 30 then
            runtime.LastAcuDistanceFromBase = distance
            return
        end
        if moderateEscortedLeash and not recallEscalated and sinceRecall < 24 then
            runtime.LastAcuDistanceFromBase = distance
            return
        end
        if secureEscortedPosture and not recallEscalated and sinceRecall < 32 then
            runtime.LastAcuDistanceFromBase = distance
            return
        end
        if (recallAction == 'raid_cover_recall' or recallAction == 'stuck_recall' or recallAction == 'panic_leash_recall')
            and retreatingSuccessfully
            and sinceRecall < 18 then
            runtime.LastAcuDistanceFromBase = distance
            return
        end
        if recallAction == 'threat_recall'
            and secureEscortedPosture
            and sinceRecall < 28 then
            runtime.LastAcuDistanceFromBase = distance
            return
        end
        if recallAction == 'raid_cover_recall'
            and heavilyEscortedForward
            and escortCount >= 10
            and enemyRaiders <= 1
            and localThreat <= (homeThreat + 2.4)
            and sinceRecall < 24 then
            runtime.LastAcuDistanceFromBase = distance
            return
        end
        if not recallEscalated and sinceRecall < math.max(recallCooldown, 7.0) then
            runtime.LastAcuDistanceFromBase = distance
            return
        end
        if not recallEscalated and sinceReason < reasonCooldown and not worseningThreat then
            runtime.LastAcuDistanceFromBase = distance
            return
        end
        if not recallEscalated and closingToBase and sinceRecall < 10.5 then
            runtime.LastAcuDistanceFromBase = distance
            return
        end
        if not recallEscalated and settlingNearBase and sinceRecall < 18 then
            runtime.LastAcuDistanceFromBase = distance
            return
        end
        if not recallEscalated and q and table.getn(q) > 0 and sinceRecall < 9.0 then
            runtime.LastAcuDistanceFromBase = distance
            return
        end
        if stuckFar and defendedButStatic and sinceRecall < 14.0 then
            runtime.LastAcuDistanceFromBase = distance
            return
        end
        if (now - lastRecall) > recallCooldown then
            local recallPos = GetSafeRetreatTarget(aiBrain, acuPos, homePos, runtime.PrimaryEnemyPos, localThreat, forceStats, aiBrain:GetArmyIndex())
            if severeDanger then
                recallPos = GetSafeRetreatTarget(aiBrain, acuPos, RetreatFromEnemy(homePos, runtime.PrimaryEnemyPos, 0.42) or homePos, runtime.PrimaryEnemyPos, localThreat, forceStats, aiBrain:GetArmyIndex())
                runtime.ACUSafetyLockUntil = math.max(runtime.ACUSafetyLockUntil or -999, now + 24)
            elseif recallAction == 'leash_reposition' then
                recallPos = LerpPos(acuPos, recallPos or homePos, 0.45)
            elseif earlyHardLeash or openingLock or hardAnchor then
                runtime.ACUSafetyLockUntil = math.max(runtime.ACUSafetyLockUntil or -999, now + 12)
            end
            if catastrophicOverextend then
                runtime.ACUStrictLeashUntil = math.max(runtime.ACUStrictLeashUntil or -999, now + 100)
            elseif severeDanger then
                runtime.ACUStrictLeashUntil = math.max(runtime.ACUStrictLeashUntil or -999, now + 45)
            end

            if severeDanger and recallAction ~= 'leash_reposition' and IssueClearCommands then
                IssueClearCommands({ acu })
            end
            if IssueMove then
                if catastrophicOverextend then
                    local stage = LerpPos(acuPos, homePos, 0.5)
                    if stage then
                        IssueMove({ acu }, stage)
                    end
                end
                IssueMove({ acu }, recallPos)
            end
            runtime.LastAcuRecallTime = now
            runtime.LastAcuRecallDistance = distance
            runtime.LastAcuRecallLocalThreat = localThreat
            runtime.LastAcuRecallHomeThreat = homeThreat
            runtime.LastAcuRecallEnemyRaiders = enemyRaiders
            recallReasonTimes[recallAction] = now
            runtime.LastAcuSafetyAction = recallAction
            LOG(string.format('*OVERMIND ACU SAFETY A%d action=%s dist=%.1f esc=%d lth=%.1f hth=%.1f hp=%.2f',
                aiBrain:GetArmyIndex(),
                runtime.LastAcuSafetyAction or 'unknown',
                distance,
                escortCount,
                localThreat,
                homeThreat,
                healthRatio))
        end
    end

    runtime.LastAcuDistanceFromBase = distance
end

