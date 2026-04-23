local AIUtils = import('/lua/ai/aiutilities.lua')
local Common = import('/mods/OvermindAI/lua/AI/Overmind/EngineerDirector/Common.lua')
local Threat = import('/mods/OvermindAI/lua/AI/Overmind/EngineerDirector/Threat.lua')
local OvermindMemory = import('/mods/OvermindAI/lua/AI/Overmind/Memory.lua')

local T1MexCategory = categories.STRUCTURE * categories.MASSEXTRACTION * categories.TECH1
local LandCombatCategory = categories.MOBILE * categories.LAND - categories.ENGINEER - categories.SCOUT - categories.COMMAND


local M = {}

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

    local distMain = Common.Distance2D(pos, mainPos)
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
        local distEnemy = Common.Distance2D(pos, enemyPos)
        if distEnemy + 58 < distMain then
            return false
        end
    end

    local raid = runtime and runtime.RaidDefense or {}
    if raid and raid.LastThreatMexPos and Common.Distance2D(pos, raid.LastThreatMexPos) < 40 then
        return false
    end
    if raid and raid.ExposedMexUnderAirRaid and raid.ExposedMexThreatPos and Common.Distance2D(pos, raid.ExposedMexThreatPos) < 72 then
        return false
    end
    local routeRisk = OvermindMemory.GetRouteRisk(aiBrain, mainPos, pos, 5, 54)
    if routeRisk > 3.4 then
        return false
    end

    if Threat.HasEnemyCombatNear(aiBrain, pos, 30) then
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
    local distMain = Common.Distance2D(pos, mainPos)
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
        local distExpansion = Common.Distance2D(pos, bestExpansionPos)
        if distExpansion <= 36 then
            bias = bias + 30
        elseif distExpansion <= 80 then
            bias = bias + 14
        end
    end

    local bestRaidPos = graph.BestRaidPos or ((runtime.ZoneModel or {}).BestRaidPos)
    if bestRaidPos then
        local distRaid = Common.Distance2D(pos, bestRaidPos)
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
        local distEnemy = Common.Distance2D(pos, enemyPos)
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

local function LerpPos(a, b, alpha)
    local t = alpha or 0.5
    return {
        (a[1] or 0) + (((b[1] or 0) - (a[1] or 0)) * t),
        (a[2] or 0) + (((b[2] or 0) - (a[2] or 0)) * t),
        (a[3] or 0) + (((b[3] or 0) - (a[3] or 0)) * t),
    }
end

local function HasExpansionEscortSupport(aiBrain, runtime, mainPos, targetPos)
    if not aiBrain or not targetPos then
        return false
    end

    if (aiBrain:GetNumUnitsAroundPoint(LandCombatCategory, targetPos, 54, 'Ally') or 0) >= 2 then
        return true
    end
    if mainPos then
        local routePos = LerpPos(mainPos, targetPos, 0.58)
        if (aiBrain:GetNumUnitsAroundPoint(LandCombatCategory, routePos, 42, 'Ally') or 0) >= 2 then
            return true
        end
    end

    local force = runtime and runtime.ForceDirector or {}
    local outerTask = ((force.Tasks or {}).outer_contest) or {}
    local outerCount = outerTask.CurrentUnits or table.getn(outerTask.AssignedUnitRefs or {})
    local outerTarget = outerTask.TargetPos
        or ((runtime and runtime.StrategicPlanner or {}).ReclaimFieldPos)
        or ((runtime and runtime.StrategicPlanner or {}).OuterContestPos)
    return outerCount >= 2 and outerTarget and Common.Distance2D(outerTarget, targetPos) <= 130
end

local function NeedsExpansionEscort(aiBrain, runtime, mainPos, targetPos, now, mexReady)
    if not aiBrain or not mainPos or not targetPos then
        return false
    end
    local distMain = Common.Distance2D(mainPos, targetPos)
    if (now or 0) < 210 or distMain < 155 then
        return false
    end

    local routeRisk = OvermindMemory.GetRouteRisk(aiBrain, mainPos, targetPos, 4, 48)
    local targetThreat = aiBrain:GetThreatAtPosition(targetPos, 1, true, 'AntiSurface') or 0
    local mapControl = ((runtime and runtime.ZoneModel) and runtime.ZoneModel.MapControl) or 0.5
    local mexEmergency = ((runtime and runtime.EngineerState) and runtime.EngineerState.MexEmergencyActive == true) or false
    return mexEmergency
        or (mexReady or 0) < 8
        or mapControl < 0.34
        or routeRisk > 1.45
        or targetThreat > 0.25
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
        if unit and not unit.Dead and Common.GetFraction(unit) >= 0.95 and not unit:IsUnitState('BeingBuilt') then
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

local function FindExpansionTarget(aiBrain, runtime, mainPos, enemyPos, maxDistance, threatCap, now, engineerPos)
    now = now or 0
    local sourcePos = engineerPos or mainPos
    local engineerId = engineerPos and engineerPos.EngineerId or false
    if runtime and runtime.ZoneGraph and runtime.ZoneGraph.BestExpansionNodeKey then
        local node = runtime.ZoneGraph.ByKey and runtime.ZoneGraph.ByKey[runtime.ZoneGraph.BestExpansionNodeKey]
        if node and node.Pos
            and node.Medium == 'land'
            and node.Classification ~= 'enemy_side'
            and (node.GraphDistHome or 999999) <= (maxDistance + 120)
            and (node.Threat or 0) <= (threatCap + 0.45)
            and (node.RouteRisk or 0) <= 5
            and not HasFriendlyMexAtPos(aiBrain, node.Pos, 8)
            and not IsReservedExpansionTarget(runtime, now, node.Pos, engineerId)
            and IsSafeExpansionTarget(aiBrain, runtime, node.Pos, mainPos, enemyPos, maxDistance, threatCap + 0.15) then
            return node.Pos
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
            local distMain = Common.Distance2D(pos, mainPos)
            local distSource = Common.Distance2D(pos, sourcePos)
            local threat = aiBrain:GetThreatAtPosition(pos, 1, true, 'AntiSurface') or 0
            local score
            if now < 360 then
                score = 420 - (distMain * 1.05) - (distSource * 0.55)
            else
                score = 320 - math.abs(170 - distMain) - (distSource * 0.18)
            end
            score = score - (threat * 28)
            score = score + GetContestExpansionBias(runtime, pos, mainPos, enemyPos)
            if enemyPos then
                local distEnemy = Common.Distance2D(pos, enemyPos)
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
    local anchorDistMain = Common.Distance2D(anchorPos, mainPos)
    for _, marker in markers do
        local pos = marker and marker.Position
        if pos
            and not HasFriendlyMexAtPos(aiBrain, pos, 8)
            and not IsReservedExpansionTarget(runtime, now, pos, engineerId)
            and IsSafeExpansionTarget(aiBrain, runtime, pos, mainPos, enemyPos, maxDistance, threatCap) then
            local distAnchor = Common.Distance2D(pos, anchorPos)
            if distAnchor >= 28 and distAnchor <= 130 then
                local distMain = Common.Distance2D(pos, mainPos)
                local threat = aiBrain:GetThreatAtPosition(pos, 1, true, 'AntiSurface') or 0
                local score = 280 - (distAnchor * 1.45) - (distMain * 0.25) - (threat * 30)
                if distMain + 12 >= anchorDistMain then
                    score = score + 34
                end
                if enemyPos then
                    local distEnemy = Common.Distance2D(pos, enemyPos)
                    score = score + math.min(30, distEnemy * 0.08)
                end
                if score > bestScore then
                    bestScore = score
                    bestPos = pos
                end
            end
        end
    end

    return bestPos
end

local function DispatchExpansionEngineer(aiBrain, runtime, now, engineers, mainPos, enemyPos, safeExpandDistance, threatCap)
    local director = runtime and runtime.ProductionDirector or {}
    local constraints = director and director.ConstraintState or {}
    local policy = runtime and runtime.EcoPolicy or {}
    local macro = runtime and runtime.MacroController or {}
    local raid = runtime and runtime.RaidDefense or {}
    local engState = runtime and runtime.EngineerState or {}
    local mexEmergency = engState and engState.MexEmergencyActive == true
    local mexReady = (((director.Current or {}).Eco or {}).Mex or {}).Ready or 0
    local bootstrap = constraints and constraints.EconBootstrap == true
    local starterPhase = constraints and constraints.StarterPhase == true
    local contestDispatch = policy.ForwardContestBias == true
        or policy.ReclaimPressureMode == true
        or macro.HQPressureEscape == true
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
        if eng and not eng.Dead and not Common.IsConstructing(eng) and Common.IsIdle(eng) then
            local pos = eng:GetPosition()
            if pos and Common.Distance2D(pos, mainPos) <= dispatchRadius then
                local sourcePos = { pos[1], pos[2] or 0, pos[3], EngineerId = Common.GetEntityId(eng) }
                local target = FindExpansionTarget(aiBrain, runtime, mainPos, enemyPos, safeExpandDistance, threatCap, now, sourcePos)
                if not target then
                    local relaxedCap = math.max(threatCap + 0.35, 1.55)
                    target = FindExpansionTarget(aiBrain, runtime, mainPos, enemyPos, safeExpandDistance, relaxedCap, now, sourcePos)
                end
                if not target then
                    break
                end
                local targetSupported = HasExpansionEscortSupport(aiBrain, runtime, mainPos, target)
                if NeedsExpansionEscort(aiBrain, runtime, mainPos, target, now, mexReady) and not targetSupported then
                    runtime.LastExpansionEscortBlockedTime = now
                    runtime.LastExpansionEscortBlockedPos = target
                    break
                end
                local bp = PickMexBlueprint(eng)
                if bp and IssueBuildMobile then
                    local engineerId = Common.GetEntityId(eng)
                    ReserveExpansionTarget(runtime, now, target, engineerId)
                    IssueBuildMobile({ eng }, target, bp, {})
                    local landReady = ((((runtime.ProductionDirector or {}).Current or {}).Factories or {}).Land or {}).Ready or 0
                    if targetSupported or ((now < 300 or landReady <= 1) and Common.Distance2D(mainPos, target) <= 165) then
                        local followup = FindFollowupExpansionTarget(
                            aiBrain,
                            runtime,
                            mainPos,
                            enemyPos,
                            target,
                            safeExpandDistance,
                            threatCap,
                            now,
                            engineerId)
                        if followup then
                            ReserveExpansionTarget(runtime, now, followup, engineerId)
                            IssueBuildMobile({ eng }, followup, bp, {})
                        end
                    end
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


M.PickMexBlueprint = PickMexBlueprint
M.IsSafeExpansionTarget = IsSafeExpansionTarget
M.ExpansionReservationKey = ExpansionReservationKey
M.FindNearestZoneNode = FindNearestZoneNode
M.GetContestExpansionBias = GetContestExpansionBias
M.CleanupExpansionReservations = CleanupExpansionReservations
M.ReserveExpansionTarget = ReserveExpansionTarget
M.IsReservedExpansionTarget = IsReservedExpansionTarget
M.HasFriendlyMexAtPos = HasFriendlyMexAtPos
M.FindExpansionTarget = FindExpansionTarget
M.FindFollowupExpansionTarget = FindFollowupExpansionTarget
M.DispatchExpansionEngineer = DispatchExpansionEngineer
return M

