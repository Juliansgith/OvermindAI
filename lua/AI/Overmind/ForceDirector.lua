local LandDirectCategory = categories.MOBILE * categories.LAND * categories.DIRECTFIRE
    - categories.ENGINEER - categories.SCOUT - categories.ANTIAIR - categories.COMMAND
local LandAACategory = categories.MOBILE * categories.LAND * categories.ANTIAIR
    - categories.ENGINEER - categories.SCOUT - categories.COMMAND
local LandIndirectCategory = categories.MOBILE * categories.LAND * categories.INDIRECTFIRE
    - categories.ENGINEER - categories.SCOUT - categories.COMMAND
local LandScoutCategory = categories.MOBILE * categories.LAND * categories.SCOUT - categories.ENGINEER
local AirFighterCategory = categories.MOBILE * categories.AIR * categories.ANTIAIR
    - categories.SCOUT - categories.TRANSPORTATION - categories.COMMAND
local AirBomberCategory = categories.MOBILE * categories.AIR * categories.BOMBER
    - categories.SCOUT - categories.TRANSPORTATION - categories.COMMAND
local AirScoutCategory = categories.MOBILE * categories.AIR * categories.SCOUT

local OvermindRoleWeights = import('/mods/OvermindAI/lua/AI/Overmind/RoleWeights.lua')

local Module = {
    Name = 'ForceDirector',
    StateSlice = 'ForceDirector',
}

local function Clamp(v, minV, maxV)
    if v < minV then
        return minV
    end
    if v > maxV then
        return maxV
    end
    return v
end

local function Distance2D(a, b)
    local dx = (a[1] or 0) - (b[1] or 0)
    local dz = (a[3] or 0) - (b[3] or 0)
    return math.sqrt((dx * dx) + (dz * dz))
end

local function GetMainPos(aiBrain, runtime)
    if runtime and runtime.ZoneModel and runtime.ZoneModel.OwnMainPos then
        return runtime.ZoneModel.OwnMainPos
    end
    if aiBrain.BuilderManagers and aiBrain.BuilderManagers.MAIN and aiBrain.BuilderManagers.MAIN.Position then
        return aiBrain.BuilderManagers.MAIN.Position
    end
    local sx, sz = aiBrain:GetArmyStartPos()
    return { sx, 0, sz }
end

local function GetACU(aiBrain)
    local acu = aiBrain:GetListOfUnits(categories.COMMAND, false, true)
    if acu and table.getn(acu) > 0 and acu[1] and not acu[1].Dead then
        return acu[1]
    end
    return false
end

local function GetEntityId(unit)
    if not unit or unit.Dead then
        return false
    end
    if unit.GetEntityId then
        return tostring(unit:GetEntityId())
    end
    local pos = unit.GetPosition and unit:GetPosition() or { 0, 0, 0 }
    return tostring(unit.UnitId or 'unit') .. '_' .. tostring(math.floor(pos[1] or 0)) .. '_' .. tostring(math.floor(pos[3] or 0))
end

local function BuildPool(units, anchor)
    local pool = {}
    for _, unit in units do
        if unit and not unit.Dead then
            local pos = unit.GetPosition and unit:GetPosition() or anchor
            table.insert(pool, {
                Unit = unit,
                Dist = pos and anchor and Distance2D(pos, anchor) or 0,
            })
        end
    end

    table.sort(pool, function(a, b)
        return (a.Dist or 0) < (b.Dist or 0)
    end)

    return pool
end

local function TakeClosest(units, anchor, count, used)
    local taken = {}
    local localUsed = used or {}
    local pool = BuildPool(units, anchor)
    for _, entry in pool do
        if table.getn(taken) >= count then
            break
        end
        local id = GetEntityId(entry.Unit)
        if id and not localUsed[id] then
            localUsed[id] = true
            table.insert(taken, entry.Unit)
        end
    end
    return taken, localUsed
end

local function CollectUnassigned(units, used)
    local out = {}
    for _, unit in units do
        local id = GetEntityId(unit)
        if id and not used[id] then
            table.insert(out, unit)
        end
    end
    return out
end

local function MergeLists(a, b, c)
    local out = {}
    for _, unit in a or {} do
        table.insert(out, unit)
    end
    for _, unit in b or {} do
        table.insert(out, unit)
    end
    for _, unit in c or {} do
        table.insert(out, unit)
    end
    return out
end

local function CountUnits(list)
    return list and table.getn(list) or 0
end

local function Round(v, digits)
    local scale = 10 ^ (digits or 0)
    return math.floor((v * scale) + 0.5) / scale
end

local function WeightedMean(entries, fallback)
    local totalWeight = 0
    local totalValue = 0
    for _, entry in entries or {} do
        local weight = entry[2] or 0
        if weight > 0 then
            totalWeight = totalWeight + weight
            totalValue = totalValue + ((entry[1] or 0) * weight)
        end
    end
    if totalWeight <= 0 then
        return fallback or 1
    end
    return totalValue / totalWeight
end

local function CopyPos(pos)
    if not pos then
        return false
    end
    return { pos[1] or 0, pos[2] or 0, pos[3] or 0 }
end

local function BuildAssignedIds(list)
    local ids = {}
    for _, unit in list or {} do
        local id = GetEntityId(unit)
        if id then
            table.insert(ids, id)
        end
    end
    return ids
end

local function BuildUnitMap(list)
    local byId = {}
    for _, unit in list or {} do
        local id = GetEntityId(unit)
        if id then
            byId[id] = unit
        end
    end
    return byId
end

local function CollectPreferredUnits(units, preferredIds, anchor, used, maxCount, maxRetainDistance)
    local taken = {}
    local localUsed = used or {}
    if maxCount <= 0 then
        return taken, localUsed
    end

    local unitMap = BuildUnitMap(units)
    for _, id in preferredIds or {} do
        if table.getn(taken) >= maxCount then
            break
        end

        local unit = unitMap[id]
        if unit and not localUsed[id] then
            local pos = unit.GetPosition and unit:GetPosition() or anchor
            local inRange = true
            if anchor and pos and maxRetainDistance and maxRetainDistance > 0 then
                inRange = Distance2D(pos, anchor) <= maxRetainDistance
            end
            if inRange then
                localUsed[id] = true
                table.insert(taken, unit)
            end
        end
    end

    return taken, localUsed
end

local function TakeTaskUnits(units, anchor, count, used, previousTask, options)
    local limit = math.max(0, math.floor(count or 0))
    local opts = options or {}
    local taken = {}
    local localUsed = used or {}

    if limit <= 0 then
        return taken, localUsed
    end

    if previousTask and previousTask.AssignedUnits then
        taken, localUsed = CollectPreferredUnits(
            units,
            previousTask.AssignedUnits,
            anchor,
            localUsed,
            limit,
            opts.MaxRetainDistance or false)
    end

    if table.getn(taken) >= limit then
        return taken, localUsed
    end

    local pool = BuildPool(units, anchor)
    for _, entry in pool do
        if table.getn(taken) >= limit then
            break
        end
        local id = GetEntityId(entry.Unit)
        if id and not localUsed[id] then
            local localPos = entry.Unit.GetPosition and entry.Unit:GetPosition() or anchor
            local inRange = true
            if anchor and localPos and opts.MaxFillDistance and opts.MaxFillDistance > 0 then
                inRange = Distance2D(localPos, anchor) <= opts.MaxFillDistance
            end
            if inRange then
                localUsed[id] = true
                table.insert(taken, entry.Unit)
            end
        end
    end

    return taken, localUsed
end

local function EnsureTask(state, taskKey, role, now)
    state.Tasks = state.Tasks or {}
    state.NextTaskId = state.NextTaskId or 1
    local task = state.Tasks[taskKey]
    if not task then
        task = {
            TaskId = string.format('fd-%d', state.NextTaskId),
            Role = role,
            CreatedAt = now,
            LastActiveAt = now,
            Status = 'new',
        }
        state.NextTaskId = state.NextTaskId + 1
        state.Tasks[taskKey] = task
    end
    return task
end

local function UpdateTask(state, taskKey, spec, now)
    local task = EnsureTask(state, taskKey, spec.Role, now)
    task.Role = spec.Role
    task.Priority = spec.Priority or 0
    task.AnchorPos = CopyPos(spec.AnchorPos)
    task.TargetPos = CopyPos(spec.TargetPos)
    task.StagingPos = CopyPos(spec.StagingPos or spec.AnchorPos or spec.TargetPos)
    task.AssignedUnits = BuildAssignedIds(spec.AssignedUnits or {})
    task.AssignedUnitRefs = spec.AssignedUnits or {}
    task.DesiredUnits = math.max(0, math.floor((spec.DesiredUnits or 0) + 0.5))
    task.CurrentUnits = CountUnits(spec.AssignedUnits or {})
    task.DesiredStrength = Round(spec.DesiredStrength or 0, 2)
    task.CurrentStrength = OvermindRoleWeights.SumUnitStrength(spec.AssignedUnits or {})
    task.Timeout = spec.Timeout or 45
    task.Objective = spec.Objective or task.Objective or spec.Role
    task.RouteName = spec.RouteName or task.RouteName or 'local'
    task.HoldRadius = spec.HoldRadius or task.HoldRadius or 22
    task.CommitRadius = spec.CommitRadius or task.CommitRadius or 40
    task.RetreatRadius = spec.RetreatRadius or task.RetreatRadius or 20
    task.Persistent = spec.Persistent ~= false
    task.TaskGroup = spec.TaskGroup or taskKey
    task.ExecutionState = task.ExecutionState or ((task.CurrentStrength > 0) and 'forming' or 'idle')
    if task.CurrentStrength <= 0 then
        task.Status = spec.EmptyStatus or 'waiting'
        task.ExecutionState = 'idle'
    else
        local readyRatio = task.CurrentStrength / math.max(1, task.DesiredStrength or 1)
        if readyRatio < 0.6 and (task.DesiredStrength or 0) > 0 then
            task.Status = 'forming'
            if task.ExecutionState == 'idle' or task.ExecutionState == 'complete' then
                task.ExecutionState = 'forming'
            end
        else
            task.Status = spec.Status or 'active'
        end
    end
    if task.CurrentStrength > 0 then
        task.LastActiveAt = now
    end
    return task
end

function Module.Update(aiBrain, now)
    local runtime = aiBrain.OvermindRuntime or {}
    aiBrain.OvermindRuntime = runtime
    runtime.ForceDirector = runtime.ForceDirector or runtime.ForceManager or {
        Assignments = {},
        Groups = {},
        Stats = {},
        RoleDemand = {},
        Tasks = {},
        NextTaskId = 1,
        LastLogTime = -999,
    }
    runtime.ForceManager = runtime.ForceDirector

    local state = runtime.ForceDirector
    local previousTasks = state.Tasks or {}
    local intel = runtime.IntelModel or {}
    local raid = runtime.RaidDefense or {}
    local opp = runtime.OpponentModel or {}
    local ownPos = GetMainPos(aiBrain, runtime)
    local frontPos = intel.FrontLinePos or runtime.PrimaryEnemyPos or ownPos
    local raidPos = intel.BestRaidPos or runtime.PrimaryEnemyPos or frontPos
    local acu = GetACU(aiBrain)
    local acuPos = acu and acu:GetPosition() or ownPos
    local homeThreat = (runtime.ZoneModel and runtime.ZoneModel.HomeThreat) or 0
    local localAcuThreat = aiBrain:GetThreatAtPosition(acuPos, 2, true, 'AntiSurface') or 0

    local direct = aiBrain:GetListOfUnits(LandDirectCategory, false, true) or {}
    local aa = aiBrain:GetListOfUnits(LandAACategory, false, true) or {}
    local indirect = aiBrain:GetListOfUnits(LandIndirectCategory, false, true) or {}
    local scouts = aiBrain:GetListOfUnits(LandScoutCategory, false, true) or {}
    local fighters = aiBrain:GetListOfUnits(AirFighterCategory, false, true) or {}
    local bombers = aiBrain:GetListOfUnits(AirBomberCategory, false, true) or {}
    local airScouts = aiBrain:GetListOfUnits(AirScoutCategory, false, true) or {}
    local directStrength = OvermindRoleWeights.AverageUnitStrength(direct, 'LandDirect')
    local aaStrength = OvermindRoleWeights.AverageUnitStrength(aa, 'LandAA')
    local indirectStrength = OvermindRoleWeights.AverageUnitStrength(indirect, 'LandIndirect')
    local scoutStrength = OvermindRoleWeights.AverageUnitStrength(scouts, 'LandScout')
    local fighterStrength = OvermindRoleWeights.AverageUnitStrength(fighters, 'AirFighter')
    local bomberStrength = OvermindRoleWeights.AverageUnitStrength(bombers, 'AirBomber')
    local airScoutStrength = OvermindRoleWeights.AverageUnitStrength(airScouts, 'AirScout')

    local used = {}
    local landCombatTotal = table.getn(direct) + table.getn(aa) + table.getn(indirect) + table.getn(scouts)
    local contestedZones = intel.ContestedZones or 0
    local airThreatZones = intel.AirThreatZones or 0
    local staleZones = intel.StaleZones or 0
    local acuDist = Distance2D(acuPos, ownPos)
    local clusterState = runtime.EnemyClusterTracker or {}
    local approachCluster = clusterState.ApproachCluster or {}
    local approachThreat = approachCluster.TotalThreat or 0
    local approachDistance = approachCluster.HomeDistance or 999
    local approachAir = approachCluster.EnemyAir or 0
    local approachConfidence = approachCluster.ContactConfidence or 0
    local approachConfirmed = (approachCluster.ConfirmedUnits or 0) > 0
        or (approachCluster.MemoryThreat or 0) >= 1.25
        or approachConfidence >= 0.46
    local approachClose = approachConfirmed and approachDistance < 260 and approachThreat >= 4.5
    local assetSiege = raid.UnderLandHarass
        and ((raid.LastThreatLabel == 'asset') or (raid.LastThreatLabel == 'acu') or (raid.LastThreatLabel == 'main'))
        and ((raid.LastLandEnemyCount or 0) >= 4)
    local frontCrisis = (opp.T2Push == true or opp.IndirectHeavy == true or assetSiege)
        and (approachClose or contestedZones >= 2 or approachThreat >= 5.5 or assetSiege)
    local interceptPos = approachCluster.StagePos or approachCluster.Pos or frontPos

    local baseGuardDirectNeed = Clamp(4 + math.floor(homeThreat / 2) + contestedZones, 4, 12)
    local baseGuardAANeed = Clamp(1 + math.min(2, airThreatZones) + (raid.UnderAirHarass and 2 or 0), 1, 6)
    local acuEscortNeed = 0
    if acuDist > 8 or localAcuThreat > (homeThreat + 1) or runtime.ACURole == 'push' then
        acuEscortNeed = Clamp(2 + math.floor(acuDist / 12) + ((localAcuThreat > 2) and 2 or 0), 2, 8)
    end
    local raiderNeed = 0
    if raidPos and (intel.BestRaidZoneKey or false) then
        raiderNeed = Clamp(2 + math.floor(staleZones / 2) + math.min(3, table.getn(scouts)), 2, 8)
    end
    local mainlineNeed = Clamp(8 + (contestedZones * 4), 8, 34)
    local airGuardNeed = Clamp(2 + (airThreatZones * 2) + (raid.UnderAirHarass and 2 or 0), 2, 10)
    if approachClose then
        baseGuardDirectNeed = Clamp(baseGuardDirectNeed + math.max(1, math.min(5, math.floor(approachThreat * 0.28))), 4, 16)
        mainlineNeed = Clamp(mainlineNeed + math.max(1, math.min(6, math.floor(approachThreat * 0.32))), 8, 40)
        if approachAir > 0 then
            baseGuardAANeed = Clamp(baseGuardAANeed + math.max(1, math.min(2, approachAir)), 1, 7)
            airGuardNeed = Clamp(airGuardNeed + math.max(1, math.min(3, approachAir)), 2, 12)
        end
    end
    if frontCrisis then
        mainlineNeed = Clamp(mainlineNeed + 6, 10, 42)
        raiderNeed = 0
        if not raid.UnderLandHarass and not raid.UnderAirHarass then
            baseGuardDirectNeed = Clamp(baseGuardDirectNeed - 1, 4, 10)
        end
    end
    if assetSiege then
        mainlineNeed = Clamp(mainlineNeed + 6, 10, 42)
        raiderNeed = 0
    end
    local interceptDirectNeed = 0
    local interceptAANeed = 0
    if approachConfirmed and approachDistance < 320 and approachThreat >= 4 then
        interceptDirectNeed = Clamp(3 + math.floor(approachThreat * 0.28) + ((approachDistance < 190) and 1 or 0), 3, 11)
        if approachAir > 0 then
            interceptAANeed = Clamp(1 + math.min(3, approachAir), 1, 4)
        end
    end
    local interceptNeed = interceptDirectNeed + interceptAANeed
    local splitLandBudget = landCombatTotal - baseGuardDirectNeed - baseGuardAANeed - acuEscortNeed
    if (frontCrisis or assetSiege) and splitLandBudget < 20 then
        interceptDirectNeed = 0
        interceptAANeed = 0
        interceptNeed = 0
    elseif (frontCrisis or assetSiege) and interceptNeed > 0 then
        interceptDirectNeed = math.min(interceptDirectNeed, math.max(1, math.floor(math.max(0, splitLandBudget) * 0.18)))
        interceptAANeed = math.min(interceptAANeed, 1)
        interceptNeed = interceptDirectNeed + interceptAANeed
    end
    local escortDirectNeed = 0
    local raiderScoutNeed = 0
    if acuEscortNeed > 0 then
        escortDirectNeed = Clamp(math.ceil(acuEscortNeed * 0.65), 1, acuEscortNeed)
    end
    if raiderNeed > 0 then
        raiderScoutNeed = math.min(table.getn(scouts), math.max(1, math.floor(raiderNeed * 0.5)))
    end
    local minimumMainlineCommit = 0
    if landCombatTotal >= 4 then
        minimumMainlineCommit = Clamp(
            math.floor(landCombatTotal * ((frontCrisis or assetSiege) and 0.52 or ((approachClose or contestedZones >= 2) and 0.4 or 0.3)))
                + (frontCrisis and 2 or 0)
                + (assetSiege and 2 or 0)
                + (approachClose and 1 or 0),
            3,
            math.max(3, landCombatTotal - 1))
    end
    if minimumMainlineCommit > 0 then
        local maxGuardTotal = landCombatTotal - acuEscortNeed - interceptNeed - minimumMainlineCommit
        if maxGuardTotal < 0 then
            maxGuardTotal = 0
        end
        local currentGuardNeed = baseGuardDirectNeed + baseGuardAANeed
        if currentGuardNeed > maxGuardTotal then
            local overflow = currentGuardNeed - maxGuardTotal
            local reducibleDirect = math.max(0, baseGuardDirectNeed - 2)
            local directCut = math.min(reducibleDirect, overflow)
            baseGuardDirectNeed = baseGuardDirectNeed - directCut
            overflow = overflow - directCut
            if overflow > 0 then
                local reducibleAA = math.max(0, baseGuardAANeed - 1)
                local aaCut = math.min(reducibleAA, overflow)
                baseGuardAANeed = baseGuardAANeed - aaCut
            end
        end
    end

    local baseGuardDirect
    baseGuardDirect, used = TakeTaskUnits(
        direct,
        ownPos,
        math.min(baseGuardDirectNeed, table.getn(direct)),
        used,
        previousTasks.base_guard,
        { MaxRetainDistance = 95, MaxFillDistance = 110 })
    local baseGuardAA
    baseGuardAA, used = TakeTaskUnits(
        aa,
        ownPos,
        math.min(baseGuardAANeed, table.getn(aa)),
        used,
        previousTasks.base_guard,
        { MaxRetainDistance = 110, MaxFillDistance = 125 })

    local acuEscortDirect = {}
    local acuEscortAA = {}
    if acuEscortNeed > 0 then
        acuEscortDirect, used = TakeTaskUnits(
            direct,
            acuPos,
            escortDirectNeed,
            used,
            previousTasks.acu_escort,
            { MaxRetainDistance = 72, MaxFillDistance = 88 })
        acuEscortAA, used = TakeTaskUnits(
            aa,
            acuPos,
            acuEscortNeed - table.getn(acuEscortDirect),
            used,
            previousTasks.acu_escort,
            { MaxRetainDistance = 80, MaxFillDistance = 92 })
    end

    local interceptDirect = {}
    local interceptAA = {}
    if interceptNeed > 0 then
        interceptDirect, used = TakeTaskUnits(
            direct,
            interceptPos,
            interceptDirectNeed,
            used,
            previousTasks.intercept_cluster,
            { MaxRetainDistance = 150, MaxFillDistance = 220 })
        interceptAA, used = TakeTaskUnits(
            aa,
            interceptPos,
            interceptAANeed,
            used,
            previousTasks.intercept_cluster,
            { MaxRetainDistance = 160, MaxFillDistance = 230 })
    end

    local artillery = {}
    artillery, used = TakeTaskUnits(
        indirect,
        frontPos,
        table.getn(indirect),
        used,
        previousTasks.artillery_support,
        { MaxRetainDistance = 170, MaxFillDistance = 220 })

    local raiderScouts = {}
    if raiderNeed > 0 then
        raiderScouts, used = TakeTaskUnits(
            scouts,
            raidPos,
            raiderScoutNeed,
            used,
            previousTasks.raid,
            { MaxRetainDistance = 170, MaxFillDistance = 210 })
    end

    local remainingDirect = CollectUnassigned(direct, used)
    local raiderDirect = {}
    if raiderNeed > CountUnits(raiderScouts) then
        raiderDirect, used = TakeTaskUnits(
            remainingDirect,
            raidPos,
            raiderNeed - CountUnits(raiderScouts),
            used,
            previousTasks.raid,
            { MaxRetainDistance = 185, MaxFillDistance = 230 })
    end

    local mainline = MergeLists(
        CollectUnassigned(direct, used),
        CollectUnassigned(aa, used),
        {}
    )
    local reserveScouts = CollectUnassigned(scouts, used)
    for _, scout in reserveScouts do
        table.insert(mainline, scout)
    end
    local function ShiftReserveUnits(source, destination, keepCount, moveCount)
        local moved = 0
        while moved < moveCount and table.getn(source) > keepCount do
            table.insert(destination, table.remove(source, table.getn(source)))
            moved = moved + 1
        end
        return moved
    end
    if (frontCrisis or assetSiege or approachClose) and minimumMainlineCommit > 0 then
        local shortage = minimumMainlineCommit - CountUnits(mainline)
        if shortage > 0 then
            local keepDirect = Clamp(2 + (raid.UnderLandHarass and 1 or 0) + ((homeThreat >= 4) and 1 or 0), 2, 6)
            shortage = shortage - ShiftReserveUnits(baseGuardDirect, mainline, keepDirect, shortage)
        end
        if shortage > 0 and not raid.UnderAirHarass then
            local keepAA = Clamp(1 + ((airThreatZones > 0) and 1 or 0), 1, 3)
            shortage = shortage - ShiftReserveUnits(baseGuardAA, mainline, keepAA, shortage)
        end
    end

    local airGuard = {}
    airGuard, used = TakeTaskUnits(
        fighters,
        ownPos,
        math.min(airGuardNeed, table.getn(fighters)),
        used,
        previousTasks.air_guard,
        { MaxRetainDistance = 155, MaxFillDistance = 190 })
    local bomberStrike = {}
    bomberStrike, used = TakeTaskUnits(
        bombers,
        ownPos,
        table.getn(bombers),
        used,
        previousTasks.bomber_strike,
        { MaxRetainDistance = 280, MaxFillDistance = 340 })
    local airScoutGroup = {}
    airScoutGroup, used = TakeTaskUnits(
        airScouts,
        ownPos,
        table.getn(airScouts),
        used,
        previousTasks.scout_screen,
        { MaxRetainDistance = 320, MaxFillDistance = 380 })

    local baseGuard = MergeLists(baseGuardDirect, baseGuardAA, {})
    local acuEscort = MergeLists(acuEscortDirect, acuEscortAA, {})
    local interceptUnits = MergeLists(interceptDirect, interceptAA, {})
    local raiders = MergeLists(raiderDirect, raiderScouts, {})

    state.Groups = {
        BaseGuard = baseGuard,
        ACUEscort = acuEscort,
        Intercept = interceptUnits,
        Raiders = raiders,
        Artillery = artillery,
        MainLine = mainline,
        AirGuard = airGuard,
        BomberStrike = bomberStrike,
        AirScout = airScoutGroup,
    }
    state.TaskGroups = {
        base_guard = baseGuard,
        acu_escort = acuEscort,
        intercept_cluster = interceptUnits,
        raid = raiders,
        artillery_support = artillery,
        front_hold = mainline,
        air_guard = airGuard,
        bomber_strike = bomberStrike,
        scout_screen = airScoutGroup,
    }

    local assignments = {}
    local function Tag(list, role)
        for _, unit in list do
            local id = GetEntityId(unit)
            if id then
                assignments[id] = role
            end
        end
    end
    Tag(baseGuard, 'base_guard')
    Tag(acuEscort, 'acu_escort')
    Tag(interceptUnits, 'intercept_cluster')
    Tag(raiders, 'raider')
    Tag(artillery, 'artillery')
    Tag(mainline, 'mainline')
    Tag(airGuard, 'air_guard')
    Tag(bomberStrike, 'bomber_strike')
    Tag(airScoutGroup, 'air_scout')
    state.Assignments = assignments

    state.Stats = {
        LandCombat = landCombatTotal,
        BaseGuard = CountUnits(baseGuard),
        ACUEscort = CountUnits(acuEscort),
        Intercept = CountUnits(interceptUnits),
        Raiders = CountUnits(raiders),
        Artillery = CountUnits(artillery),
        MainLine = CountUnits(mainline),
        AirGuard = CountUnits(airGuard),
        BomberStrike = CountUnits(bomberStrike),
        AirScout = CountUnits(airScoutGroup),
    }

    state.RoleDemand = {
    }
    local baseGuardDesiredStrength = Round((baseGuardDirectNeed * directStrength) + (baseGuardAANeed * aaStrength), 2)
    local acuEscortDesiredStrength = Round((escortDirectNeed * directStrength) + (math.max(0, acuEscortNeed - escortDirectNeed) * aaStrength), 2)
    local interceptDesiredStrength = Round((interceptDirectNeed * directStrength) + (interceptAANeed * aaStrength), 2)
    local raidDesiredStrength = Round((math.max(0, raiderNeed - raiderScoutNeed) * directStrength) + (raiderScoutNeed * scoutStrength), 2)
    local mainlineDesiredStrength = Round(mainlineNeed * WeightedMean({
        { directStrength, 0.62 },
        { aaStrength, 0.24 },
        { scoutStrength, 0.14 },
    }, directStrength), 2)
    local airGuardDesiredStrength = Round(airGuardNeed * fighterStrength, 2)
    local bomberStrikeNeed = raidPos and 2 or 0
    if (opp.CounterAirWindow == true) and (approachThreat >= 5 or contestedZones >= 2) then
        bomberStrikeNeed = math.max(bomberStrikeNeed, math.min(4, 2 + math.floor((approachThreat or 0) * 0.18)))
    end
    local bomberStrikeDesiredStrength = Round(bomberStrikeNeed * bomberStrength, 2)
    local scoutScreenDesiredStrength = Round(math.max(1, math.min(4, 1 + math.floor((intel.StaleZones or 0) / 2))) * airScoutStrength, 2)

    UpdateTask(state, 'base_guard', {
        Role = 'base_guard',
        Priority = 80 + math.floor(homeThreat * 4),
        AnchorPos = ownPos,
        TargetPos = ownPos,
        StagingPos = ownPos,
        AssignedUnits = baseGuard,
        DesiredUnits = baseGuardDirectNeed + baseGuardAANeed,
        DesiredStrength = baseGuardDesiredStrength,
        Timeout = 60,
        Objective = 'hold_home',
        RouteName = 'rear',
        HoldRadius = 28,
        CommitRadius = 42,
        RetreatRadius = 18,
        EmptyStatus = 'reinforce',
    }, now)
    UpdateTask(state, 'acu_escort', {
        Role = 'acu_escort',
        Priority = 90 + math.floor(localAcuThreat * 5) + ((runtime.ACURole == 'push') and 6 or 0),
        AnchorPos = acuPos,
        TargetPos = acuPos,
        StagingPos = acuPos,
        AssignedUnits = acuEscort,
        DesiredUnits = acuEscortNeed,
        DesiredStrength = acuEscortDesiredStrength,
        Timeout = 45,
        Objective = 'escort_acu',
        RouteName = 'acu',
        HoldRadius = 20,
        CommitRadius = 30,
        RetreatRadius = 14,
        EmptyStatus = 'standby',
    }, now)
    UpdateTask(state, 'intercept_cluster', {
        Role = 'intercept_cluster',
        Priority = approachClose and (84 + math.floor(approachThreat * 2)) or 18,
        AnchorPos = ownPos,
        TargetPos = approachCluster.Pos or interceptPos,
        StagingPos = interceptPos,
        AssignedUnits = interceptUnits,
        DesiredUnits = interceptNeed,
        DesiredStrength = interceptDesiredStrength,
        Timeout = 34,
        Objective = 'intercept_approach',
        RouteName = 'intercept',
        HoldRadius = 24,
        CommitRadius = 44,
        RetreatRadius = 16,
        EmptyStatus = 'reserve',
    }, now)
    UpdateTask(state, 'raid', {
        Role = 'raid',
        Priority = 50 + math.floor((intel.StaleZones or 0) * 4) + ((intel.BestRaidZoneKey and 1 or 0) * 10),
        AnchorPos = ownPos,
        TargetPos = raidPos,
        StagingPos = intel.RaidStagePos or frontPos or ownPos,
        AssignedUnits = raiders,
        DesiredUnits = raiderNeed,
        DesiredStrength = raidDesiredStrength,
        Timeout = 70,
        Objective = 'raid_mex_lane',
        RouteName = 'raid',
        HoldRadius = 18,
        CommitRadius = 40,
        RetreatRadius = 16,
        EmptyStatus = 'queued',
    }, now)
    UpdateTask(state, 'artillery_support', {
        Role = 'artillery_support',
        Priority = 56 + math.floor(contestedZones * 3),
        AnchorPos = frontPos,
        TargetPos = frontPos,
        StagingPos = intel.FrontStagePos or frontPos or ownPos,
        AssignedUnits = artillery,
        DesiredUnits = CountUnits(artillery),
        DesiredStrength = OvermindRoleWeights.SumUnitStrength(artillery),
        Timeout = 55,
        Objective = 'support_front',
        RouteName = 'front',
        HoldRadius = 32,
        CommitRadius = 52,
        RetreatRadius = 24,
        EmptyStatus = 'reserve',
    }, now)
    UpdateTask(state, 'front_hold', {
        Role = 'front_hold',
        Priority = 72 + (contestedZones * 6),
        AnchorPos = frontPos,
        TargetPos = frontPos,
        StagingPos = intel.FrontStagePos or frontPos or ownPos,
        AssignedUnits = mainline,
        DesiredUnits = mainlineNeed,
        DesiredStrength = mainlineDesiredStrength,
        Timeout = 60,
        Objective = 'hold_or_push_front',
        RouteName = 'front',
        HoldRadius = 28,
        CommitRadius = 44,
        RetreatRadius = 18,
        EmptyStatus = 'reinforce',
    }, now)
    UpdateTask(state, 'air_guard', {
        Role = 'air_guard',
        Priority = 68 + (airThreatZones * 6) + (raid.UnderAirHarass and 8 or 0),
        AnchorPos = ownPos,
        TargetPos = frontPos,
        StagingPos = ownPos,
        AssignedUnits = airGuard,
        DesiredUnits = airGuardNeed,
        DesiredStrength = airGuardDesiredStrength,
        Timeout = 45,
        Objective = 'screen_air_threats',
        RouteName = 'rear',
        HoldRadius = 36,
        CommitRadius = 64,
        RetreatRadius = 20,
        EmptyStatus = 'scramble',
    }, now)
    UpdateTask(state, 'bomber_strike', {
        Role = 'bomber_strike',
        Priority = 42 + ((raidPos and 1 or 0) * 10),
        AnchorPos = ownPos,
        TargetPos = raidPos,
        StagingPos = ownPos,
        AssignedUnits = bomberStrike,
        DesiredUnits = bomberStrikeNeed,
        DesiredStrength = bomberStrikeDesiredStrength,
        Timeout = 40,
        Objective = 'strike_raid_targets',
        RouteName = 'raid',
        HoldRadius = 22,
        CommitRadius = 60,
        RetreatRadius = 20,
        EmptyStatus = 'hold',
    }, now)
    UpdateTask(state, 'scout_screen', {
        Role = 'scout_screen',
        Priority = 36 + math.floor((intel.StaleZones or 0) * 3),
        AnchorPos = ownPos,
        TargetPos = intel.BestScoutPos or frontPos,
        StagingPos = ownPos,
        AssignedUnits = airScoutGroup,
        DesiredUnits = math.max(1, math.min(4, 1 + math.floor((intel.StaleZones or 0) / 2))),
        DesiredStrength = scoutScreenDesiredStrength,
        Timeout = 30,
        Objective = 'refresh_graph_intel',
        RouteName = 'front',
        HoldRadius = 18,
        CommitRadius = 48,
        RetreatRadius = 12,
        EmptyStatus = 'queued',
    }, now)
    local function TaskGap(task)
        if not task then
            return 0
        end
        return math.max(0, (task.DesiredStrength or 0) - (task.CurrentStrength or 0))
    end
    state.RoleDemand = {
        BaseGuard = TaskGap(state.Tasks.base_guard),
        ACUEscort = TaskGap(state.Tasks.acu_escort),
        Intercept = TaskGap(state.Tasks.intercept_cluster),
        Raider = TaskGap(state.Tasks.raid),
        MainLine = TaskGap(state.Tasks.front_hold),
        AirGuard = TaskGap(state.Tasks.air_guard),
        BomberStrike = TaskGap(state.Tasks.bomber_strike),
    }
    state.TaskList = {
        state.Tasks.base_guard,
        state.Tasks.acu_escort,
        state.Tasks.intercept_cluster,
        state.Tasks.raid,
        state.Tasks.artillery_support,
        state.Tasks.front_hold,
        state.Tasks.air_guard,
        state.Tasks.bomber_strike,
        state.Tasks.scout_screen,
    }
    state.TaskExecution = state.TaskExecution or {}
    state.UnitTaskById = assignments
    state.LastUpdate = now

    if now - (state.LastLogTime or -999) >= 30 then
        state.LastLogTime = now
        LOG(string.format('*OVERMIND FORCE A%d t=%.1f land=%d guard=%d acu=%d int=%d raid=%d art=%d main=%d air=%d bomb=%d stale=%d front=%d tasks=%d taskState=%s/%s/%s/%s',
            aiBrain:GetArmyIndex(),
            now,
            landCombatTotal,
            state.Stats.BaseGuard or 0,
            state.Stats.ACUEscort or 0,
            state.Stats.Intercept or 0,
            state.Stats.Raiders or 0,
            state.Stats.Artillery or 0,
            state.Stats.MainLine or 0,
            state.Stats.AirGuard or 0,
            state.Stats.BomberStrike or 0,
            staleZones,
            contestedZones,
            table.getn(state.TaskList or {}),
            (state.Tasks.front_hold and state.Tasks.front_hold.ExecutionState) or 'none',
            (state.Tasks.base_guard and state.Tasks.base_guard.ExecutionState) or 'none',
            (state.Tasks.intercept_cluster and state.Tasks.intercept_cluster.ExecutionState) or 'none',
            (state.Tasks.raid and state.Tasks.raid.ExecutionState) or 'none'))
    end
end

function Update(aiBrain, now)
    return Module.Update(aiBrain, now)
end

return Module
