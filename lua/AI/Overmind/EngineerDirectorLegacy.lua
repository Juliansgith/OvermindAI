local AIUtils = import('/lua/ai/aiutilities.lua')
local OvermindMemory = import('/mods/OvermindAI/lua/AI/Overmind/Memory.lua')
local OvermindEconomyLedger = import('/mods/OvermindAI/lua/AI/Overmind/EconomyLedger.lua')

local T1MexCategory = categories.STRUCTURE * categories.MASSEXTRACTION * categories.TECH1
local EnemyMexCategory = categories.STRUCTURE * categories.MASSEXTRACTION
local FactoryCategory = categories.FACTORY * categories.STRUCTURE
local StructureCategory = categories.STRUCTURE - categories.FACTORY
local MexCategory = categories.STRUCTURE * categories.MASSEXTRACTION
local EnergyCategory = categories.STRUCTURE * categories.ENERGYPRODUCTION
local Tech2PowerCategory = categories.STRUCTURE * categories.ENERGYPRODUCTION * (categories.TECH2 + categories.TECH3)
local RadarCategory = categories.STRUCTURE * categories.RADAR
local AADefenseCategory = categories.STRUCTURE * categories.DEFENSE * categories.ANTIAIR
local DefenseCategory = categories.STRUCTURE * categories.DEFENSE
local BuilderCategory = categories.ENGINEER * categories.MOBILE + categories.COMMAND
local LandCombatCategory = categories.MOBILE * categories.LAND - categories.ENGINEER - categories.SCOUT - categories.COMMAND
local ComputeAirThreatFlags
local HasEnemyCombatNear

local function Distance2D(a, b)
    local dx = (a[1] or 0) - (b[1] or 0)
    local dz = (a[3] or 0) - (b[3] or 0)
    return math.sqrt((dx * dx) + (dz * dz))
end

local function Clamp(v, minV, maxV)
    if v < minV then
        return minV
    end
    if v > maxV then
        return maxV
    end
    return v
end

local function GetMainPos(aiBrain, runtime)
    if aiBrain.BuilderManagers and aiBrain.BuilderManagers.MAIN and aiBrain.BuilderManagers.MAIN.Position then
        return aiBrain.BuilderManagers.MAIN.Position
    end
    if runtime and runtime.ZoneModel and runtime.ZoneModel.OwnMainPos then
        return runtime.ZoneModel.OwnMainPos
    end
    local sx, sz = aiBrain:GetArmyStartPos()
    return { sx, 0, sz }
end

local function GetFraction(unit)
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

local function GetEntityId(unit)
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

local function IsIdle(unit)
    local q = unit and unit.GetCommandQueue and unit:GetCommandQueue() or false
    return (not q) or table.getn(q) == 0
end

local function GetCommandQueueLength(unit)
    local q = unit and unit.GetCommandQueue and unit:GetCommandQueue() or false
    return q and table.getn(q) or 0
end

local function IsConstructing(unit)
    if not unit or unit.Dead then
        return false
    end
    return unit:IsUnitState('Building') or unit:IsUnitState('Upgrading')
end

local function CountEngineerActivity(engineers)
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
            if IsIdle(eng) then
                activity.IdleCount = activity.IdleCount + 1
            end
            if IsConstructing(eng) then
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

local function ShouldThrottle(runtime, entityId, now, interval)
    runtime.EngineerRecallCooldown = runtime.EngineerRecallCooldown or {}
    local last = runtime.EngineerRecallCooldown[entityId] or -1000
    if now - last < interval then
        return true
    end
    runtime.EngineerRecallCooldown[entityId] = now
    return false
end

local function RecallEngineer(runtime, eng, mainPos, now, reason)
    if not eng or eng.Dead or not mainPos then
        return false
    end
    local entityId = eng.EntityId or 0
    if entityId > 0 and ShouldThrottle(runtime, entityId, now, 12) then
        return false
    end

    if IssueClearCommands then
        IssueClearCommands({ eng })
    end
    if IssueMove then
        IssueMove({ eng }, mainPos)
    end

    runtime.LastEngineerRecallReason = reason
    runtime.LastEngineerRecallTime = now
    return true
end

local function MarkExpansionCommit(runtime, engineerId, now, duration)
    if not runtime or not engineerId then
        return
    end
    runtime.EngineerExpansionCommit = runtime.EngineerExpansionCommit or {}
    runtime.EngineerExpansionCommit[engineerId] = now + math.max(18, duration or 50)
end

local function IsExpansionCommitActive(runtime, engineerId, now)
    if not runtime or not engineerId then
        return false
    end
    local commits = runtime.EngineerExpansionCommit
    if not commits then
        return false
    end
    local expiresAt = commits[engineerId]
    if not expiresAt then
        return false
    end
    if now > expiresAt then
        commits[engineerId] = nil
        return false
    end
    return true
end

local function CleanupExpansionCommits(runtime, now)
    local commits = runtime and runtime.EngineerExpansionCommit or false
    if not commits then
        return
    end
    for engineerId, expiresAt in commits do
        if (not expiresAt) or now > expiresAt then
            commits[engineerId] = nil
        end
    end
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
    if not (planner.ReclaimFirst == true or planner.OuterRetentionActive == true or quotaForced) then
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
    local minReclaimMass = planner.ReclaimFirst and (quotaForced and 0.5 or 1.5) or (quotaForced and 1 or 2.5)
    local minFieldMass = planner.ReclaimFirst and (quotaForced and 28 or 42) or (quotaForced and 36 or 58)
    local reclaimTargets, reclaimMass = GetReclaimFieldTargets(targetPos, planner.ReclaimFirst and 46 or 40, minReclaimMass)
    local supportWeightedThreat = math.max(0, localThreat - (supported * 0.18))
    local threatCap = planner.ReclaimFirst and (outerBacked and 2.75 or 2.35) or (outerBacked and 2.15 or 1.85)
    local routeRiskCap = planner.ReclaimFirst and (outerBacked and 5.2 or 4.5) or (outerBacked and 4.4 or 3.8)
    local minSupport = planner.ReclaimFirst and (outerBacked and 1 or 2) or (outerBacked and 2 or 3)
    local quietField = enemySupport <= 0
        and supportWeightedThreat <= 0.25
        and routeRisk <= (quotaForced and 2.8 or 2.2)
    if quotaForced then
        minFieldMass = math.min(minFieldMass, planner.ReclaimFirst and 28 or 36)
        threatCap = math.max(threatCap, outerBacked and 2.55 or 2.15)
        routeRiskCap = math.max(routeRiskCap, outerBacked and 5.4 or 4.8)
        quietField = quietField
            or (enemySupport <= 0 and supportWeightedThreat <= 0.55 and routeRisk <= 3.8)
        minSupport = quietField and 0 or math.min(minSupport, 1)
    end

    if table.getn(reclaimTargets) <= 0 or reclaimMass < minFieldMass then
        return false
    end
    local maxFieldDistance = ((runtime.EcoPolicy or {}).SafeExpandDistance or 680) + (quotaForced and 220 or 100)
    if distMain > maxFieldDistance then
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
    if supported < minSupport and distMain > (outerBacked and 180 or 120) and not quietField then
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
                if issued >= 24 then
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

local function PickMexBlueprint(builder)
    if not builder or builder.Dead then
        return false
    end

    local bps = EntityCategoryGetUnitList(T1MexCategory)
    if not bps or table.getn(bps) <= 0 then
        return false
    end

    for _, bp in bps do
        if bp and builder:CanBuild(bp) then
            return bp
        end
    end

    return false
end

local function IsSafeExpansionTarget(aiBrain, runtime, pos, mainPos, enemyPos, maxDistance, threatCap)
    if not pos or not mainPos then
        return false
    end

    local distMain = Distance2D(pos, mainPos)
    if distMain > maxDistance then
        return false
    end
    if distMain < 48 then
        return false
    end

    local allyMex = aiBrain:GetNumUnitsAroundPoint(categories.STRUCTURE * categories.MASSEXTRACTION, pos, 7, 'Ally') or 0
    if allyMex > 0 then
        return false
    end

    local localThreat = aiBrain:GetThreatAtPosition(pos, 1, true, 'AntiSurface') or 0
    if localThreat > threatCap then
        return false
    end
    local expansionRisk = OvermindMemory.GetExpansionRisk(aiBrain, pos, 56)
    if expansionRisk > 3.2 then
        return false
    end

    local enemyRaiders = aiBrain:GetNumUnitsAroundPoint(
        categories.MOBILE * categories.LAND - categories.ENGINEER - categories.SCOUT - categories.COMMAND,
        pos,
        28,
        'Enemy') or 0
    if enemyRaiders >= 1 then
        return false
    end

    if enemyPos then
        local distEnemy = Distance2D(pos, enemyPos)
        if distEnemy + 58 < distMain then
            return false
        end
    end

    local raid = runtime and runtime.RaidDefense or {}
    if raid and raid.LastThreatMexPos and Distance2D(pos, raid.LastThreatMexPos) < 40 then
        return false
    end
    if raid and raid.ExposedMexUnderAirRaid and raid.ExposedMexThreatPos and Distance2D(pos, raid.ExposedMexThreatPos) < 72 then
        return false
    end
    local routeRisk = OvermindMemory.GetRouteRisk(aiBrain, mainPos, pos, 5, 54)
    if routeRisk > 3.4 then
        return false
    end

    if HasEnemyCombatNear(aiBrain, pos, 30) then
        return false
    end

    return true
end

local function ExpansionReservationKey(pos)
    if not pos then
        return false
    end
    return string.format('%d:%d', math.floor((pos[1] or 0) + 0.5), math.floor((pos[3] or 0) + 0.5))
end

local function FindNearestZoneNode(runtime, pos, maxDistance)
    if not runtime or not pos then
        return false
    end
    local nodes = ((runtime.ZoneGraph or {}).Nodes) or {}
    local best = false
    local bestDistSq = (maxDistance or 56) * (maxDistance or 56)
    for _, node in nodes do
        if node and node.Pos and node.Medium == 'land' then
            local dx = (node.Pos[1] or 0) - (pos[1] or 0)
            local dz = (node.Pos[3] or 0) - (pos[3] or 0)
            local distSq = (dx * dx) + (dz * dz)
            if distSq <= bestDistSq then
                best = node
                bestDistSq = distSq
            end
        end
    end
    return best
end

local function GetContestExpansionBias(runtime, pos, mainPos, enemyPos)
    if not runtime or not pos or not mainPos then
        return 0
    end

    local policy = runtime.EcoPolicy or {}
    if not (policy.ForwardContestBias == true or policy.PrioritizeProduction == true or policy.ContestMapMode == true) then
        return 0
    end

    local bias = 0
    local distMain = Distance2D(pos, mainPos)
    local outerHoldShare = policy.OuterHoldShare or 0
    if distMain >= 120 then
        bias = bias + 14
    end
    if distMain >= 165 and outerHoldShare < 0.55 then
        bias = bias + 18
    end

    local graph = runtime.ZoneGraph or {}
    local bestExpansionPos = graph.BestExpansionPos or ((runtime.ZoneModel or {}).BestExpansionPos)
    if bestExpansionPos then
        local distExpansion = Distance2D(pos, bestExpansionPos)
        if distExpansion <= 36 then
            bias = bias + 30
        elseif distExpansion <= 80 then
            bias = bias + 14
        end
    end

    local bestRaidPos = graph.BestRaidPos or ((runtime.ZoneModel or {}).BestRaidPos)
    if bestRaidPos then
        local distRaid = Distance2D(pos, bestRaidPos)
        if distRaid <= 42 then
            bias = bias + 16
        elseif distRaid <= 90 then
            bias = bias + 8
        end
    end

    local node = FindNearestZoneNode(runtime, pos, 60)
    if node then
        if node.Classification == 'contested' then
            bias = bias + 24
        elseif node.Classification == 'front' then
            bias = bias + 18
        elseif node.Classification == 'rear' or node.Classification == 'core' then
            bias = bias - 6
        elseif node.Classification == 'enemy_side' then
            bias = bias - 24
        end
        bias = bias + Clamp((node.ExpansionValue or 0) * 0.18, -8, 34)
        bias = bias + Clamp((node.RaidValue or 0) * 0.08, -6, 18)
        if (node.EnemyMex or 0) > 0 then
            bias = bias + 10
        end
        if (node.RouteRisk or 0) >= 4 then
            bias = bias - 10
        end
        if (node.FriendlyLand or 0) >= (node.EnemyLand or 0) then
            bias = bias + 6
        end
    end

    if enemyPos then
        local distEnemy = Distance2D(pos, enemyPos)
        if distEnemy > distMain then
            bias = bias + math.min(12, (distEnemy - distMain) * 0.08)
        end
    end

    return bias
end

local function CleanupExpansionReservations(runtime, now)
    local engState = runtime and runtime.EngineerState or false
    local reservations = engState and engState.ExpansionReservations or false
    if not reservations then
        return
    end
    if now < ((engState.LastExpansionReservationCleanup or -999) + 2) then
        return
    end
    engState.LastExpansionReservationCleanup = now
    for key, data in pairs(reservations) do
        if (data and data.ExpiresAt or -1) <= now then
            reservations[key] = nil
        end
    end
end

local function ReserveExpansionTarget(runtime, now, pos, engineerId)
    local engState = runtime and runtime.EngineerState or false
    if not engState or not pos then
        return
    end
    engState.ExpansionReservations = engState.ExpansionReservations or {}
    engState.ExpansionReservations[ExpansionReservationKey(pos)] = {
        ExpiresAt = now + 28,
        EngineerId = engineerId,
    }
end

local function IsReservedExpansionTarget(runtime, now, pos, engineerId)
    local engState = runtime and runtime.EngineerState or false
    local reservations = engState and engState.ExpansionReservations or false
    if not reservations then
        return false
    end
    local key = ExpansionReservationKey(pos)
    local data = key and reservations[key] or false
    if not data then
        return false
    end
    if (data.ExpiresAt or -1) <= now then
        reservations[key] = nil
        return false
    end
    return (data.EngineerId or -1) ~= (engineerId or -2)
end

local function HasFriendlyMexAtPos(aiBrain, pos, radius)
    if not aiBrain or not pos then
        return false
    end
    return (aiBrain:GetNumUnitsAroundPoint(categories.STRUCTURE * categories.MASSEXTRACTION, pos, radius or 8, 'Ally') or 0) > 0
end

local function NeedsBootstrapPower(aiBrain, runtime)
    local director = runtime and runtime.ProductionDirector or {}
    local constraints = director and director.ConstraintState or {}
    if constraints.EconBootstrap ~= true and constraints.StarterPhase ~= true then
        return false
    end
    local required = constraints.StarterPowerFloor or constraints.BootstrapPowerFloor or 1
    local units = aiBrain:GetListOfUnits(categories.ENERGYPRODUCTION * categories.STRUCTURE, false, true) or {}
    local ready = 0
    for _, unit in units do
        if unit and not unit.Dead and GetFraction(unit) >= 0.95 and not unit:IsUnitState('BeingBuilt') then
            ready = ready + 1
        end
    end
    return ready < required
end

local function NeedsCriticalRadar(runtime)
    local prod = runtime and runtime.ProductionDirector or {}
    local constraints = prod.ConstraintState or {}
    local structurePlan = prod.StructurePlan or {}
    local current = prod.Current or {}
    local currentStructures = current.Structures or {}
    local eco = runtime and runtime.EcoState or {}
    local powerReady = (((current.Eco or {}).Power or {}).Ready) or 0
    return (structurePlan.RadarCritical == true
            or ((structurePlan.Radar or 0) > (currentStructures.Radar or 0))
            or (constraints.StarterRadarRequired == true and (currentStructures.Radar or 0) <= 0))
        and (currentStructures.Radar or 0) <= 0
        and powerReady > 0
        and (eco.EnergyStorageRatio or 0) > 0.02
        and (eco.EnergyTrend or 0) > -12
end

local function GetRadarReservedBuilderIds(runtime, now)
    local reserved = {}
    local radar = runtime and runtime.RadarFallback or false
    if radar and radar.DirectBuilderId and ((radar.DirectExpiresAt or -999) > now) then
        reserved[radar.DirectBuilderId] = true
    end
    return reserved
end

local function GetExpansionTargetJitter(runtime, pos)
    local randomization = runtime and runtime.Randomization or false
    if not randomization or not pos then
        return 0
    end

    local seed = randomization.Seed or 0
    local x = math.floor((pos[1] or 0) * 10)
    local z = math.floor((pos[3] or 0) * 10)
    local hash = math.mod((seed + (x * 73856093) + (z * 19349663)), 2147483647)
    return ((math.mod(hash, 17)) - 8) * 0.55
end

local function FindExpansionTarget(aiBrain, runtime, mainPos, enemyPos, maxDistance, threatCap, now, engineerPos)
    now = now or 0
    local sourcePos = engineerPos or mainPos
    local engineerId = engineerPos and engineerPos.EngineerId or false
    local raid = runtime and runtime.RaidDefense or {}
    local engState = runtime and runtime.EngineerState or {}
    local mexPeakReady = (engState and engState.PeakMexReady) or 0
    local mexReady = (((((runtime or {}).ProductionDirector or {}).Current or {}).Eco or {}).Mex or {}).Ready or 0
    local mexRebuildUrgent = mexPeakReady > mexReady
    local zonePreferredPos = false
    if runtime and runtime.ZoneGraph and runtime.ZoneGraph.BestExpansionNodeKey then
        local node = runtime.ZoneGraph.ByKey and runtime.ZoneGraph.ByKey[runtime.ZoneGraph.BestExpansionNodeKey]
        if node and node.Pos
            and node.Medium == 'land'
            and node.Classification ~= 'enemy_side'
            and (node.GraphDistHome or 999999) <= (maxDistance + 120)
            and (node.Threat or 0) <= (threatCap + 0.45)
            and (node.RouteRisk or 0) <= 8
            and not HasFriendlyMexAtPos(aiBrain, node.Pos, 8)
            and not IsReservedExpansionTarget(runtime, now, node.Pos, engineerId) then
            if mexRebuildUrgent then
                return node.Pos
            end
            zonePreferredPos = node.Pos
        end
    end

    local markers = AIUtils.AIGetMarkerLocations(aiBrain, 'Mass')
    if not markers or table.getn(markers) <= 0 then
        return false
    end

    local bestPos = false
    local bestScore = -99999
    for _, marker in markers do
        local pos = marker and marker.Position
        if pos
            and not HasFriendlyMexAtPos(aiBrain, pos, 8)
            and not IsReservedExpansionTarget(runtime, now, pos, engineerId)
            and IsSafeExpansionTarget(aiBrain, runtime, pos, mainPos, enemyPos, maxDistance, threatCap) then
            local distMain = Distance2D(pos, mainPos)
            local distSource = Distance2D(pos, sourcePos)
            local threat = aiBrain:GetThreatAtPosition(pos, 1, true, 'AntiSurface') or 0
            local score
            if now < 360 then
                score = 420 - (distMain * 1.05) - (distSource * 0.55)
            else
                score = 320 - math.abs(170 - distMain) - (distSource * 0.18)
            end
            score = score - (threat * 28)
            score = score + GetContestExpansionBias(runtime, pos, mainPos, enemyPos)
            score = score + GetExpansionTargetJitter(runtime, pos)
            if zonePreferredPos and Distance2D(pos, zonePreferredPos) <= 8 then
                score = score + 26
            end
            if raid and raid.LastThreatMexPos then
                local distThreatMex = Distance2D(pos, raid.LastThreatMexPos)
                if distThreatMex <= 38 then
                    score = score + 95
                elseif distThreatMex <= 72 then
                    score = score + 56
                elseif distThreatMex <= 120 then
                    score = score + 22
                end
            end
            if mexRebuildUrgent then
                score = score + math.max(0, 40 - (distMain * 0.12))
                score = score - (distSource * 0.35)
            end
            if enemyPos then
                local distEnemy = Distance2D(pos, enemyPos)
                score = score + math.min(45, distEnemy * 0.12)
            end
            if score > bestScore then
                bestScore = score
                bestPos = pos
            end
        end
    end

    return bestPos
end

local function FindFollowupExpansionTarget(aiBrain, runtime, mainPos, enemyPos, anchorPos, maxDistance, threatCap, now, engineerId)
    if not anchorPos then
        return false
    end

    local markers = AIUtils.AIGetMarkerLocations(aiBrain, 'Mass')
    if not markers or table.getn(markers) <= 0 then
        return false
    end

    local bestPos = false
    local bestScore = -99999
    local anchorDistMain = Distance2D(anchorPos, mainPos)
    for _, marker in markers do
        local pos = marker and marker.Position
        if pos
            and not HasFriendlyMexAtPos(aiBrain, pos, 8)
            and not IsReservedExpansionTarget(runtime, now, pos, engineerId)
            and IsSafeExpansionTarget(aiBrain, runtime, pos, mainPos, enemyPos, maxDistance, threatCap) then
            local distAnchor = Distance2D(pos, anchorPos)
            if distAnchor >= 28 and distAnchor <= 130 then
                local distMain = Distance2D(pos, mainPos)
                local threat = aiBrain:GetThreatAtPosition(pos, 1, true, 'AntiSurface') or 0
                local score = 280 - (distAnchor * 1.45) - (distMain * 0.25) - (threat * 30)
                if distMain + 12 >= anchorDistMain then
                    score = score + 34
                end
                if enemyPos then
                    local distEnemy = Distance2D(pos, enemyPos)
                    score = score + math.min(30, distEnemy * 0.08)
                end
                score = score + (GetExpansionTargetJitter(runtime, pos) * 0.7)
                if score > bestScore then
                    bestScore = score
                    bestPos = pos
                end
            end
        end
    end

    return bestPos
end

local GetCurrentMexCounts
local HasSecondLandFactoryDebt

local function DispatchExpansionEngineer(aiBrain, runtime, now, engineers, mainPos, enemyPos, safeExpandDistance, threatCap)
    local director = runtime and runtime.ProductionDirector or {}
    local constraints = director and director.ConstraintState or {}
    local policy = runtime and runtime.EcoPolicy or {}
    local macro = runtime and runtime.MacroController or {}
    local raid = runtime and runtime.RaidDefense or {}
    local engState = runtime and runtime.EngineerState or {}
    local mexEmergency = engState and engState.MexEmergencyActive == true
    local _, mexReadyActual = GetCurrentMexCounts(aiBrain)
    local bootstrap = constraints and constraints.EconBootstrap == true
    local starterPhase = constraints and constraints.StarterPhase == true
    local contestDispatch = policy.ForwardContestBias == true
        or policy.ReclaimPressureMode == true
        or macro.HQPressureEscape == true
    if HasSecondLandFactoryDebt(aiBrain, now) and mexReadyActual >= 4 and not mexEmergency then
        return 0
    end
    if (bootstrap or starterPhase) and NeedsBootstrapPower(aiBrain, runtime) then
        return 0
    end
    if starterPhase and NeedsCriticalRadar(runtime) then
        return 0
    end
    if raid.ExposedMexUnderAirRaid == true then
        return 0
    end
    if ((raid.BomberPanicUntil or -999) > now) and table.getn(engineers or {}) <= math.max(4, ((constraints and constraints.StarterEngineerFloor) or 6) - 1) then
        return 0
    end
    if now < (runtime.LastExpansionDispatchTime or -999) + (bootstrap and 1.2 or (mexEmergency and 1.4 or 2.2)) then
        return 0
    end

    CleanupExpansionReservations(runtime, now)
    local dispatched = 0
    local dispatchLimit = bootstrap and 2 or (contestDispatch and 2 or 1)
    if mexEmergency then
        dispatchLimit = math.max(dispatchLimit, 3)
    end
    local dispatchRadius = mexEmergency and 340 or 220
    for _, eng in engineers do
        if eng and not eng.Dead and not IsConstructing(eng) and IsIdle(eng) then
            local pos = eng:GetPosition()
            if pos and Distance2D(pos, mainPos) <= dispatchRadius then
                local sourcePos = { pos[1], pos[2] or 0, pos[3], EngineerId = GetEntityId(eng) }
                local target = FindExpansionTarget(aiBrain, runtime, mainPos, enemyPos, safeExpandDistance, threatCap, now, sourcePos)
                if not target then
                    local relaxedCap = math.max(threatCap + 0.35, 1.55)
                    target = FindExpansionTarget(aiBrain, runtime, mainPos, enemyPos, safeExpandDistance, relaxedCap, now, sourcePos)
                end
                if not target then
                    break
                end
                local bp = PickMexBlueprint(eng)
                    if bp and IssueBuildMobile then
                        local engineerId = GetEntityId(eng)
                        ReserveExpansionTarget(runtime, now, target, engineerId)
                        IssueBuildMobile({ eng }, target, bp, {})
                        local landReady = ((((runtime.ProductionDirector or {}).Current or {}).Factories or {}).Land or {}).Ready or 0
                        local followupBudget = (mexEmergency and 2) or 1
                        if now < 420 or landReady <= 1 or mexEmergency then
                            local anchorPos = target
                            for _ = 1, followupBudget do
                                local followup = FindFollowupExpansionTarget(
                                    aiBrain,
                                    runtime,
                                    mainPos,
                                    enemyPos,
                                    anchorPos,
                                    safeExpandDistance,
                                    threatCap,
                                    now,
                                    engineerId)
                                if not followup then
                                    break
                                end
                                ReserveExpansionTarget(runtime, now, followup, engineerId)
                                IssueBuildMobile({ eng }, followup, bp, {})
                                anchorPos = followup
                            end
                        end
                        MarkExpansionCommit(runtime, engineerId, now, bootstrap and 68 or (mexEmergency and 96 or 78))
                        runtime.LastExpansionDispatchTime = now
                        runtime.LastExpansionTargetPos = target
                        dispatched = dispatched + 1
                    if dispatched >= dispatchLimit then
                        break
                    end
                end
            end
        end
    end

    return dispatched
end

local function GetFactoryDomain(factory)
    if EntityCategoryContains(categories.FACTORY * categories.LAND, factory) then
        return 'Land'
    elseif EntityCategoryContains(categories.FACTORY * categories.AIR, factory) then
        return 'Air'
    elseif EntityCategoryContains(categories.FACTORY * categories.NAVAL, factory) then
        return 'Navy'
    end
    return 'Other'
end

local function GetStructureKind(structure)
    if EntityCategoryContains(MexCategory, structure) then
        return 'Mex'
    elseif EntityCategoryContains(EnergyCategory, structure) then
        return 'Power'
    elseif EntityCategoryContains(RadarCategory, structure) then
        return 'Radar'
    elseif EntityCategoryContains(AADefenseCategory, structure) then
        return 'AA'
    elseif EntityCategoryContains(DefenseCategory, structure) then
        return 'Defense'
    end
    return 'Structure'
end

local function CountReadyFactories(aiBrain, category)
    local units = aiBrain:GetListOfUnits(category, false, true) or {}
    local ready = 0
    for _, unit in units do
        if unit and not unit.Dead and GetFraction(unit) >= 0.95 and not unit:IsUnitState('BeingBuilt') and not unit:IsUnitState('Upgrading') then
            ready = ready + 1
        end
    end
    return ready
end

local function CountExistingAndReady(aiBrain, category)
    local units = aiBrain:GetListOfUnits(category, false, true) or {}
    local total = 0
    local ready = 0
    for _, unit in units do
        if unit and not unit.Dead then
            total = total + 1
            if GetFraction(unit) >= 0.95 and not unit:IsUnitState('BeingBuilt') and not unit:IsUnitState('Upgrading') then
                ready = ready + 1
            end
        end
    end
    return total, ready
end

local function GetCurrentPowerCounts(aiBrain, runtime)
    return CountExistingAndReady(aiBrain, EnergyCategory)
end

GetCurrentMexCounts = function(aiBrain)
    return CountExistingAndReady(aiBrain, MexCategory)
end

local function GetCurrentLandFactoryCounts(aiBrain)
    return CountExistingAndReady(aiBrain, categories.FACTORY * categories.LAND * categories.STRUCTURE)
end

HasSecondLandFactoryDebt = function(aiBrain, now)
    local landTotal, landReady = GetCurrentLandFactoryCounts(aiBrain)
    return now < 480
        and landReady >= 1
        and landTotal < 2
end

local function ShouldDeferEcoForSecondFactory(aiBrain, runtime, now, kind)
    if not HasSecondLandFactoryDebt(aiBrain, now) then
        return false
    end
    local eco = (runtime and runtime.EcoState) or {}
    local _, mexReady = GetCurrentMexCounts(aiBrain)
    local _, powerReady = GetCurrentPowerCounts(aiBrain, runtime)
    local severeEnergyCrisis = (eco.EnergyTrend or 0) <= -45
        or ((eco.EnergyStorageRatio or 0) <= 0.015 and (eco.EnergyTrend or 0) <= -20)
    if severeEnergyCrisis then
        return false
    end
    if kind == 'Power' then
        return powerReady >= 2
    end
    if kind == 'Mex' then
        return mexReady >= 4 and powerReady >= 2
    end
    return false
end

local function ShouldWorkPowerStructure(aiBrain, runtime, now, fraction)
    local director = (runtime and runtime.ProductionDirector) or {}
    local constraints = director.ConstraintState or {}
    local current = director.Current or {}
    local eco = (runtime and runtime.EcoState) or {}
    local mexReady = ((((current.Eco or {}).Mex or {}).Ready) or 0)
    local factoryReady = (((current.Factories or {}).Ready) or 0)
    local powerTotal, powerReady = GetCurrentPowerCounts(aiBrain, runtime)
    local pendingPower = math.max(0, powerTotal - powerReady)
    local severeEnergyCrisis = (eco.EnergyTrend or 0) <= -45
        or ((eco.EnergyStorageRatio or 0) <= 0.015 and (eco.EnergyTrend or 0) <= -20)

    if NeedsBootstrapPower(aiBrain, runtime) or severeEnergyCrisis then
        return true
    end

    if ShouldDeferEcoForSecondFactory(aiBrain, runtime, now, 'Power') then
        return false
    end

    local cap = 4
    if now < 180 then
        cap = math.max(2, math.min(3, mexReady + 1))
    elseif now < 360 then
        cap = math.max(3, math.min(4, mexReady))
    elseif now < 600 then
        cap = math.max(4, math.min(6, mexReady + 1))
    else
        cap = math.max(5, math.min(8, mexReady + 2))
    end
    if factoryReady >= 4 then
        cap = cap + 1
    end

    if powerTotal >= cap and (eco.EnergyStorageRatio or 0) >= 0.03 and (eco.EnergyTrend or 0) >= -20 then
        return false
    end

    if pendingPower >= 1 and (fraction or 0) < 0.78 and (eco.EnergyStorageRatio or 0) >= 0.04 and (eco.EnergyTrend or 0) >= -22 then
        return false
    end

    if constraints.PowerBufferLow == true then
        return (eco.EnergyStorageRatio or 0) < 0.12 or (eco.EnergyTrend or 0) < -14 or powerReady < math.max(2, math.min(4, mexReady))
    end

    return (eco.EnergyStorageRatio or 0) < 0.28 or (eco.EnergyTrend or 0) < 2
end

local function ScoreStructureTarget(aiBrain, runtime, structure, kind, pos, fraction, mainPos)
    local eco = runtime.EcoState or {}
    local recovery = runtime.Recovery or {}
    local raid = runtime.RaidDefense or {}
    local constraints = ((runtime.ProductionDirector or {}).ConstraintState or {})
    local engState = runtime.EngineerState or {}
    local distMain = Distance2D(pos, mainPos)
    local localThreat = aiBrain:GetThreatAtPosition(pos, 1, true, 'AntiSurface') or 0
    if kind == 'Power' and not ShouldWorkPowerStructure(aiBrain, runtime, GetGameTimeSeconds(), fraction) then
        return -999999, localThreat
    end
    if kind == 'Mex' and ShouldDeferEcoForSecondFactory(aiBrain, runtime, GetGameTimeSeconds(), 'Mex') then
        return -999999, localThreat
    end

    local engineerLossRisk = OvermindMemory.GetEngineerLossRisk(aiBrain, pos, 42)
    local expansionRisk = OvermindMemory.GetExpansionRisk(aiBrain, pos, 56)
    local bootstrapPowerNeed = NeedsBootstrapPower(aiBrain, runtime)
    local radarCritical = NeedsCriticalRadar(runtime)
    local starterPhase = ((runtime.ProductionDirector or {}).ConstraintState or {}).StarterPhase == true
    local mexEmergency = engState.MexEmergencyActive == true
    local mexRebuild = engState.MexEmergencyRebuild == true
    local bomberWatch, bomberPanic, exposedMexAirRaid = ComputeAirThreatFlags(runtime, GetGameTimeSeconds())
    local forceFinishPower = kind == 'Power'
        and fraction >= 0.8
        and (
            (eco.MassStorageRatio or 0) >= 0.12
            or (eco.MassTrend or 0) >= 0.02
            or (eco.EnergyStorageRatio or 0) <= 0.35
            or constraints.PowerBufferLow == true
        )

    local kindBias = 24
    if kind == 'Mex' then
        kindBias = 94
    elseif kind == 'Power' then
        kindBias = 78
    elseif kind == 'Radar' then
        kindBias = 60
    elseif kind == 'AA' then
        kindBias = 54
    elseif kind == 'Defense' then
        kindBias = 42
    end

    local score = kindBias + (fraction * 120) - (distMain * 0.16) - (localThreat * 18) - (engineerLossRisk * 18) - (expansionRisk * 10)
    if kind == 'Mex' and mexEmergency then
        score = score + (mexRebuild and 95 or 62)
        if raid and raid.LastThreatMexPos then
            local distThreatMex = Distance2D(pos, raid.LastThreatMexPos)
            if distThreatMex <= 34 then
                score = score + 85
            elseif distThreatMex <= 70 then
                score = score + 48
            end
        end
    end
    if bootstrapPowerNeed then
        if kind == 'Power' then
            score = score + 120
        elseif kind == 'Mex' then
            score = score - 80
        elseif kind == 'Radar' or kind == 'AA' or kind == 'Defense' then
            score = score - 120
        end
    elseif radarCritical then
        if kind == 'Radar' then
            score = score + 220
        elseif kind == 'AA' or kind == 'Defense' then
            score = score - 90
        elseif kind == 'Mex' then
            score = score - 120
        end
    end
    if starterPhase and not bootstrapPowerNeed then
        if kind == 'Radar' and radarCritical then
            score = score + 140
        elseif kind == 'Mex' and radarCritical then
            score = score - 160
        end
    end
    if bomberWatch and not bomberPanic and not exposedMexAirRaid then
        if kind == 'Radar' then
            score = score + (radarCritical and 180 or 85)
        elseif kind == 'AA' then
            score = score + (radarCritical and 18 or 80)
        elseif kind == 'Power' then
            score = score + 24
        elseif kind == 'Mex' then
            score = score - (radarCritical and (mexEmergency and 60 or 170) or (mexEmergency and 18 or 55))
        elseif kind == 'Defense' then
            score = score - 25
        end
    end
    if distMain <= 135 then
        score = score + 12
    end
    if kind == 'Mex' and (eco.MassStorageRatio or 0) <= 0.12 then
        score = score + 18
    end
    if kind == 'Power' and (eco.EnergyStorageRatio or 0) <= 0.18 then
        score = score + 20
    end
    if forceFinishPower then
        score = score + 220 + (fraction * 40)
    end
    if kind == 'Radar' and ((runtime.IntelModel and runtime.IntelModel.StaleZones) or 0) >= 3 then
        score = score + 12
    end
    if (kind == 'AA' or kind == 'Defense') and recovery.ForceDefenseRecovery then
        score = score + 14
    end
    if bomberPanic or exposedMexAirRaid then
        if kind == 'AA' then
            score = score + 130
        elseif kind == 'Radar' then
            score = score + 55
        elseif kind == 'Power' then
            score = score + 18
        elseif kind == 'Mex' then
            score = score - (mexEmergency and 26 or 85)
        elseif kind == 'Defense' then
            score = score - 30
        end
    end
    if exposedMexAirRaid and raid.ExposedMexThreatPos and Distance2D(pos, raid.ExposedMexThreatPos) < 44 then
        if kind == 'AA' then
            score = score + 180
        elseif kind == 'Radar' then
            score = score + 70
        elseif kind == 'Mex' then
            score = score - (mexRebuild and 40 or 150)
        elseif kind == 'Defense' then
            score = score - 40
        end
    end

    return score, localThreat
end

local function FindBestUnfinishedStructure(aiBrain, runtime, mainPos)
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
    local mexEmergency = ((runtime.EngineerState or {}).MexEmergencyActive) == true
    local mexRebuild = ((runtime.EngineerState or {}).MexEmergencyRebuild) == true

    for _, structure in structures do
        if structure and not structure.Dead and not structure:IsUnitState('Upgrading') then
            local fraction = GetFraction(structure)
            if fraction < 0.995 then
                local pos = structure.GetPosition and structure:GetPosition() or false
                if pos then
                    local distMain = Distance2D(pos, mainPos)
                    local kind = GetStructureKind(structure)
                    local maxDist = (kind == 'Mex')
                        and math.max(320, safeExpandDistance * (mexEmergency and 1.2 or 0.95))
                        or 240
                    if distMain <= maxDist then
                        local score, threat = ScoreStructureTarget(aiBrain, runtime, structure, kind, pos, fraction, mainPos)
                        local threatCap = (kind == 'Mex') and (mexRebuild and 3.5 or 3.1) or 2.8
                        if threat <= threatCap and score > bestScore then
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

    return best, bestPos, bestFraction, bestKind, bestPriority
end

local function FindBestUnfinishedFactory(aiBrain, runtime, mainPos)
    local factories = aiBrain:GetListOfUnits(FactoryCategory, false, true) or {}
    if table.getn(factories) <= 0 then
        return false, false, 1, 'none', 0
    end

    local readyLand = CountReadyFactories(aiBrain, categories.FACTORY * categories.LAND * categories.STRUCTURE)
    local readyAir = CountReadyFactories(aiBrain, categories.FACTORY * categories.AIR * categories.STRUCTURE)
    local readySea = CountReadyFactories(aiBrain, categories.FACTORY * categories.NAVAL * categories.STRUCTURE)

    local best = false
    local bestPos = false
    local bestFraction = 1
    local bestDomain = 'none'
    local bestReady = 0
    local bestScore = -999999
    for _, factory in factories do
        if factory and not factory.Dead then
            local fraction = GetFraction(factory)
            if fraction < 0.95 and not factory:IsUnitState('Upgrading') then
                local pos = factory.GetPosition and factory:GetPosition() or false
                if pos then
                    local domain = GetFactoryDomain(factory)
                    local readyInDomain = 0
                    if domain == 'Land' then
                        readyInDomain = readyLand
                    elseif domain == 'Air' then
                        readyInDomain = readyAir
                    elseif domain == 'Navy' then
                        readyInDomain = readySea
                    end

                    local distMain = Distance2D(pos, mainPos)
                    local score = (fraction * 150) - (distMain * 0.18)
                    if domain == 'Land' then
                        score = score + 10
                    end
                    if readyInDomain <= 0 then
                        score = score + 18
                    end
                    if distMain <= 130 then
                        score = score + 10
                    end
                    if runtime and runtime.Recovery and runtime.Recovery.ForceFactoryRecovery and domain == 'Land' then
                        score = score + 12
                    end
                    if score > bestScore then
                        best = factory
                        bestPos = pos
                        bestFraction = fraction
                        bestDomain = domain
                        bestReady = readyInDomain
                        bestScore = score
                    end
                end
            end
        end
    end

    return best, bestPos, bestFraction, bestDomain, bestReady
end

local function ResetFactoryTask(task)
    task.Active = false
    task.TargetId = false
    task.TargetPos = false
    task.TargetFraction = 1
    task.Domain = 'none'
    task.StallTime = 0
    task.ReadyFactories = 0
    task.RequiredBuilders = 0
    task.AssignedBuilders = 0
    task.BuilderIds = {}
    task.LastProgressTime = false
    task.UsedCommander = false
    task.CandidateDebug = false
end

local function ResetStructureTask(task)
    task.Active = false
    task.TargetId = false
    task.TargetPos = false
    task.TargetFraction = 1
    task.Kind = 'none'
    task.Priority = 0
    task.StickyUntil = -999
    task.StallTime = 0
    task.RequiredBuilders = 0
    task.AssignedBuilders = 0
    task.BuilderIds = {}
    task.LastProgressTime = false
    task.UsedCommander = false
    task.CandidateDebug = false
end

local function ComputeFactoryTaskRequirements(domain, fraction, stallTime, readyFactories, eco)
    local required = 1
    if domain == 'Land' and readyFactories <= 0 then
        required = required + 1
    end
    if domain == 'Land' and readyFactories <= 1 and fraction >= 0.15 then
        required = required + 1
    end
    if domain == 'Land' and readyFactories <= 1 and fraction >= 0.28 then
        required = required + 1
    end
    if fraction >= 0.4 then
        required = required + 1
    end
    if domain == 'Land' and fraction >= 0.6 then
        required = required + 1
    end
    if stallTime >= 8 then
        required = required + 1
    end
    if domain == 'Land' and stallTime >= 18 then
        required = required + 1
    end
    if (eco.MassStorageRatio or 0) <= 0.02 and required > 2 and readyFactories > 0 then
        required = required - 1
    end
    if domain == 'Land' then
        return Clamp(required, 2, 4)
    end
    return Clamp(required, 1, 4)
end

local function PickPowerBlueprint(builder, targetTech)
    if not builder or builder.Dead then
        return false
    end

    local techCategory = (targetTech == 'tech2' or targetTech == 2) and categories.TECH2 or categories.TECH1
    local bps = EntityCategoryGetUnitList(categories.STRUCTURE * categories.ENERGYPRODUCTION * techCategory)
    if not bps or table.getn(bps) <= 0 then
        return false
    end

    for _, bp in bps do
        if bp and builder:CanBuild(bp) then
            return bp
        end
    end

    return false
end

local PowerBuildOffsets = {
    { 18, 0 }, { -18, 0 }, { 0, 18 }, { 0, -18 },
    { 28, 12 }, { -28, 12 }, { 12, -28 }, { -12, -28 },
    { 36, 0 }, { -36, 0 }, { 0, 36 }, { 0, -36 },
    { 48, 0 }, { -48, 0 }, { 0, 48 }, { 0, -48 },
    { 54, 24 }, { -54, 24 }, { 24, -54 }, { -24, -54 },
    { 66, 0 }, { -66, 0 }, { 0, 66 }, { 0, -66 },
}

local function GetFactoryAnchor(aiBrain, mainPos)
    local factories = aiBrain:GetListOfUnits(categories.FACTORY * categories.LAND * categories.STRUCTURE, false, true) or {}
    local best = mainPos
    local bestDist = 999999
    for _, unit in factories do
        if unit and not unit.Dead and GetFraction(unit) >= 0.95 and not unit:IsUnitState('BeingBuilt') then
            local pos = unit.GetPosition and unit:GetPosition() or false
            if pos then
                local dist = Distance2D(pos, mainPos)
                if dist < bestDist then
                    best = pos
                    bestDist = dist
                end
            end
        end
    end
    return best
end

local function PickLandFactoryBlueprint(builder)
    if not builder or builder.Dead then
        return false
    end

    local bps = EntityCategoryGetUnitList(categories.FACTORY * categories.LAND * categories.STRUCTURE * categories.TECH1)
    if not bps or table.getn(bps) <= 0 then
        return false
    end

    for _, bp in bps do
        if bp and builder:CanBuild(bp) then
            return bp
        end
    end

    return false
end

local SecondLandFactoryOffsets = {
    { 30, 18 }, { -30, 18 }, { 30, -18 }, { -30, -18 },
    { 18, 30 }, { -18, 30 }, { 18, -30 }, { -18, -30 },
    { 42, 0 }, { -42, 0 }, { 0, 42 }, { 0, -42 },
    { 48, 24 }, { -48, 24 }, { 48, -24 }, { -48, -24 },
    { 24, 48 }, { -24, 48 }, { 24, -48 }, { -24, -48 },
}

local function FindLandFactoryBuildPos(aiBrain, bp, anchorPos)
    if not aiBrain or not bp or not anchorPos then
        return false
    end

    for _, offset in SecondLandFactoryOffsets do
        local x = (anchorPos[1] or 0) + offset[1]
        local z = (anchorPos[3] or 0) + offset[2]
        local y = 0
        if GetTerrainHeight then
            y = GetTerrainHeight(x, z) or 0
        end
        local pos = { x, y, z }
        local alliedStructures = aiBrain:GetNumUnitsAroundPoint(categories.STRUCTURE, pos, 13, 'Ally') or 0
        local alliedFactories = aiBrain:GetNumUnitsAroundPoint(FactoryCategory, pos, 16, 'Ally') or 0
        local buildable = true
        if aiBrain.CanBuildStructureAt then
            buildable = aiBrain:CanBuildStructureAt(bp, pos) == true
        end
        if buildable and alliedStructures <= 0 and alliedFactories <= 0 and not HasEnemyCombatNear(aiBrain, pos, 42) then
            return pos
        end
    end

    return false
end

local function TryOpenSecondLandFactoryBuild(aiBrain, runtime, eng, mainPos, now)
    if not eng or eng.Dead or not mainPos or not IssueBuildMobile then
        return false
    end
    if now < 115 or now > 430 then
        return false
    end

    local landTotal, landReady = GetCurrentLandFactoryCounts(aiBrain)
    if landReady < 1 or landTotal >= 2 then
        return false
    end

    local _, mexReady = GetCurrentMexCounts(aiBrain)
    local _, powerReady = GetCurrentPowerCounts(aiBrain, runtime)
    if mexReady < 4 or powerReady < 2 then
        return false
    end

    local eco = runtime and runtime.EcoState or {}
    if (eco.EnergyStorageRatio or 0) <= 0.006 and (eco.EnergyTrend or 0) <= -45 then
        return false
    end
    if now < ((runtime.LastSecondLandFactoryDirectIssueTime or -999) + 16) then
        return false
    end

    local bp = PickLandFactoryBlueprint(eng)
    local anchor = bp and GetFactoryAnchor(aiBrain, mainPos) or false
    local buildPos = bp and anchor and FindLandFactoryBuildPos(aiBrain, bp, anchor) or false
    if not bp or not buildPos then
        return false
    end

    if IssueClearCommands then
        IssueClearCommands({ eng })
    end
    IssueBuildMobile({ eng }, buildPos, bp, {})
    runtime.LastSecondLandFactoryDirectIssueTime = now
    runtime.LastSecondLandFactoryDirectPos = buildPos
    runtime.SecondLandFactoryDirectCount = (runtime.SecondLandFactoryDirectCount or 0) + 1
    return true
end

local function FindPowerBuildPos(aiBrain, anchorPos, bp, spacingRadius, ignoreThreat)
    if not aiBrain or not anchorPos then
        return false
    end

    local radius = spacingRadius or 8
    for _, offset in PowerBuildOffsets do
        local x = (anchorPos[1] or 0) + offset[1]
        local z = (anchorPos[3] or 0) + offset[2]
        local y = 0
        if GetTerrainHeight then
            y = GetTerrainHeight(x, z) or 0
        end
        local pos = { x, y, z }
        local structureNearby = aiBrain:GetNumUnitsAroundPoint(categories.STRUCTURE, pos, radius, 'Ally') or 0
        local buildable = true
        if bp and aiBrain.CanBuildStructureAt then
            buildable = aiBrain:CanBuildStructureAt(bp, pos) == true
        end
        if buildable and structureNearby <= 0 and (ignoreThreat or not HasEnemyCombatNear(aiBrain, pos, 34)) then
            return pos
        end
    end

    return false
end

local function LogFirstT2PowerFailure(aiBrain, runtime, now, reason)
    if not runtime then
        return
    end
    if now < ((runtime.LastFirstT2PowerDebugLogTime or -999) + 12) then
        return
    end
    runtime.LastFirstT2PowerDebugLogTime = now
    LOG(string.format('*OVERMIND ENGDIR T2POWER A%d t=%.1f issued=0 reason=%s',
        aiBrain:GetArmyIndex(),
        now,
        reason or 'unknown'))
end

local function CountNearbyUnfinishedPower(aiBrain, mainPos, radius, category)
    local units = aiBrain:GetListOfUnits(category or EnergyCategory, false, true) or {}
    local count = 0
    for _, unit in units do
        if unit and not unit.Dead then
            local pos = unit.GetPosition and unit:GetPosition() or false
            if pos and Distance2D(pos, mainPos) <= (radius or 180) and GetFraction(unit) < 0.995 and not unit:IsUnitState('Upgrading') then
                count = count + 1
            end
        end
    end
    return count
end

local function GetPriorityPowerRecoveryTarget(aiBrain, runtime, mainPos, structureTargetObject, structureTask)
    if not aiBrain or not mainPos then
        return false
    end

    if structureTask and structureTask.Active and structureTask.Kind == 'Power' and structureTargetObject and not structureTargetObject.Dead then
        if ShouldWorkPowerStructure(aiBrain, runtime, GetGameTimeSeconds(), GetFraction(structureTargetObject)) then
            return structureTargetObject
        end
        return false
    end

    local best = false
    local bestScore = -999999
    local units = aiBrain:GetListOfUnits(EnergyCategory, false, true) or {}
    for _, unit in units do
        if unit and not unit.Dead and not unit:IsUnitState('Upgrading') then
            local pos = unit.GetPosition and unit:GetPosition() or false
            if pos then
                local dist = Distance2D(pos, mainPos)
                if dist <= 220 then
                    local fraction = GetFraction(unit)
                    local health = unit.GetHealth and unit:GetHealth() or 0
                    local maxHealth = unit.GetMaxHealth and unit:GetMaxHealth() or 0
                    local score = -999999
                    if fraction < 0.995 then
                        if ShouldWorkPowerStructure(aiBrain, runtime, GetGameTimeSeconds(), fraction) then
                            score = 320 + (fraction * 140) - dist
                        end
                    elseif maxHealth > 0 and health > 0 and health < (maxHealth * 0.92) then
                        score = 220 + ((1 - (health / maxHealth)) * 180) - dist
                    end
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

local function GetPriorityMexRecoveryTarget(aiBrain, runtime, mainPos, structureTargetObject, structureTask)
    if not aiBrain or not mainPos then
        return false
    end

    if structureTask and structureTask.Active and structureTask.Kind == 'Mex' and structureTargetObject and not structureTargetObject.Dead then
        return structureTargetObject
    end

    local best = false
    local bestScore = -999999
    local units = aiBrain:GetListOfUnits(MexCategory, false, true) or {}
    for _, unit in units do
        if unit and not unit.Dead and not unit:IsUnitState('Upgrading') then
            local pos = unit.GetPosition and unit:GetPosition() or false
            if pos then
                local dist = Distance2D(pos, mainPos)
                if dist <= 520 then
                    local fraction = GetFraction(unit)
                    if fraction < 0.995 then
                        local threat = aiBrain:GetThreatAtPosition(pos, 1, true, 'AntiSurface') or 0
                        if threat <= 2.8 and not ShouldDeferEcoForSecondFactory(aiBrain, runtime, GetGameTimeSeconds(), 'Mex') then
                            local score = 300 + (fraction * 180) - (dist * 0.18)
                            if fraction >= 0.35 then
                                score = score + 120
                            end
                            if fraction >= 0.7 then
                                score = score + 140
                            end
                            if score > bestScore then
                                bestScore = score
                                best = unit
                            end
                        end
                    end
                end
            end
        end
    end

    return best
end

local function ShouldForceFinishEcoStructure(aiBrain, runtime, mainPos, structureTargetObject, structureTask)
    local powerTarget = GetPriorityPowerRecoveryTarget(aiBrain, runtime, mainPos, structureTargetObject, structureTask)
    local mexTarget = GetPriorityMexRecoveryTarget(aiBrain, runtime, mainPos, structureTargetObject, structureTask)
    local eco = runtime and runtime.EcoState or {}
    local constraints = (((runtime or {}).ProductionDirector or {}).ConstraintState or {})
    local bootstrapPowerNeed = NeedsBootstrapPower(aiBrain, runtime)
    local bestTarget = false
    local bestKind = false
    local bestScore = -999999

    if powerTarget and not powerTarget.Dead then
        local fraction = GetFraction(powerTarget)
        local score = (bootstrapPowerNeed and 1000 or 0)
            + ((constraints.PowerBufferLow == true) and 700 or 0)
            + 500
            + (fraction * 300)
            + ((fraction >= 0.35) and 180 or 0)
        if score > bestScore then
            bestScore = score
            bestTarget = powerTarget
            bestKind = 'Power'
        end
    end

    if mexTarget and not mexTarget.Dead then
        local fraction = GetFraction(mexTarget)
        local score = 420
            + (fraction * 260)
            + ((fraction >= 0.35) and 180 or 0)
            + ((fraction >= 0.7) and 120 or 0)
            + (((eco.MassStorageRatio or 0) <= 0.18) and 120 or 0)
        if score > bestScore then
            bestScore = score
            bestTarget = mexTarget
            bestKind = 'Mex'
        end
    end

    return bestTarget ~= false, bestTarget, bestKind
end

local function TryOpenPowerRecoveryBuild(aiBrain, runtime, eng, mainPos, now)
    if not eng or eng.Dead or not mainPos or not IssueBuildMobile then
        return false
    end

    if not ShouldWorkPowerStructure(aiBrain, runtime, now, 0) then
        return false
    end

    if now < ((runtime.LastPowerRecoveryIssueTime or -999) + 8) then
        return false
    end
    if CountNearbyUnfinishedPower(aiBrain, mainPos, 260) >= 1 then
        return false
    end

    local bp = PickPowerBlueprint(eng)
    local anchor = bp and GetFactoryAnchor(aiBrain, mainPos) or false
    local buildPos = bp and anchor and FindPowerBuildPos(aiBrain, anchor, bp, 8) or false
    if not bp or not buildPos then
        return false
    end

    IssueBuildMobile({ eng }, buildPos, bp, {})
    runtime.LastPowerRecoveryIssueTime = now
    runtime.LastPowerRecoveryPos = buildPos
    return true
end

local function TryOpenFirstT2PowerBuild(aiBrain, runtime, eng, mainPos, now)
    if not eng or eng.Dead or not mainPos or not IssueBuildMobile then
        return false
    end

    local macro = runtime and runtime.MacroController or {}
    local phase = macro.Phase or (((runtime and runtime.ProductionDirector) or {}).MacroObjective) or 'none'
    if phase ~= 'first_t2_power' and macro.NeedFirstT2Power ~= true then
        return false
    end
    if (aiBrain:GetCurrentUnits(Tech2PowerCategory) or 0) > 0 then
        LogFirstT2PowerFailure(aiBrain, runtime, now, 'existing_t2_power')
        return false
    end
    if CountNearbyUnfinishedPower(aiBrain, mainPos, 320, Tech2PowerCategory) >= 1 then
        LogFirstT2PowerFailure(aiBrain, runtime, now, 'unfinished_t2_power')
        return false
    end
    if now < ((runtime.LastFirstT2PowerIssueTime or -999) + 10) then
        LogFirstT2PowerFailure(aiBrain, runtime, now, 'cooldown')
        return false
    end

    local bp = PickPowerBlueprint(eng, 'tech2')
    local anchor = bp and GetFactoryAnchor(aiBrain, mainPos) or false
    local buildPos = bp and anchor and FindPowerBuildPos(aiBrain, anchor, bp, 10, true) or false
    if not bp then
        LogFirstT2PowerFailure(aiBrain, runtime, now, 'no_blueprint')
        return false
    end
    if not anchor then
        LogFirstT2PowerFailure(aiBrain, runtime, now, 'no_anchor')
        return false
    end
    if not buildPos then
        LogFirstT2PowerFailure(aiBrain, runtime, now, 'no_build_pos')
        return false
    end

    if IssueClearCommands then
        IssueClearCommands({ eng })
    end
    IssueBuildMobile({ eng }, buildPos, bp, {})
    runtime.LastFirstT2PowerIssueTime = now
    runtime.LastFirstT2PowerPos = buildPos
    LOG(string.format('*OVERMIND ENGDIR T2POWER A%d t=%.1f issued=1 pos=%.1f,%.1f',
        aiBrain:GetArmyIndex(),
        now,
        buildPos[1] or 0,
        buildPos[3] or 0))
    return true
end

local function ShouldScaleBaseEco(runtime, now)
    local director = runtime and runtime.ProductionDirector or {}
    local constraints = director.ConstraintState or {}
    local current = director.Current or {}
    local eco = runtime and runtime.EcoState or {}
    local factories = current.Factories or {}
    local readyLand = ((factories.Land or {}).Ready) or 0
    local powerReady = (((current.Eco or {}).Power or {}).Ready) or 0
    local mexReady = (((current.Eco or {}).Mex or {}).Ready) or 0

    if now < 240 or constraints.EcoCrash or constraints.QueueStarved or constraints.CriticalFactory or constraints.CriticalStructure then
        return false
    end
    if readyLand < 3 or mexReady < 5 then
        return false
    end
    if (eco.MassStorageRatio or 0) < 0.14 or (eco.MassTrend or 0) < -0.12 then
        return false
    end
    if (eco.EnergyStorageRatio or 0) >= 0.72 and powerReady >= (mexReady + 1) then
        return false
    end
    return powerReady <= mexReady or (eco.EnergyStorageRatio or 0) < 0.52 or (eco.EnergyTrend or 0) < 10
end

local function CountUnfinishedMexes(aiBrain, mainPos, radius)
    local units = aiBrain:GetListOfUnits(MexCategory, false, true) or {}
    local count = 0
    for _, unit in units do
        if unit and not unit.Dead and not unit:IsUnitState('Upgrading') and GetFraction(unit) < 0.995 then
            local pos = unit.GetPosition and unit:GetPosition() or false
            if pos and (not mainPos or Distance2D(pos, mainPos) <= (radius or 520)) then
                count = count + 1
            end
        end
    end
    return count
end

local function ShouldPersistentSurplusSpend(runtime, now)
    local macro = runtime and runtime.MacroController or {}
    local phase = macro.Phase or (((runtime and runtime.ProductionDirector) or {}).MacroObjective) or 'land_factory_floor'
    if phase ~= 'surplus_scale' then
        return false
    end
    local director = runtime and runtime.ProductionDirector or {}
    local constraints = director.ConstraintState or {}
    local current = director.Current or {}
    local eco = runtime and runtime.EcoState or {}
    local factories = current.Factories or {}
    local readyLand = ((factories.Land or {}).Ready) or 0
    local totalLand = ((factories.Land or {}).Total) or 0
    local powerReady = (((current.Eco or {}).Power or {}).Ready) or 0
    local mexReady = (((current.Eco or {}).Mex or {}).Ready) or 0

    if now < 210 or constraints.EcoCrash or constraints.QueueStarved or constraints.CriticalStructure then
        return false
    end
    if constraints.CriticalFactory and not (readyLand >= 4 and totalLand <= readyLand and powerReady >= 4) then
        return false
    end
    if constraints.LandPanic or constraints.AirPanic then
        return false
    end
    if readyLand < 3 or mexReady < 5 then
        return false
    end
    if (eco.MassStorageRatio or 0) < 0.12 or (eco.MassTrend or 0) < -0.08 then
        return false
    end
    if (eco.EnergyStorageRatio or 0) < 0.08 or (eco.EnergyTrend or 0) < -12 then
        return false
    end
    return true
end

local function TryOpenSurplusExpansionBuild(aiBrain, runtime, eng, mainPos, enemyPos, safeExpandDistance, now)
    if not eng or eng.Dead or not mainPos or not IssueBuildMobile then
        return false
    end
    safeExpandDistance = safeExpandDistance or 680

    local macroPhase = (((runtime or {}).MacroController or {}).Phase)
        or ((((runtime or {}).ProductionDirector or {}).MacroObjective) or 'none')
    local _, mexReady = GetCurrentMexCounts(aiBrain)
    local engState = runtime and runtime.EngineerState or {}
    if runtime then
        runtime.EngineerState = engState
    end
    if HasSecondLandFactoryDebt(aiBrain, now) and mexReady >= 4 and not engState.MexEmergencyActive then
        return false
    end
    engState.PeakMexReady = math.max(engState.PeakMexReady or 0, mexReady)
    local mexLossCount = math.max(0, (engState.PeakMexReady or mexReady) - mexReady)
    local rebuildUrgent = mexLossCount >= 1
    local mexExpansionUrgent = now < 1550 and mexReady < 12

    local issueCooldown = (macroPhase == 'starter_mex_claim') and 2 or ((rebuildUrgent or mexExpansionUrgent) and 3 or 8)
    if now < ((runtime.LastSurplusExpansionIssueTime or -999) + issueCooldown) then
        return false
    end
    local maxUnfinishedMexes = 1
    if macroPhase == 'starter_mex_claim' then
        maxUnfinishedMexes = 4
    elseif rebuildUrgent or mexExpansionUrgent then
        maxUnfinishedMexes = 4
    end
    if CountUnfinishedMexes(aiBrain, mainPos, math.max(520, safeExpandDistance)) >= maxUnfinishedMexes then
        return false
    end

    local engineerId = GetEntityId(eng)
    local pos = eng.GetPosition and eng:GetPosition() or false
    local sourcePos = pos and { pos[1], pos[2] or 0, pos[3], EngineerId = engineerId } or false
    local searchPrimary = math.max(320, math.min(560, safeExpandDistance))
    local searchFallback = math.max(420, math.min(760, safeExpandDistance + 140))
    if macroPhase == 'starter_mex_claim' or mexReady < 6 then
        searchPrimary = math.max(280, math.min(420, safeExpandDistance))
        searchFallback = math.max(360, math.min(620, safeExpandDistance + 120))
    elseif rebuildUrgent or mexExpansionUrgent then
        searchPrimary = math.max(320, math.min(520, safeExpandDistance + 80))
        searchFallback = math.max(420, math.min(720, safeExpandDistance + 220))
    end
    local threatPrimary = (macroPhase == 'starter_mex_claim') and 1.9 or ((rebuildUrgent or mexExpansionUrgent) and 1.95 or 1.7)
    local threatFallback = threatPrimary + 0.25

    local target = FindExpansionTarget(aiBrain, runtime, mainPos, enemyPos, searchPrimary, threatPrimary, now, sourcePos)
    if not target then
        target = FindExpansionTarget(aiBrain, runtime, mainPos, enemyPos, searchFallback, threatFallback, now, sourcePos)
    end
    if not target then
        return false
    end

    local bp = PickMexBlueprint(eng)
    if not bp then
        return false
    end

    ReserveExpansionTarget(runtime, now, target, engineerId)
    IssueBuildMobile({ eng }, target, bp, {})

    local followupBudget = (macroPhase == 'starter_mex_claim') and 4 or (((rebuildUrgent or mexExpansionUrgent) or mexReady <= 6) and 3 or 1)
    if followupBudget > 0 then
        local anchorPos = target
        local followupDistance = math.max(searchPrimary, safeExpandDistance + 140)
        local followupThreat = threatPrimary + 0.1
        for _ = 1, followupBudget do
            local followup = FindFollowupExpansionTarget(
                aiBrain,
                runtime,
                mainPos,
                enemyPos,
                anchorPos,
                followupDistance,
                followupThreat,
                now,
                engineerId)
            if not followup then
                break
            end
            ReserveExpansionTarget(runtime, now, followup, engineerId)
            IssueBuildMobile({ eng }, followup, bp, {})
            anchorPos = followup
        end
    end

    runtime.LastSurplusExpansionIssueTime = now
    runtime.LastSurplusExpansionPos = target
    MarkExpansionCommit(runtime, engineerId, now, (macroPhase == 'starter_mex_claim') and 102 or ((rebuildUrgent or mexExpansionUrgent) and 88 or 64))
    return true
end

local function ComputeStructureTaskRequirements(kind, fraction, stallTime, eco)
    local required = 1
    if kind == 'Mex' then
        if fraction >= 0.25 then
            required = required + 1
        end
        if (eco.MassStorageRatio or 0) <= 0.08 then
            required = required + 1
        end
    elseif kind == 'Power' then
        if (eco.EnergyStorageRatio or 0) <= 0.2 then
            required = required + 1
        end
        if fraction >= 0.55 then
            required = required + 1
        end
    elseif kind == 'Radar' then
        if stallTime >= 18 then
            required = required + 1
        end
    elseif kind == 'AA' or kind == 'Defense' then
        if fraction >= 0.45 then
            required = required + 1
        end
    end
    if stallTime >= 24 then
        required = required + 1
    end
    return Clamp(required, 1, 3)
end

local function FindTrackedUnfinishedStructure(aiBrain, task)
    if not aiBrain or not task or (not task.TargetId and not task.TargetPos) then
        return false
    end

    local structures = aiBrain:GetListOfUnits(StructureCategory, false, true) or {}
    local fallback = false
    local fallbackPos = false
    local fallbackFraction = 1
    local fallbackKind = 'Structure'
    local fallbackPriority = 0

    for _, structure in structures do
        if structure and not structure.Dead and structure:IsUnitState('BeingBuilt') then
            local pos = structure:GetPosition()
            if pos then
                local fraction = GetFraction(structure)
                if fraction < 0.995 then
                    local entityId = GetEntityId(structure)
                    local kind = GetStructureKind(structure)
                    local priority = 0
                    if kind == 'Mex' then
                        priority = 5
                    elseif kind == 'Power' then
                        priority = 4
                    elseif kind == 'Radar' then
                        priority = 6
                    elseif kind == 'AA' then
                        priority = 3
                    elseif kind == 'Defense' then
                        priority = 2
                    else
                        priority = 1
                    end

                    if task.TargetId and entityId == task.TargetId then
                        return structure, pos, fraction, kind, priority
                    end

                    if task.TargetPos and not fallback and Distance2D(pos, task.TargetPos) <= 8 then
                        fallback = structure
                        fallbackPos = pos
                        fallbackFraction = fraction
                        fallbackKind = kind
                        fallbackPriority = priority
                    end
                end
            end
        end
    end

    return fallback, fallbackPos, fallbackFraction, fallbackKind, fallbackPriority
end

local function ShouldKeepTrackedStructureTask(now, task, trackedTargetId, trackedKind, trackedFraction, trackedPriority, bestTargetId, bestKind, bestPriority, radarCritical)
    if not trackedTargetId then
        return false
    end

    if not bestTargetId or trackedTargetId == bestTargetId then
        return true
    end

    local assigned = task.AssignedBuilders or 0
    local stickyUntil = task.StickyUntil or -999
    local keep = false
    local trackedLower = string.lower(trackedKind or 'none')
    local bestLower = string.lower(bestKind or 'none')

    if now < stickyUntil then
        keep = true
    end

    if assigned > 0 and trackedFraction >= 0.35 then
        keep = true
    end

    if trackedKind == 'Mex' and trackedFraction >= 0.55 then
        keep = true
    elseif trackedKind == 'Power' and trackedFraction >= 0.55 then
        keep = true
    elseif trackedKind == 'Radar' and trackedFraction >= 0.35 then
        keep = true
    elseif (trackedLower == 'aa' or trackedLower == 'defense') and trackedFraction >= 0.2 then
        keep = true
    elseif trackedLower == 'structure' and trackedFraction >= 0.5 then
        keep = true
    end
    if trackedKind == 'Power' and trackedFraction >= 0.8 then
        keep = true
    end
    if assigned <= 0 and trackedFraction >= 0.72 then
        keep = true
    end

    local preemptMargin = 85
    if bestLower == 'radar' and radarCritical then
        preemptMargin = 140
    end
    if trackedKind == 'Mex' and trackedFraction >= 0.55 then
        preemptMargin = preemptMargin + 120
    elseif trackedKind == 'Power' and trackedFraction >= 0.55 then
        preemptMargin = preemptMargin + 100
    elseif trackedKind == 'Radar' and trackedFraction >= 0.35 then
        preemptMargin = preemptMargin + 80
    elseif (trackedLower == 'aa' or trackedLower == 'defense') and trackedFraction >= 0.2 then
        preemptMargin = preemptMargin + 115
    elseif trackedLower == 'structure' and trackedFraction >= 0.5 then
        preemptMargin = preemptMargin + 140
    end
    if trackedKind == 'Power' and trackedFraction >= 0.8 then
        preemptMargin = preemptMargin + 180
    end
    if assigned <= 0 and trackedFraction >= 0.72 then
        preemptMargin = preemptMargin + 120
    end

    if bestPriority > (trackedPriority + preemptMargin) then
        keep = false
    end

    return keep
end

ComputeAirThreatFlags = function(runtime, now)
    local raid = runtime.RaidDefense or {}
    local constraints = ((runtime.ProductionDirector or {}).ConstraintState or {})
    local bomberWatch = constraints.BomberWatch == true
    local bomberPanic = ((raid.BomberPanicUntil or -999) > now) or ((raid.LastBomberEnemyCount or 0) >= 1 and raid.UnderAirHarass)
    local exposedMexAirRaid = raid.ExposedMexUnderAirRaid == true and raid.ExposedMexThreatPos ~= false
    return bomberWatch, bomberPanic, exposedMexAirRaid
end

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

HasEnemyCombatNear = function(aiBrain, pos, radius)
    if not aiBrain or not pos then
        return false
    end
    local count = aiBrain:GetNumUnitsAroundPoint(
        categories.MOBILE * (categories.LAND + categories.AIR + categories.NAVAL) - categories.ENGINEER - categories.SCOUT,
        pos,
        radius or 42,
        'Enemy'
    ) or 0
    return count > 0
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
    local engState = runtime.EngineerState or {}
    local mexEmergencyRebuild = engState.MexEmergencyRebuild == true
    local mexEmergencyActive = mexEmergencyRebuild or engState.MexEmergencyActive == true
    local mainPos = GetMainPos(aiBrain, runtime)
    local targetThreat = aiBrain:GetThreatAtPosition(targetPos, 1, true, 'AntiSurface') or 0
    local openingFactoryFloor = string.lower(domain or 'none') == 'land'
        and readyFactories <= 0
        and now < 180
        and mainPos
        and Distance2D(targetPos, mainPos) <= 120
        and not HasEnemyCombatNear(aiBrain, targetPos, 42)
    local stickyLandFinish = string.lower(domain or 'none') == 'land'
        and mainPos
        and Distance2D(targetPos, mainPos) <= 260
        and GetFraction(target) >= 0.18
        and not HasEnemyCombatNear(aiBrain, targetPos, 52)
    local requiredBuilders = ComputeFactoryTaskRequirements(domain, GetFraction(target), stallTime, readyFactories, eco)
    if mexEmergencyActive then
        local domainLower = string.lower(domain or 'none')
        if domainLower == 'land' then
            if readyFactories >= 1 then
                requiredBuilders = math.max(0, requiredBuilders - (mexEmergencyRebuild and 2 or 1))
                if stallTime < 16 then
                    requiredBuilders = math.min(requiredBuilders, 1)
                end
            end
        else
            requiredBuilders = math.max(0, requiredBuilders - 1)
            if not recovery.ForceFactoryRecovery and stallTime < 20 then
                requiredBuilders = 0
            end
        end
    end
    if openingFactoryFloor then
        requiredBuilders = math.max(2, math.min(3, requiredBuilders))
    elseif stickyLandFinish then
        requiredBuilders = math.max(requiredBuilders, math.min(4, readyFactories <= 1 and 3 or 2))
    end
    local forceInterrupt = stallTime >= 4 or readyFactories <= 0 or recovery.ForceFactoryRecovery or openingFactoryFloor or stickyLandFinish
    if mexEmergencyActive
        and not openingFactoryFloor
        and not stickyLandFinish
        and readyFactories >= 1
        and stallTime < 12 then
        forceInterrupt = false
    end
    if requiredBuilders <= 0 then
        return 0, {}, false, { Total = 0, Safe = 0, Reachable = 0, Interruptible = 0 }
    end

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
    local targetId = GetEntityId(target)

    for _, unit in builders do
        if unit and not unit.Dead then
            debug.Total = debug.Total + 1
            local entityId = GetEntityId(unit)
            if not (reservedBuilderIds and entityId and reservedBuilderIds[entityId]) then
                local pos = unit.GetPosition and unit:GetPosition() or false
                if pos then
                    local dist = Distance2D(pos, targetPos)
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
                        and Distance2D(pos, mainPos) <= 155
                        and dist <= 145
                        and not HasEnemyCombatNear(aiBrain, pos, 40)
                    if openerSafe then
                        safe = true
                    end
                    if isCommander and mainPos and Distance2D(pos, mainPos) > 190 then
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
                        local alreadyAssigned = focus and (GetEntityId(focus) == targetId)
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
        local entityId = GetEntityId(unit)
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
    local engState = runtime.EngineerState or {}
    local mexEmergencyRebuild = engState.MexEmergencyRebuild == true
    local mexEmergencyActive = mexEmergencyRebuild or engState.MexEmergencyActive == true
    local mainPos = GetMainPos(aiBrain, runtime)
    local targetThreat = aiBrain:GetThreatAtPosition(targetPos, 1, true, 'AntiSurface') or 0
    local radarCritical = NeedsCriticalRadar(runtime)
    local bomberWatch, bomberPanic, exposedMexAirRaid = ComputeAirThreatFlags(runtime, now)
    local raid = runtime.RaidDefense or {}
    local airThreatened = bomberWatch or bomberPanic or raid.UnderAirHarass or exposedMexAirRaid
    local targetFraction = GetFraction(target)
    local requiredBuilders = ComputeStructureTaskRequirements(kind, targetFraction, stallTime, eco)
    local kindLower = string.lower(kind or 'none')
    if mexEmergencyActive and kind ~= 'Mex' then
        if mexEmergencyRebuild then
            if kind == 'Power' and targetFraction >= 0.78 then
                requiredBuilders = math.max(1, requiredBuilders - 1)
            elseif kind == 'Radar' and radarCritical then
                requiredBuilders = math.max(1, requiredBuilders - 1)
            else
                requiredBuilders = math.max(0, requiredBuilders - 2)
            end
        elseif kind ~= 'Power' then
            requiredBuilders = math.max(0, requiredBuilders - 1)
        end
    end
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
    if requiredBuilders <= 0 then
        return 0, {}, false, { Total = 0, Safe = 0, Reachable = 0, Interruptible = 0 }
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
    local targetId = GetEntityId(target)

    for _, unit in builders do
        if unit and not unit.Dead then
            local entityId = GetEntityId(unit)
            if not (reservedBuilderIds and entityId and reservedBuilderIds[entityId]) then
                debug.Total = debug.Total + 1
                local pos = unit.GetPosition and unit:GetPosition() or false
                if pos then
                    local dist = Distance2D(pos, targetPos)
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
                    if isCommander and mainPos and Distance2D(pos, mainPos) > 170 then
                        safe = false
                    end

                    if safe then
                        debug.Safe = debug.Safe + 1
                        local reachableRadius = isCommander and math.min(dispatchRadius, 200) or dispatchRadius
                        local focus = unit.GetFocusUnit and unit:GetFocusUnit() or false
                        local alreadyAssigned = focus and (GetEntityId(focus) == targetId)
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
        local entityId = GetEntityId(unit)
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
                local dist = Distance2D(pos, mainPos)
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
                    local dist = Distance2D(pos, mainPos)
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
                local dist = Distance2D(pos, mainPos)
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
                    score = score + ((1 - GetFraction(unit)) * 80)
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

    local mainPos = GetMainPos(aiBrain, runtime)
    local engPos = eng.GetPosition and eng:GetPosition() or false
    local targetPos = target.GetPosition and target:GetPosition() or false
    if engPos and targetPos then
        local targetThreat = aiBrain:GetThreatAtPosition(targetPos, 1, true, 'AntiSurface') or 0
        local localThreat = aiBrain:GetThreatAtPosition(engPos, 1, true, 'AntiSurface') or 0
        local routeRisk = OvermindMemory.GetRouteRisk(aiBrain, engPos, targetPos, 4, 40)
        local targetEnemyCombat = HasEnemyCombatNear(aiBrain, targetPos, 26)
        local routeEnemyCombat = HasEnemyCombatNear(aiBrain, engPos, 20)
        local nearMain = mainPos and Distance2D(targetPos, mainPos) <= 140
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

    local entityId = GetEntityId(eng)
    local claimedByFactoryTask = ctx.factoryTask.Active and entityId and ctx.factoryTask.BuilderIds and ctx.factoryTask.BuilderIds[entityId]
    local claimedByStructureTask = ctx.structureTask.Active and entityId and ctx.structureTask.BuilderIds and ctx.structureTask.BuilderIds[entityId]
    local claimedByRadarOrder = entityId and ctx.radarReservedBuilderIds[entityId]
    local mexEmergency = ctx.mexRebuildUrgent or ctx.mexExpansionUrgent
    local secondLandFactoryDebt = HasSecondLandFactoryDebt(aiBrain, now)
    local ignoreFactoryClaim = mexEmergency and not ctx.severeFactoryStarve
    local ignoreStructureClaim = mexEmergency
        and ctx.structureTask
        and (ctx.structureTask.Kind ~= 'Mex' and ctx.structureTask.Kind ~= 'Power')
    local ignoreEcoClaimForSecondFactory = secondLandFactoryDebt
        and ctx.structureTask
        and (ctx.structureTask.Kind == 'Mex' or ctx.structureTask.Kind == 'Power')
    local canPreemptStructureForReclaim = claimedByStructureTask
        and not claimedByFactoryTask
        and not claimedByRadarOrder
        and ctx.contestFieldMode
        and ctx.fieldTaskWindow
        and ctx.reclaimField < ctx.fieldTaskQuota
        and (ctx.structureReclaimPreempts or 0) < 1
        and ctx.needBase <= 0
        and not ctx.mexRebuildUrgent
        and not (ctx.structureTask.Kind == 'Power' and ctx.constraints.PowerBufferLow == true)
    if canPreemptStructureForReclaim
        and TryReclaimFieldZone(aiBrain, runtime, eng, ctx.reclaimFieldPos, now) then
        ctx.reclaimField = ctx.reclaimField + 1
        ctx.structureReclaimPreempts = (ctx.structureReclaimPreempts or 0) + 1
        return
    end

    local pos = eng:GetPosition()
    if not pos then
        return
    end

    local dist = Distance2D(pos, ctx.mainPos)
    local localThreat = aiBrain:GetThreatAtPosition(pos, 1, true, 'AntiSurface') or 0
    if ctx.macroPhase == 'first_t2_power'
        and EntityCategoryContains(categories.ENGINEER * categories.MOBILE * (categories.TECH2 + categories.TECH3), eng)
        and TryOpenFirstT2PowerBuild(aiBrain, runtime, eng, ctx.mainPos, now) then
        if claimedByFactoryTask and ctx.factoryTask.BuilderIds and entityId then
            ctx.factoryTask.BuilderIds[entityId] = nil
            ctx.factoryTask.AssignedBuilders = math.max(0, (ctx.factoryTask.AssignedBuilders or 1) - 1)
        end
        if claimedByStructureTask and ctx.structureTask.BuilderIds and entityId then
            ctx.structureTask.BuilderIds[entityId] = nil
            ctx.structureTask.AssignedBuilders = math.max(0, (ctx.structureTask.AssignedBuilders or 1) - 1)
        end
        ctx.powerRecoveryCount = ctx.powerRecoveryCount + 1
        return
    end

    if ((claimedByFactoryTask and not ignoreFactoryClaim)
        or (claimedByStructureTask and not ignoreStructureClaim and not ignoreEcoClaimForSecondFactory)
        or claimedByRadarOrder) then
        return
    end

    local escort = aiBrain:GetNumUnitsAroundPoint(categories.MOBILE * (categories.LAND + categories.AIR) - categories.ENGINEER - categories.SCOUT - categories.COMMAND, pos, 26, 'Ally') or 0
    local isIdle = IsIdle(eng)
    local constructing = IsConstructing(eng)
    local commandQueueLength = GetCommandQueueLength(eng)
    local expansionCommitActive = entityId and IsExpansionCommitActive(runtime, entityId, now)
    local acted = false

    if isIdle and not constructing then
        if ctx.contestFieldMode
            and ctx.fieldTaskWindow
            and ctx.reclaimField < ctx.fieldTaskQuota
            and ctx.needBase <= 0
            and not (ctx.factoryTask.Active and (ctx.factoryTask.AssignedBuilders or 0) <= 0 and (ctx.macroPhase == 'bootstrap_factory' or ctx.macroPhase == 'land_factory_floor'))
            and TryReclaimFieldZone(aiBrain, runtime, eng, ctx.reclaimFieldPos, now) then
            ctx.reclaimField = ctx.reclaimField + 1
            acted = true
        elseif expansionCommitActive
            and localThreat < 2.1
            and dist <= math.max(560, ctx.safeExpandDistance + 80)
            and TryOpenSurplusExpansionBuild(aiBrain, runtime, eng, ctx.mainPos, ctx.enemyPos, ctx.safeExpandDistance, now) then
            ctx.dispatchedExpand = ctx.dispatchedExpand + 1
            acted = true
        elseif ctx.structureTask.Active
            and (ctx.structureTask.Kind == 'Power' or ctx.structureTask.Kind == 'Mex')
            and (ctx.macroPhase ~= 'starter_mex_claim' or ctx.structureTask.Kind == 'Power')
            and (ctx.structureTask.Kind ~= 'Mex' or not ctx.mexExpansionUrgent)
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
            and TryOpenSurplusExpansionBuild(aiBrain, runtime, eng, ctx.mainPos, ctx.enemyPos, ctx.safeExpandDistance, now) then
            ctx.dispatchedExpand = ctx.dispatchedExpand + 1
            acted = true
        elseif ctx.mexRebuildUrgent
            and localThreat < 2.0
            and dist <= 460
            and TryOpenSurplusExpansionBuild(aiBrain, runtime, eng, ctx.mainPos, ctx.enemyPos, ctx.safeExpandDistance, now) then
            ctx.dispatchedExpand = ctx.dispatchedExpand + 1
            acted = true
        elseif ctx.mexExpansionUrgent
            and localThreat < 1.95
            and dist <= 500
            and TryOpenSurplusExpansionBuild(aiBrain, runtime, eng, ctx.mainPos, ctx.enemyPos, ctx.safeExpandDistance, now) then
            ctx.dispatchedExpand = ctx.dispatchedExpand + 1
            acted = true
        elseif ctx.mexRebuildUrgent
            and localThreat < 2.05
            and dist <= 520
            and TryReclaimEnemyMex(aiBrain, runtime, eng, now) then
            ctx.reclaimEnemyMex = ctx.reclaimEnemyMex + 1
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
                local powerTarget = GetPriorityPowerRecoveryTarget(aiBrain, runtime, ctx.mainPos, ctx.structureTargetObject, ctx.structureTask)
                if powerTarget and TryAssignAssistOrRepair(aiBrain, runtime, eng, powerTarget, false, now) then
                    ctx.powerRecoveryCount = ctx.powerRecoveryCount + 1
                    acted = true
                elseif TryOpenPowerRecoveryBuild(aiBrain, runtime, eng, ctx.mainPos, now) then
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
            and not ctx.mexRebuildUrgent
            and not ctx.mexExpansionUrgent
            and ctx.reclaimField < ctx.fieldTaskQuota
            and ctx.needBase <= 0
            and TryReclaimFieldZone(aiBrain, runtime, eng, ctx.reclaimFieldPos, now) then
            ctx.reclaimField = ctx.reclaimField + 1
            acted = true
        elseif ctx.contestFieldMode
            and ctx.fieldTaskWindow
            and not ctx.mexRebuildUrgent
            and not ctx.mexExpansionUrgent
            and ctx.reclaimField < ctx.fieldTaskQuota
            and ctx.needBase <= 0
            and localThreat < 1.8
            and dist <= 380
            and TryOpenSurplusExpansionBuild(aiBrain, runtime, eng, ctx.mainPos, ctx.enemyPos, ctx.safeExpandDistance, now) then
            ctx.dispatchedExpand = ctx.dispatchedExpand + 1
            acted = true
        elseif ctx.contestFieldMode
            and ctx.fieldTaskWindow
            and not ctx.mexRebuildUrgent
            and not ctx.mexExpansionUrgent
            and ctx.reclaimField < ctx.fieldTaskQuota
            and ctx.needBase <= 0
            and localThreat < 1.9
            and dist <= 420
            and TryReclaimEnemyMex(aiBrain, runtime, eng, now) then
            ctx.reclaimEnemyMex = ctx.reclaimEnemyMex + 1
            acted = true
        end
    end

    if (not acted)
        and isIdle
        and not constructing
        and (ctx.constraints.PowerBufferLow == true or ctx.hqPowerRecoveryWanted or ShouldScaleBaseEco(runtime, now))
        and localThreat < 2.2
        and dist <= 360 then
        local powerTarget = GetPriorityPowerRecoveryTarget(aiBrain, runtime, ctx.mainPos, ctx.structureTargetObject, ctx.structureTask)
        if powerTarget and TryAssignAssistOrRepair(aiBrain, runtime, eng, powerTarget, false, now) then
            ctx.powerRecoveryCount = ctx.powerRecoveryCount + 1
            acted = true
        elseif TryOpenPowerRecoveryBuild(aiBrain, runtime, eng, ctx.mainPos, now) then
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
        and ((isIdle and not constructing) or (not constructing and GetCommandQueueLength(eng) <= 2))
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
        and ShouldPersistentSurplusSpend(runtime, now)
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
        and (ShouldPersistentSurplusSpend(runtime, now) or ShouldScaleBaseEco(runtime, now))
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
        and ShouldPersistentSurplusSpend(runtime, now)
        and localThreat < 1.8
        and dist <= 260 then
        if TryOpenSurplusExpansionBuild(aiBrain, runtime, eng, ctx.mainPos, ctx.enemyPos, ctx.safeExpandDistance, now) then
            ctx.dispatchedExpand = ctx.dispatchedExpand + 1
            ctx.surplusSpendCount = ctx.surplusSpendCount + 1
            acted = true
        elseif ShouldScaleBaseEco(runtime, now) and TryOpenPowerRecoveryBuild(aiBrain, runtime, eng, ctx.mainPos, now) then
            ctx.powerRecoveryCount = ctx.powerRecoveryCount + 1
            ctx.surplusSpendCount = ctx.surplusSpendCount + 1
            acted = true
        end
    end

    if isIdle
        and not constructing
        and (not acted)
        and not ctx.mexRebuildUrgent
        and not ctx.mexExpansionUrgent
        and TryReclaimFieldZone(aiBrain, runtime, eng, ctx.reclaimFieldPos, now) then
        ctx.reclaimField = ctx.reclaimField + 1
        acted = true
    end

    if isIdle
        and not constructing
        and (not acted)
        and not (ShouldPersistentSurplusSpend(runtime, now) or ShouldScaleBaseEco(runtime, now))
        and TryReclaimEnemyMex(aiBrain, runtime, eng, now) then
        ctx.reclaimEnemyMex = ctx.reclaimEnemyMex + 1
        acted = true
    end

    local farUnsafe = dist > math.max(230, ctx.safeExpandDistance * 0.88) and localThreat > 2 and escort < 3
    local earlyOverextend = now < 420 and dist > math.min(350, ctx.safeExpandDistance * 0.82) and escort < 2 and localThreat > 1.1
    local enemySideRisk = false
    if ctx.enemyPos then
        local distEnemy = Distance2D(pos, ctx.enemyPos)
        enemySideRisk = dist > 160 and distEnemy < (dist * 0.95) and escort < 3
    end
    local severeThreat = localThreat > 3.3 and escort < 3
    local airRaidRisk = (ctx.bomberPanic or ctx.raid.ExposedMexUnderAirRaid)
        and dist > 110
        and escort < 2
        and (
            localThreat > 0.8
            or (ctx.raid.ExposedMexThreatPos and Distance2D(pos, ctx.raid.ExposedMexThreatPos) < 70)
        )
    local queuedWork = (not isIdle) and commandQueueLength >= 1
    local preserveQueuedExpansion = queuedWork
        and (ctx.mexRebuildUrgent or ctx.mexExpansionUrgent)
        and dist > 105
        and localThreat < 2.4
        and escort >= 1
    local preserveCommittedExpansion = expansionCommitActive
        and dist > 95
        and localThreat < 2.8
        and escort >= 1
    local allowNonSevereRecall = not preserveQueuedExpansion and not preserveCommittedExpansion

    if (not acted) and (severeThreat or (allowNonSevereRecall and (farUnsafe or (not constructing and (earlyOverextend or enemySideRisk))))) then
        if RecallEngineer(runtime, eng, ctx.mainPos, now, 'threatened') then
            ctx.threatenedCount = ctx.threatenedCount + 1
        end
    elseif (not acted) and not constructing and airRaidRisk and allowNonSevereRecall then
        if RecallEngineer(runtime, eng, ctx.mainPos, now, 'air_raid') then
            ctx.threatenedCount = ctx.threatenedCount + 1
        end
    elseif (not acted) and allowNonSevereRecall and not constructing and ctx.needBase > 0 and dist > 130 and isIdle and localThreat < 1.9 then
        if RecallEngineer(runtime, eng, ctx.mainPos, now, 'base_floor') then
            ctx.recoverCount = ctx.recoverCount + 1
            ctx.needBase = ctx.needBase - 1
        end
    elseif (not acted) and allowNonSevereRecall and not constructing and ctx.factoryTask.Active and (ctx.factoryTask.AssignedBuilders or 0) < (ctx.factoryTask.RequiredBuilders or 0) and dist > 140 and localThreat < 1.6 and ctx.forcedFactoryRecover < math.max(2, ctx.factoryTask.RequiredBuilders or 0) then
        if RecallEngineer(runtime, eng, ctx.mainPos, now, 'factory_task') then
            ctx.forcedFactoryRecover = ctx.forcedFactoryRecover + 1
        end
    elseif (not acted) and allowNonSevereRecall and not constructing and ctx.severeFactoryStarve and dist > 140 and localThreat < 1.6 and ctx.forcedFactoryRecover < 2 then
        if RecallEngineer(runtime, eng, ctx.mainPos, now, 'factory_starve') then
            ctx.forcedFactoryRecover = ctx.forcedFactoryRecover + 1
        end
    end
end

function Update(aiBrain, now)
    local runtime = aiBrain.OvermindRuntime
    if not runtime then
        return
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
    local structureTask = engState.UnfinishedStructureTask or {}
    engState.UnfinishedStructureTask = structureTask
    engState.ExpansionReservations = engState.ExpansionReservations or {}
    CleanupExpansionReservations(runtime, now)
    CleanupExpansionCommits(runtime, now)

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
    local mexExpansionUrgent = now < 1700
        and mexReady < math.max(13, (constraints.StarterMexFloor or 5) + 6)
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
    local desiredReclaimQuota = policy.EngineerReclaimQuota or 0
    local firstReclaimBaseReady = baseEngineers >= math.max(2, baseFloor - 1)
    local fieldBaseReady = baseEngineers >= math.max(3, baseFloor)
    engState.ReclaimFieldStickyUntil = engState.ReclaimFieldStickyUntil or -999
    engState.ReclaimFieldStickyQuota = engState.ReclaimFieldStickyQuota or 0
    local fieldStickyActive = now < (engState.ReclaimFieldStickyUntil or -999)
    local fieldTaskQuota = 0
    if (contestFieldMode or desiredReclaimQuota > 0)
        and not mexRebuildUrgent
        and (not mexExpansionUrgent or desiredReclaimQuota > 0)
        and reclaimFieldPos
        and (fieldBaseReady or (desiredReclaimQuota > 0 and firstReclaimBaseReady))
        and not ecoCrash
        and not severeFactoryStarve
        and (factoryTaskStable or desiredReclaimQuota > 0)
        and (structureTaskStable or desiredReclaimQuota > 0) then
        if ((planner.ReclaimFirst == true or planner.OuterRetentionActive == true or outerContestUnits > 0) or desiredReclaimQuota > 0)
            and reclaimFieldScore >= 90 then
            fieldTaskQuota = math.max(1, desiredReclaimQuota)
        end
        if reclaimFieldScore >= 180
            and outerContestUnits >= 1
            and baseEngineers >= (baseFloor + 2) then
            fieldTaskQuota = math.max(fieldTaskQuota, 2)
        end
    end
    if fieldTaskQuota > 0 then
        engState.ReclaimFieldStickyUntil = now + 48
        engState.ReclaimFieldStickyQuota = math.max(engState.ReclaimFieldStickyQuota or 0, fieldTaskQuota)
        fieldStickyActive = true
    elseif fieldStickyActive
        and (contestFieldMode or desiredReclaimQuota > 0)
        and not mexRebuildUrgent
        and (not mexExpansionUrgent or desiredReclaimQuota > 0)
        and reclaimFieldPos
        and (fieldBaseReady or (desiredReclaimQuota > 0 and firstReclaimBaseReady))
        and not ecoCrash
        and not severeFactoryStarve
        and (factoryTaskStable or desiredReclaimQuota > 0)
        and (structureTaskStable or desiredReclaimQuota > 0) then
        fieldTaskQuota = math.max(1, engState.ReclaimFieldStickyQuota or 1)
    else
        engState.ReclaimFieldStickyUntil = -999
        engState.ReclaimFieldStickyQuota = 0
        fieldStickyActive = false
    end

    local ctx = {
        bomberPanic = bomberPanic,
        constraints = constraints,
        contestFieldMode = (contestFieldMode or desiredReclaimQuota > 0) and true or false,
        directSecondFactory = 0,
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
        structureReclaimPreempts = 0,
        structureTargetObject = structureTargetObject,
        structureTask = structureTask,
        surplusSpendCount = 0,
        threatenedCount = 0,
        transitionLock = transitionLock,
        fieldTaskQuota = fieldTaskQuota,
        mexRebuildUrgent = mexRebuildUrgent,
        mexExpansionUrgent = mexExpansionUrgent,
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
    ctx.fieldTaskWindow = (contestFieldMode or desiredReclaimQuota > 0)
        and not severeFactoryStarve
        and not ecoCrash
        and (factoryTaskStable or desiredReclaimQuota > 0)
        and (structureTaskStable or desiredReclaimQuota > 0)
        and (fieldBaseReady or (desiredReclaimQuota > 0 and firstReclaimBaseReady))
        and fieldTaskQuota > 0
    for _, eng in engineers do
        ProcessEngineer(aiBrain, runtime, eng, now, ctx)
    end

    local radarOrderActive = next(radarReservedBuilderIds) ~= nil
    local allowExpandWhileRadarPending = radarCritical
        and not structureTask.Active
        and radarOrderActive
        and table.getn(engineers or {}) >= math.max(baseFloor + 3, 6)
    local mexDispatchOverride = mexRebuildUrgent
        or (mexExpansionUrgent and mexReady < math.max(8, (constraints.StarterMexFloor or 5) + 2))

    local canDispatchExpand = now >= 60
        and not severeFactoryStarve
        and not ecoCrash
        and (mexDispatchOverride or not recovery.ForceBaseEngineerRecovery)
        and (mexDispatchOverride or not factoryTask.Active)
        and (mexDispatchOverride or not structureTask.Active)
        and (not radarCritical or allowExpandWhileRadarPending)
        and (not (bomberWatch and currentRadar <= 0) or allowExpandWhileRadarPending)
        and not raid.ExposedMexUnderAirRaid
        and not (bomberPanic and table.getn(engineers or {}) <= math.max(4, baseFloor + 1))
        and (mexDispatchOverride or baseEngineers >= math.max(2, baseFloor - 2))
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
        if mexDispatchOverride then
            threatCap = math.max(threatCap, 1.75)
        end
        local dispatchDistance = math.max(420, safeExpandDistance)
        if mexDispatchOverride then
            dispatchDistance = math.max(dispatchDistance, safeExpandDistance + 80)
        end
        ctx.dispatchedExpand = DispatchExpansionEngineer(aiBrain, runtime, now, engineers, mainPos, enemyPos, dispatchDistance, threatCap)
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

    local activity = CountEngineerActivity(engineers)
    activity.BaseEngineers = baseEngineers
    activity.NeedBase = math.max(0, baseFloor - baseEngineers)
    activity.RecoverCount = ctx.recoverCount
    activity.ThreatRecallCount = ctx.threatenedCount
    activity.FactoryRecoverCount = ctx.forcedFactoryRecover
    activity.StructureRecoverCount = structureTask.AssignedBuilders or 0
    activity.ExpansionDispatchCount = ctx.dispatchedExpand
    activity.ReclaimFieldCount = ctx.reclaimField
    activity.ReclaimEnemyMexCount = ctx.reclaimEnemyMex
    activity.PowerRecoveryCount = ctx.powerRecoveryCount
    activity.SurplusSpendCount = ctx.surplusSpendCount
    activity.ReclaimQuota = fieldTaskQuota
    local blockedReason = severeFactoryStarve and 'factory_starve'
        or ecoCrash and 'eco_crash'
        or fieldTaskQuota <= 0 and 'no_reclaim_quota'
        or 'none'
    activity.BlockedReason = blockedReason
    OvermindEconomyLedger.PublishEngineerActivity(aiBrain, runtime, now, activity)

    local shouldLog = (ctx.recoverCount + ctx.threatenedCount + ctx.forcedFactoryRecover + ctx.directSecondFactory + ctx.dispatchedExpand + ctx.reclaimEnemyMex + ctx.reclaimField) > 0
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
        LOG(string.format('*OVERMIND ENGDIR A%d t=%.1f recover=%d threat=%d facRec=%d directFac=%d powerRec=%d surp=%d expand=%d field=%d quota=%d block=%s baseNeed=%d facTask=%d:%s frac=%.2f stall=%.1f asn=%d/%d structTask=%d:%s:%s frac=%.2f stall=%.1f asn=%d/%d near=%d pos=%.1f,%.1f',
            aiBrain:GetArmyIndex(),
            now,
            ctx.recoverCount,
            ctx.threatenedCount,
            ctx.forcedFactoryRecover,
            ctx.directSecondFactory,
            ctx.powerRecoveryCount,
            ctx.surplusSpendCount,
            ctx.dispatchedExpand,
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
            structureNearby,
            sx,
            sz))
    end
end
