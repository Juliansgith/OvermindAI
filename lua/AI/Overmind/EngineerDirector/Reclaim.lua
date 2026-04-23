local Common = import('/mods/OvermindAI/lua/AI/Overmind/EngineerDirector/Common.lua')
local Threat = import('/mods/OvermindAI/lua/AI/Overmind/EngineerDirector/Threat.lua')
local OvermindMemory = import('/mods/OvermindAI/lua/AI/Overmind/Memory.lua')

local EnemyMexCategory = categories.STRUCTURE * categories.MASSEXTRACTION
local LandCombatCategory = categories.MOBILE * categories.LAND - categories.ENGINEER - categories.SCOUT - categories.COMMAND


local M = {}

local function ReclaimSegmentKey(pos)
    if not pos then
        return false
    end
    return string.format('%d:%d', math.floor((pos[1] or 0) / 64), math.floor((pos[3] or 0) / 64))
end

local function GetReclaimSegment(runtime, targetPos, now)
    if not runtime or not targetPos then
        return false
    end
    local engState = runtime.EngineerState or {}
    runtime.EngineerState = engState
    engState.ReclaimSegments = engState.ReclaimSegments or {}

    if now >= ((engState.LastReclaimSegmentCleanup or -999) + 12) then
        engState.LastReclaimSegmentCleanup = now
        for key, segment in pairs(engState.ReclaimSegments) do
            local stale = now - (segment.LastSeenTime or now)
            local assignedExpired = (segment.AssignedUntil or -999) <= now
            if stale > 420 and assignedExpired then
                engState.ReclaimSegments[key] = nil
            elseif assignedExpired then
                segment.AssignedCount = 0
            end
        end
    end

    local key = ReclaimSegmentKey(targetPos)
    if not key then
        return false
    end
    local segment = engState.ReclaimSegments[key] or {
        Key = key,
        Pos = { targetPos[1], targetPos[2] or 0, targetPos[3] },
        AssignedCount = 0,
        AssignedUntil = -999,
        LastEnemySightingTime = -999,
        LastEngineerLossTime = -999,
        LastSeenTime = now,
    }
    segment.LastSeenTime = now
    engState.ReclaimSegments[key] = segment
    return segment
end

local function HasRecentSegmentDanger(segment, now, quotaForced, supported)
    if not segment then
        return false
    end

    local lossAge = now - (segment.LastEngineerLossTime or -999)
    if lossAge >= 0 and lossAge < 300 then
        return not (quotaForced and supported >= 2 and lossAge >= 120)
    end

    local sightAge = now - (segment.LastEnemySightingTime or -999)
    if sightAge >= 0 and sightAge < 120 then
        return not (quotaForced and supported >= 2 and sightAge >= 45)
    end

    return false
end

local function TryReclaimEnemyMex(aiBrain, runtime, eng, now)
    if not eng or eng.Dead then
        return false
    end
    local pos = eng.GetPosition and eng:GetPosition() or false
    if not pos then
        return false
    end

    local policy = runtime and runtime.EcoPolicy or {}
    local aggressiveContest = policy.ReclaimPressureMode == true
        or policy.ForwardContestBias == true
        or policy.PrioritizeProduction == true
        or policy.ContestMapMode == true
        or (policy.ReclaimEnemyMexBias or 0) >= 0.6
    local riskBias = policy.ReclaimRiskBias or 0
    local supportBias = policy.ReclaimSupportBias or 0
    local routeRiskBias = policy.ReclaimRouteRiskBias or 0
    local enemyMexBias = policy.ReclaimEnemyMexBias or 0

    runtime.EngineerEnemyMexReclaimCooldown = runtime.EngineerEnemyMexReclaimCooldown or {}
    local entityId = eng.EntityId or 0
    local last = runtime.EngineerEnemyMexReclaimCooldown[entityId] or -999
    local cooldown = math.max(6, math.min(18, (aggressiveContest and 10 or 14) - math.floor(enemyMexBias * 3)))
    if now - last < cooldown then
        return false
    end

    local searchRadius = math.max(20, math.min(40, (aggressiveContest and 32 or 26) + math.floor(enemyMexBias * 4)))
    local enemyMex = aiBrain:GetUnitsAroundPoint(EnemyMexCategory, pos, searchRadius, 'Enemy')
    if not enemyMex or table.getn(enemyMex) <= 0 then
        return false
    end

    local localThreat = aiBrain:GetThreatAtPosition(pos, 1, true, 'AntiSurface') or 0
    local escort = aiBrain:GetNumUnitsAroundPoint(
        categories.MOBILE * categories.LAND - categories.ENGINEER - categories.SCOUT - categories.COMMAND,
        pos,
        24,
        'Ally') or 0
    local localThreatCap = (aggressiveContest and 1.05 or 0.8) + riskBias + (enemyMexBias * 0.18)
    local minEscort = math.max(1, (aggressiveContest and 3 or 4) - math.floor(supportBias + math.max(0, enemyMexBias * 0.75)))
    if localThreat > localThreatCap or escort < minEscort or Threat.HasEnemyCombatNear(aiBrain, pos, aggressiveContest and 32 or 28) then
        return false
    end

    local reclaimTargets = {}
    local maxTargets = math.min(math.max(1, math.min(4, (aggressiveContest and 3 or 2) + math.floor(math.max(0, enemyMexBias)))), table.getn(enemyMex))
    for i = 1, maxTargets do
        local target = enemyMex[i]
        if target and not target.Dead then
            local targetPos = target.GetPosition and target:GetPosition() or false
            local routeRisk = targetPos and OvermindMemory.GetRouteRisk(aiBrain, pos, targetPos, 4, 42) or 999
            local targetThreat = targetPos and (aiBrain:GetThreatAtPosition(targetPos, 1, true, 'AntiSurface') or 0) or 999
            local enemyGuard = targetPos and (aiBrain:GetNumUnitsAroundPoint(
                categories.MOBILE * categories.LAND - categories.ENGINEER - categories.SCOUT - categories.COMMAND,
                targetPos,
                24,
                'Enemy') or 0) or 999
            local routeRiskCap = (aggressiveContest and 1.7 or 1.35) + (riskBias * 1.5) + routeRiskBias + (enemyMexBias * 0.35)
            local targetThreatCap = (aggressiveContest and 0.85 or 0.6) + (riskBias * 0.8) + (enemyMexBias * 0.15)
            local enemyGuardCap = (aggressiveContest and 1 or 0) + math.max(0, math.floor((riskBias * 2) + enemyMexBias))
            if targetPos and routeRisk <= routeRiskCap and targetThreat <= targetThreatCap and enemyGuard <= enemyGuardCap and not Threat.HasEnemyCombatNear(aiBrain, targetPos, aggressiveContest and 28 or 24) then
                table.insert(reclaimTargets, target)
            end
        end
    end
    if table.getn(reclaimTargets) <= 0 then
        return false
    end

    if IssueClearCommands then
        IssueClearCommands({ eng })
    end
    if IssueReclaim then
        local issued = false
        for _, target in reclaimTargets do
            if target and not target.Dead then
                IssueReclaim({ eng }, target)
                issued = true
            end
        end
        if issued then
            runtime.EngineerEnemyMexReclaimCooldown[entityId] = now
            return true
        end
    end

    return false
end

local function GetReclaimFieldTargets(targetPos, radius, minMass)
    if not targetPos then
        return {}, 0
    end

    local r = radius or 18
    local rect = Rect((targetPos[1] or 0) - r, (targetPos[3] or 0) - r, (targetPos[1] or 0) + r, (targetPos[3] or 0) + r)
    local reclaimRect = GetReclaimablesInRect(rect) or {}
    local targets = {}
    local totalMass = 0
    for _, reclaim in reclaimRect do
        local mass = reclaim and reclaim.MaxMassReclaim or 0
        local remaining = mass * (reclaim.ReclaimLeft or 1)
        if remaining >= (minMass or 1) then
            table.insert(targets, reclaim)
            totalMass = totalMass + remaining
        end
    end
    return targets, totalMass
end

local function TryReclaimFieldZone(aiBrain, runtime, eng, targetPos, now)
    if not eng or eng.Dead or not targetPos then
        return false
    end

    local planner = runtime and runtime.StrategicPlanner or {}
    local policy = runtime and runtime.EcoPolicy or {}
    local quotaForced = (policy.EngineerReclaimQuota or 0) > 0
    local riskBias = policy.ReclaimRiskBias or 0
    local supportBias = policy.ReclaimSupportBias or 0
    local nearbyBias = policy.ReclaimNearbyBias or 0
    local radiusBias = policy.ReclaimFieldRadiusBias or 0
    local massBias = policy.ReclaimFieldMassBias or 0
    local routeRiskBias = policy.ReclaimRouteRiskBias or 0
    if not (planner.ReclaimFirst == true or planner.OuterRetentionActive == true or quotaForced) then
        return false
    end

    local pos = eng.GetPosition and eng:GetPosition() or false
    local mainPos = Common.GetMainPos(aiBrain, runtime)
    if not pos or not mainPos then
        return false
    end

    local distMain = Common.Distance2D(targetPos, mainPos)
    local localThreat = aiBrain:GetThreatAtPosition(targetPos, 1, true, 'AntiSurface') or 0
    local routeRisk = OvermindMemory.GetRouteRisk(aiBrain, pos, targetPos, 4, 44)
    local allySupport = aiBrain:GetNumUnitsAroundPoint(LandCombatCategory, targetPos, 28, 'Ally') or 0
    local enemySupport = aiBrain:GetNumUnitsAroundPoint(LandCombatCategory, targetPos, 28, 'Enemy') or 0
    local outerTask = (((runtime or {}).ForceDirector or {}).Tasks or {}).outer_contest or {}
    local taskSupport = outerTask.CurrentUnits or 0
    local taskStrength = outerTask.CurrentStrength or 0
    local supported = math.max(allySupport, taskSupport, math.floor(taskStrength / 7))
    local outerBacked = taskSupport > 0 or taskStrength >= 8 or planner.OuterRetentionActive == true
    local segment = GetReclaimSegment(runtime, targetPos, now)
    local engineerLossRisk = OvermindMemory.GetEngineerLossRisk(aiBrain, targetPos, 44)
    if segment then
        segment.LastMassEstimate = 0
        segment.LastSupport = supported
        if enemySupport > 0 or localThreat > 0.35 or Threat.HasEnemyCombatNear(aiBrain, targetPos, planner.ReclaimFirst and 20 or 24) then
            segment.LastEnemySightingTime = now
        end
        if engineerLossRisk >= 1.2 then
            segment.LastEngineerLossTime = math.max(segment.LastEngineerLossTime or -999, ((aiBrain.OvermindMemory or {}).LastEngineerLossTime or now))
        end
    end
    if HasRecentSegmentDanger(segment, now, quotaForced, supported) then
        return false
    end

    local reclaimRadius = (planner.ReclaimFirst and 46 or 40) + (nearbyBias * 18) + radiusBias
    local minTargetMass = math.max(0.5, (planner.ReclaimFirst and 1.5 or 2.5) - nearbyBias - (massBias * 0.03))
    if quotaForced then
        reclaimRadius = math.max(reclaimRadius, 48)
        minTargetMass = math.min(minTargetMass, 1.0)
    end
    local reclaimTargets, reclaimMass = GetReclaimFieldTargets(targetPos, reclaimRadius, minTargetMass)
    local supportWeightedThreat = math.max(0, localThreat - (supported * 0.18))
    local threatCap = (planner.ReclaimFirst and (outerBacked and 2.75 or 2.35) or (outerBacked and 2.15 or 1.85)) + riskBias + (routeRiskBias * 0.2)
    local routeRiskCap = (planner.ReclaimFirst and (outerBacked and 5.2 or 4.5) or (outerBacked and 4.4 or 3.8)) + (riskBias * 1.4) + routeRiskBias
    local minSupport = math.max(0, (planner.ReclaimFirst and (outerBacked and 1 or 2) or (outerBacked and 2 or 3)) - math.floor(supportBias))
    if quotaForced then
        threatCap = threatCap + 0.35
        routeRiskCap = routeRiskCap + 0.55
        minSupport = math.max(0, minSupport - 1)
    end
    if segment then
        segment.LastMassEstimate = reclaimMass
    end

    local requiredMass = math.max(12, ((quotaForced and 30 or (planner.ReclaimFirst and 42 or 58)) * (1 - (nearbyBias * 0.22))) - massBias)
    if table.getn(reclaimTargets) <= 0 or reclaimMass < requiredMass then
        return false
    end
    if distMain > (((runtime.EcoPolicy or {}).SafeExpandDistance or 680) + 100) then
        return false
    end
    if supportWeightedThreat > threatCap then
        return false
    end
    if routeRisk > routeRiskCap then
        return false
    end
    if enemySupport > math.max(1, supported) then
        return false
    end
    if supported < minSupport and distMain > (outerBacked and 180 or 120) then
        return false
    end
    if Threat.HasEnemyCombatNear(aiBrain, targetPos, planner.ReclaimFirst and 20 or 24) and supported < (outerBacked and minSupport or (minSupport + 1)) then
        return false
    end

    table.sort(reclaimTargets, function(a, b)
        local apos = a.CachePosition or (a.GetPosition and a:GetPosition()) or targetPos
        local bpos = b.CachePosition or (b.GetPosition and b:GetPosition()) or targetPos
        return Common.Distance2D(apos, pos) < Common.Distance2D(bpos, pos)
    end)

    if IssueClearCommands then
        IssueClearCommands({ eng })
    end
    if IssueMove then
        IssueMove({ eng }, targetPos)
    end
    if IssueReclaim then
        local issued = 0
        for _, reclaim in reclaimTargets do
            if reclaim and (reclaim.MaxMassReclaim or 0) > 0 then
                IssueReclaim({ eng }, reclaim)
                issued = issued + 1
                if issued >= 24 then
                    break
                end
            end
        end
        if issued > 0 then
            if segment then
                segment.AssignedCount = (segment.AssignedCount or 0) + 1
                segment.AssignedUntil = math.max(segment.AssignedUntil or -999, now + 24)
                segment.LastAssignedTime = now
            end
            return true
        end
    end

    return false
end

local function TryReclaimNearby(aiBrain, runtime, eng, now, radius, minMass, options)
    if not eng or eng.Dead then
        return false
    end

    local pos = eng.GetPosition and eng:GetPosition() or false
    if not pos then
        return false
    end

    options = options or {}
    local policy = runtime and runtime.EcoPolicy or {}
    local riskBias = policy.ReclaimRiskBias or 0
    local nearbyBias = policy.ReclaimNearbyBias or 0
    local radiusBias = policy.ReclaimFieldRadiusBias or 0
    local massBias = policy.ReclaimFieldMassBias or 0
    local routeRiskBias = policy.ReclaimRouteRiskBias or 0
    local escort = aiBrain:GetNumUnitsAroundPoint(LandCombatCategory, pos, 28, 'Ally') or 0
    local localThreat = aiBrain:GetThreatAtPosition(pos, 1, true, 'AntiSurface') or 0
    local maxThreat = (options.MaxThreat or (escort >= 2 and 2.4 or 1.4)) + riskBias + (routeRiskBias * 0.15)
    if localThreat > maxThreat then
        return false
    end
    if Threat.HasEnemyCombatNear(aiBrain, pos, options.EnemyRadius or 26) and escort < (options.MinEscort or 2) then
        return false
    end

    local reclaimTargets, reclaimMass = GetReclaimFieldTargets(pos, (radius or 42) + (nearbyBias * 12) + (radiusBias * 0.65), minMass or 1)
    local minTotalMass = math.max(4, ((options.MinTotalMass or 8) * (1 - (nearbyBias * 0.25))) - (massBias * 0.25))
    if table.getn(reclaimTargets) <= 0 or reclaimMass < minTotalMass then
        return false
    end

    table.sort(reclaimTargets, function(a, b)
        local apos = a.CachePosition or (a.GetPosition and a:GetPosition()) or pos
        local bpos = b.CachePosition or (b.GetPosition and b:GetPosition()) or pos
        return Common.Distance2D(apos, pos) < Common.Distance2D(bpos, pos)
    end)

    if IssueClearCommands then
        IssueClearCommands({ eng })
    end
    if IssueReclaim then
        local issued = 0
        local maxTargets = math.max(8, (options.MaxTargets or 18) + math.floor(nearbyBias * 8))
        for _, reclaim in reclaimTargets do
            if reclaim and (reclaim.MaxMassReclaim or 0) > 0 then
                IssueReclaim({ eng }, reclaim)
                issued = issued + 1
                if issued >= maxTargets then
                    break
                end
            end
        end
        return issued > 0
    end

    return false
end


M.TryReclaimEnemyMex = TryReclaimEnemyMex
M.GetReclaimFieldTargets = GetReclaimFieldTargets
M.TryReclaimFieldZone = TryReclaimFieldZone
M.TryReclaimNearby = TryReclaimNearby
M.ReclaimSegmentKey = ReclaimSegmentKey
return M

