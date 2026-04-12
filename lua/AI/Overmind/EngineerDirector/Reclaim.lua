local Common = import('/mods/OvermindAI/lua/AI/Overmind/EngineerDirector/Common.lua')
local Threat = import('/mods/OvermindAI/lua/AI/Overmind/EngineerDirector/Threat.lua')
local OvermindMemory = import('/mods/OvermindAI/lua/AI/Overmind/Memory.lua')

local EnemyMexCategory = categories.STRUCTURE * categories.MASSEXTRACTION
local LandCombatCategory = categories.MOBILE * categories.LAND - categories.ENGINEER - categories.SCOUT - categories.COMMAND

local Distance2D = Common.Distance2D
local GetMainPos = Common.GetMainPos
local HasEnemyCombatNear = Threat.HasEnemyCombatNear

local M = {}

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

    runtime.EngineerEnemyMexReclaimCooldown = runtime.EngineerEnemyMexReclaimCooldown or {}
    local entityId = eng.EntityId or 0
    local last = runtime.EngineerEnemyMexReclaimCooldown[entityId] or -999
    if now - last < (aggressiveContest and 10 or 14) then
        return false
    end

    local enemyMex = aiBrain:GetUnitsAroundPoint(EnemyMexCategory, pos, aggressiveContest and 32 or 26, 'Enemy')
    if not enemyMex or table.getn(enemyMex) <= 0 then
        return false
    end

    local localThreat = aiBrain:GetThreatAtPosition(pos, 1, true, 'AntiSurface') or 0
    local escort = aiBrain:GetNumUnitsAroundPoint(
        categories.MOBILE * categories.LAND - categories.ENGINEER - categories.SCOUT - categories.COMMAND,
        pos,
        24,
        'Ally') or 0
    local localThreatCap = aggressiveContest and 1.05 or 0.8
    local minEscort = aggressiveContest and 3 or 4
    if localThreat > localThreatCap or escort < minEscort or HasEnemyCombatNear(aiBrain, pos, aggressiveContest and 32 or 28) then
        return false
    end

    local reclaimTargets = {}
    local maxTargets = math.min(aggressiveContest and 3 or 2, table.getn(enemyMex))
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
            local routeRiskCap = aggressiveContest and 1.7 or 1.35
            local targetThreatCap = aggressiveContest and 0.85 or 0.6
            local enemyGuardCap = aggressiveContest and 1 or 0
            if targetPos and routeRisk <= routeRiskCap and targetThreat <= targetThreatCap and enemyGuard <= enemyGuardCap and not HasEnemyCombatNear(aiBrain, targetPos, aggressiveContest and 28 or 24) then
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
        if mass > (minMass or 10) then
            table.insert(targets, reclaim)
            totalMass = totalMass + (mass * (reclaim.ReclaimLeft or 1))
        end
    end
    return targets, totalMass
end

local function TryReclaimFieldZone(aiBrain, runtime, eng, targetPos, now)
    if not eng or eng.Dead or not targetPos then
        return false
    end

    local planner = runtime and runtime.StrategicPlanner or {}
    if not (planner.ReclaimFirst == true or planner.OuterRetentionActive == true) then
        return false
    end

    local pos = eng.GetPosition and eng:GetPosition() or false
    local mainPos = GetMainPos(aiBrain, runtime)
    if not pos or not mainPos then
        return false
    end

    local distMain = Distance2D(targetPos, mainPos)
    local localThreat = aiBrain:GetThreatAtPosition(targetPos, 1, true, 'AntiSurface') or 0
    local routeRisk = OvermindMemory.GetRouteRisk(aiBrain, pos, targetPos, 4, 44)
    local allySupport = aiBrain:GetNumUnitsAroundPoint(LandCombatCategory, targetPos, 28, 'Ally') or 0
    local enemySupport = aiBrain:GetNumUnitsAroundPoint(LandCombatCategory, targetPos, 28, 'Enemy') or 0
    local outerTask = (((runtime or {}).ForceDirector or {}).Tasks or {}).outer_contest or {}
    local taskSupport = outerTask.CurrentUnits or 0
    local taskStrength = outerTask.CurrentStrength or 0
    local supported = math.max(allySupport, taskSupport, math.floor(taskStrength / 7))
    local outerBacked = taskSupport > 0 or taskStrength >= 8 or planner.OuterRetentionActive == true
    local reclaimTargets, reclaimMass = GetReclaimFieldTargets(targetPos, planner.ReclaimFirst and 22 or 20, planner.ReclaimFirst and 6 or 10)
    local supportWeightedThreat = math.max(0, localThreat - (supported * 0.18))
    local threatCap = planner.ReclaimFirst and (outerBacked and 2.35 or 2.0) or (outerBacked and 1.8 or 1.5)
    local routeRiskCap = planner.ReclaimFirst and (outerBacked and 4.0 or 3.5) or (outerBacked and 3.4 or 3.0)
    local minSupport = planner.ReclaimFirst and (outerBacked and 1 or 2) or (outerBacked and 2 or 3)

    if table.getn(reclaimTargets) <= 0 or reclaimMass < (planner.ReclaimFirst and 80 or 120) then
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
    if HasEnemyCombatNear(aiBrain, targetPos, planner.ReclaimFirst and 20 or 24) and supported < (outerBacked and minSupport or (minSupport + 1)) then
        return false
    end

    table.sort(reclaimTargets, function(a, b)
        local apos = a.CachePosition or (a.GetPosition and a:GetPosition()) or targetPos
        local bpos = b.CachePosition or (b.GetPosition and b:GetPosition()) or targetPos
        return Distance2D(apos, pos) < Distance2D(bpos, pos)
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
                if issued >= 8 then
                    break
                end
            end
        end
        if issued > 0 then
            return true
        end
    end

    return false
end


M.TryReclaimEnemyMex = TryReclaimEnemyMex
M.GetReclaimFieldTargets = GetReclaimFieldTargets
M.TryReclaimFieldZone = TryReclaimFieldZone
return M
