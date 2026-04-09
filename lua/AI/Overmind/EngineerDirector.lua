local AIUtils = import('/lua/ai/aiutilities.lua')
local OvermindMemory = import('/mods/OvermindAI/lua/AI/Overmind/Memory.lua')

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
local ComputeAirThreatFlags

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

local function IsConstructing(unit)
    if not unit or unit.Dead then
        return false
    end
    return unit:IsUnitState('Building') or unit:IsUnitState('Upgrading')
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

local function TryReclaimEnemyMex(aiBrain, runtime, eng, now)
    if not eng or eng.Dead then
        return false
    end
    local pos = eng.GetPosition and eng:GetPosition() or false
    if not pos then
        return false
    end

    runtime.EngineerEnemyMexReclaimCooldown = runtime.EngineerEnemyMexReclaimCooldown or {}
    local entityId = eng.EntityId or 0
    local last = runtime.EngineerEnemyMexReclaimCooldown[entityId] or -999
    if now - last < 14 then
        return false
    end

    local enemyMex = aiBrain:GetUnitsAroundPoint(EnemyMexCategory, pos, 26, 'Enemy')
    if not enemyMex or table.getn(enemyMex) <= 0 then
        return false
    end

    local localThreat = aiBrain:GetThreatAtPosition(pos, 1, true, 'AntiSurface') or 0
    local escort = aiBrain:GetNumUnitsAroundPoint(
        categories.MOBILE * categories.LAND - categories.ENGINEER - categories.SCOUT - categories.COMMAND,
        pos,
        24,
        'Ally') or 0
    if localThreat > 2.2 and escort < 2 then
        return false
    end

    local reclaimTargets = {}
    local maxTargets = math.min(2, table.getn(enemyMex))
    for i = 1, maxTargets do
        table.insert(reclaimTargets, enemyMex[i])
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
    if routeRisk > 4.6 then
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
            and (node.RouteRisk or 0) <= 8
            and not HasFriendlyMexAtPos(aiBrain, node.Pos, 8)
            and not IsReservedExpansionTarget(runtime, now, node.Pos, engineerId) then
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
    local raid = runtime and runtime.RaidDefense or {}
    local bootstrap = constraints and constraints.EconBootstrap == true
    local starterPhase = constraints and constraints.StarterPhase == true
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
    if now < (runtime.LastExpansionDispatchTime or -999) + (bootstrap and 1.2 or 2.2) then
        return 0
    end

    CleanupExpansionReservations(runtime, now)
    local dispatched = 0
    local dispatchLimit = bootstrap and 2 or 1
    for _, eng in engineers do
        if eng and not eng.Dead and not IsConstructing(eng) and IsIdle(eng) then
            local pos = eng:GetPosition()
            if pos and Distance2D(pos, mainPos) <= 220 then
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
                    if now < 420 or landReady <= 1 then
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

local function ScoreStructureTarget(aiBrain, runtime, structure, kind, pos, fraction, mainPos)
    local eco = runtime.EcoState or {}
    local recovery = runtime.Recovery or {}
    local raid = runtime.RaidDefense or {}
    local constraints = ((runtime.ProductionDirector or {}).ConstraintState or {})
    local distMain = Distance2D(pos, mainPos)
    local localThreat = aiBrain:GetThreatAtPosition(pos, 1, true, 'AntiSurface') or 0
    local engineerLossRisk = OvermindMemory.GetEngineerLossRisk(aiBrain, pos, 42)
    local expansionRisk = OvermindMemory.GetExpansionRisk(aiBrain, pos, 56)
    local bootstrapPowerNeed = NeedsBootstrapPower(aiBrain, runtime)
    local radarCritical = NeedsCriticalRadar(runtime)
    local starterPhase = ((runtime.ProductionDirector or {}).ConstraintState or {}).StarterPhase == true
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
            score = score - (radarCritical and 170 or 55)
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
            score = score - 85
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
            score = score - 150
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

    for _, structure in structures do
        if structure and not structure.Dead and not structure:IsUnitState('Upgrading') then
            local fraction = GetFraction(structure)
            if fraction < 0.995 then
                local pos = structure.GetPosition and structure:GetPosition() or false
                if pos then
                    local distMain = Distance2D(pos, mainPos)
                    local kind = GetStructureKind(structure)
                    local maxDist = (kind == 'Mex') and math.max(300, safeExpandDistance * 0.95) or 240
                    if distMain <= maxDist then
                        local score, threat = ScoreStructureTarget(aiBrain, runtime, structure, kind, pos, fraction, mainPos)
                        if threat <= ((kind == 'Mex') and 3.1 or 2.8) and score > bestScore then
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
    if fraction >= 0.4 then
        required = required + 1
    end
    if stallTime >= 16 then
        required = required + 1
    end
    if (eco.MassStorageRatio or 0) <= 0.02 and required > 2 and readyFactories > 0 then
        required = required - 1
    end
    return Clamp(required, 1, 4)
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

local function HasEnemyCombatNear(aiBrain, pos, radius)
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
    local mainPos = GetMainPos(aiBrain, runtime)
    local targetThreat = aiBrain:GetThreatAtPosition(targetPos, 1, true, 'AntiSurface') or 0
    local openingFactoryFloor = string.lower(domain or 'none') == 'land'
        and readyFactories <= 0
        and now < 180
        and mainPos
        and Distance2D(targetPos, mainPos) <= 120
        and not HasEnemyCombatNear(aiBrain, targetPos, 42)
    local requiredBuilders = ComputeFactoryTaskRequirements(domain, GetFraction(target), stallTime, readyFactories, eco)
    if openingFactoryFloor then
        requiredBuilders = math.max(2, math.min(3, requiredBuilders))
    end
    local forceInterrupt = stallTime >= 6 or readyFactories <= 0 or recovery.ForceFactoryRecovery or openingFactoryFloor

    local dispatchRadius = 240
    if stallTime >= 10 then
        dispatchRadius = 420
    end
    if stallTime >= 24 then
        dispatchRadius = 760
    end
    if stallTime >= 48 then
        dispatchRadius = 960
    end

    local interruptQCap = 0
    if forceInterrupt then
        interruptQCap = 2
    end
    if stallTime >= 18 then
        interruptQCap = 5
    end
    if readyFactories <= 0 and domain == 'Land' then
        interruptQCap = math.max(interruptQCap, 8)
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
                                    + ((openingFactoryFloor and not isCommander and dist <= 90) and 80 or 0),
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
    local mainPos = GetMainPos(aiBrain, runtime)
    local targetThreat = aiBrain:GetThreatAtPosition(targetPos, 1, true, 'AntiSurface') or 0
    local radarCritical = NeedsCriticalRadar(runtime)
    local bomberWatch, bomberPanic, exposedMexAirRaid = ComputeAirThreatFlags(runtime, now)
    local raid = runtime.RaidDefense or {}
    local airThreatened = bomberWatch or bomberPanic or raid.UnderAirHarass or exposedMexAirRaid
    local targetFraction = GetFraction(target)
    local requiredBuilders = ComputeStructureTaskRequirements(kind, targetFraction, stallTime, eco)
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

    local baseFloor = policy.BaseEngineerFloor or 3
    if now < 300 then
        baseFloor = math.max(2, baseFloor - 1)
    end
    local safeExpandDistance = policy.SafeExpandDistance or 680
    local recoverCount = 0
    local threatenedCount = 0
    local forcedFactoryRecover = 0
    local dispatchedExpand = 0
    local reclaimEnemyMex = 0
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
    local currentRadar = ((((runtime.ProductionDirector or {}).Current or {}).Structures or {}).Radar) or 0
    local bomberWatch = constraints.BomberWatch == true
    local bomberPanic = ((raid.BomberPanicUntil or -999) > now) or ((raid.LastBomberEnemyCount or 0) >= 1 and raid.UnderAirHarass)
    local radarReservedBuilderIds = GetRadarReservedBuilderIds(runtime, now)

    local target, targetPos, fraction, domain, readyFactories = FindBestUnfinishedFactory(aiBrain, runtime, mainPos)
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
        if assignedBuilders > 0 then
            forcedFactoryRecover = assignedBuilders
        end
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
    if not factoryTaskCritical then
        local trackedStructure, trackedPos, trackedFraction, trackedKind, trackedPriority = FindTrackedUnfinishedStructure(aiBrain, structureTask)
        local structure, structurePos, structureFraction, structureKind, structurePriority = FindBestUnfinishedStructure(aiBrain, runtime, mainPos)

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
                stickyDuration = 18
            elseif string.lower(structureKind or 'none') == 'structure' then
                stickyDuration = 16
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
            end
        else
            ResetStructureTask(structureTask)
        end
    else
        ResetStructureTask(structureTask)
    end

    for _, eng in engineers do
        if eng and not eng.Dead then
            local entityId = GetEntityId(eng)
            local claimedByFactoryTask = factoryTask.Active and entityId and factoryTask.BuilderIds and factoryTask.BuilderIds[entityId]
            local claimedByStructureTask = structureTask.Active and entityId and structureTask.BuilderIds and structureTask.BuilderIds[entityId]
            local claimedByRadarOrder = entityId and radarReservedBuilderIds[entityId]
            if not (claimedByFactoryTask or claimedByStructureTask or claimedByRadarOrder) then
                local pos = eng:GetPosition()
                if pos then
                    local dist = Distance2D(pos, mainPos)
                    local localThreat = aiBrain:GetThreatAtPosition(pos, 1, true, 'AntiSurface') or 0
                    local escort = aiBrain:GetNumUnitsAroundPoint(categories.MOBILE * (categories.LAND + categories.AIR) - categories.ENGINEER - categories.SCOUT - categories.COMMAND, pos, 26, 'Ally') or 0
                    local isIdle = IsIdle(eng)
                    local constructing = IsConstructing(eng)
                    local acted = false

                    if isIdle and not constructing and TryReclaimEnemyMex(aiBrain, runtime, eng, now) then
                        reclaimEnemyMex = reclaimEnemyMex + 1
                        acted = true
                    end

                    local farUnsafe = dist > math.max(230, safeExpandDistance * 0.88) and localThreat > 2 and escort < 3
                    local earlyOverextend = now < 420 and dist > math.min(350, safeExpandDistance * 0.82) and escort < 2 and localThreat > 1.1
                    local enemySideRisk = false
                    if enemyPos then
                        local distEnemy = Distance2D(pos, enemyPos)
                        enemySideRisk = dist > 160 and distEnemy < (dist * 0.95) and escort < 3
                    end
                    local severeThreat = localThreat > 3.3 and escort < 3
                    local airRaidRisk = (bomberPanic or raid.ExposedMexUnderAirRaid)
                        and dist > 110
                        and escort < 2
                        and (
                            localThreat > 0.8
                            or (raid.ExposedMexThreatPos and Distance2D(pos, raid.ExposedMexThreatPos) < 70)
                        )

                    if (not acted) and (severeThreat or farUnsafe or (not constructing and (earlyOverextend or enemySideRisk))) then
                        if RecallEngineer(runtime, eng, mainPos, now, 'threatened') then
                            threatenedCount = threatenedCount + 1
                        end
                    elseif (not acted) and not constructing and airRaidRisk then
                        if RecallEngineer(runtime, eng, mainPos, now, 'air_raid') then
                            threatenedCount = threatenedCount + 1
                        end
                    elseif (not acted) and not constructing and needBase > 0 and dist > 130 and isIdle and localThreat < 1.9 then
                        if RecallEngineer(runtime, eng, mainPos, now, 'base_floor') then
                            recoverCount = recoverCount + 1
                            needBase = needBase - 1
                        end
                    elseif (not acted) and not constructing and severeFactoryStarve and dist > 140 and localThreat < 1.6 and forcedFactoryRecover < 2 then
                        if RecallEngineer(runtime, eng, mainPos, now, 'factory_starve') then
                            forcedFactoryRecover = forcedFactoryRecover + 1
                        end
                    end
                end
            end
        end
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
        dispatchedExpand = DispatchExpansionEngineer(aiBrain, runtime, now, engineers, mainPos, enemyPos, math.max(420, safeExpandDistance), threatCap)
    end

    runtime.LastEngineerRecovered = recoverCount
    runtime.LastEngineerThreatRecalls = threatenedCount
    runtime.LastEngineerFactoryRecalls = forcedFactoryRecover
    runtime.LastEngineerStructureRecover = structureTask.AssignedBuilders or 0
    runtime.LastEngineerExpandDispatch = dispatchedExpand
    runtime.LastEngineerEnemyMexReclaim = reclaimEnemyMex

    local shouldLog = (recoverCount + threatenedCount + forcedFactoryRecover + dispatchedExpand + reclaimEnemyMex) > 0
        or factoryTask.Active
        or structureTask.Active
    if shouldLog and (now - (runtime.LastEngineerDirectorLogTime or -999)) >= 20 then
        runtime.LastEngineerDirectorLogTime = now
        LOG(string.format('*OVERMIND ENGDIR A%d t=%.1f recover=%d threat=%d facRec=%d expand=%d baseNeed=%d facTask=%d:%s frac=%.2f stall=%.1f asn=%d/%d structTask=%d:%s frac=%.2f stall=%.1f asn=%d/%d',
            aiBrain:GetArmyIndex(),
            now,
            recoverCount,
            threatenedCount,
            forcedFactoryRecover,
            dispatchedExpand,
            math.max(0, baseFloor - baseEngineers),
            factoryTask.Active and 1 or 0,
            factoryTask.Domain or 'none',
            factoryTask.TargetFraction or 1,
            factoryTask.StallTime or 0,
            factoryTask.AssignedBuilders or 0,
            factoryTask.RequiredBuilders or 0,
            structureTask.Active and 1 or 0,
            structureTask.Kind or 'none',
            structureTask.TargetFraction or 1,
            structureTask.StallTime or 0,
            structureTask.AssignedBuilders or 0,
            structureTask.RequiredBuilders or 0))
    end
end
