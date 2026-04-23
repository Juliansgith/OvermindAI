local M = {}

local function Clamp(v, minV, maxV)
    if v < minV then
        return minV
    end
    if v > maxV then
        return maxV
    end
    return v
end

local function TableCount(t)
    return t and table.getn(t) or 0
end

local function Distance2D(a, b)
    local dx = (a[1] or 0) - (b[1] or 0)
    local dz = (a[3] or 0) - (b[3] or 0)
    return math.sqrt((dx * dx) + (dz * dz))
end

local function IsCivilianArmyName(name)
    if not name or name == 'NEUTRAL_CIVILIAN' then
        return true
    end
    if ScenarioInfo and ScenarioInfo.ArmySetup and ScenarioInfo.ArmySetup[name] then
        local personality = string.lower(ScenarioInfo.ArmySetup[name].AIPersonality or '')
        if string.find(personality, 'civilian') ~= nil then
            return true
        end
    end
    return false
end

local function CountActivePlayerBrains()
    local count = 0
    if not ArmyBrains then
        return 2
    end

    for _, brain in ArmyBrains do
        if brain and not IsCivilianArmyName(brain.Name) then
            count = count + 1
        end
    end

    return math.max(2, count)
end

local function ComputeContestMapStructure(aiBrain, runtime)
    runtime = runtime or {}
    local graph = runtime.ZoneGraph or {}
    local zone = runtime.ZoneModel or {}
    local nodes = graph.Nodes or {}
    local navMarkerCount = zone.NavMarkerCount or graph.WaterZones or 0
    local ownPos = graph.OwnMainPos or zone.OwnMainPos
    if not ownPos and aiBrain and aiBrain.GetArmyStartPos then
        local sx, sz = aiBrain:GetArmyStartPos()
        ownPos = { sx, 0, sz }
    end
    local enemyPos = graph.EnemyMainPos or runtime.PrimaryEnemyPos or false
    local metrics = {
        NavMarkerCount = navMarkerCount or 0,
        TotalLandZones = 0,
        TotalMass = 0,
        OuterMass = 0,
        ForwardOwnedMass = 0,
        OuterMexShare = 0,
        StartZoneMexShare = 0,
        OuterHoldShare = 0,
        SafeForwardMexCount = 0,
        ContestableZoneCount = 0,
        LandRouteDepth = 0,
        FrontSecure = false,
        StructuralContestMap = false,
        PlayerCount = CountActivePlayerBrains(),
        DirectEnemyDistance = (ownPos and enemyPos) and Distance2D(ownPos, enemyPos) or 999,
        FocusOnT1SpamRaw = false,
        FocusOnT1Spam = false,
    }

    if navMarkerCount >= 3 then
        return metrics
    end

    local depthTotal = 0
    local depthCount = 0
    for _, node in nodes do
        if node and node.Medium == 'land' then
            metrics.TotalLandZones = metrics.TotalLandZones + 1

            local class = node.Classification or 'rear'
            local massCount = node.MassCount or 0
            local expansionCount = node.ExpansionCount or 0
            local enemyMex = node.EnemyMex or 0
            local threat = node.Threat or 0
            local routeRisk = node.RouteRisk or 0
            local friendlyLand = node.FriendlyLand or 0
            local enemyLand = node.EnemyLand or 0
            local friendlyStructures = node.FriendlyStructures or 0
            local enemyStructures = node.EnemyStructures or 0
            local hopHome = node.HopHome or 999
            local outsideHome = class == 'front' or class == 'contested' or class == 'enemy_side'
            local contestable = outsideHome and ((massCount + expansionCount + enemyMex) > 0)
            local safeForward = (class == 'front' or class == 'contested')
                and (massCount > 0 or enemyMex > 0)
                and routeRisk <= 3.6
                and threat <= 2.6
                and enemyStructures <= 2
            local heldForward = outsideHome
                and class ~= 'enemy_side'
                and (
                    (class == 'front' and (friendlyLand >= enemyLand or (enemyLand <= 0 and friendlyStructures >= 1)))
                    or (class == 'contested' and friendlyLand >= math.max(1, enemyLand) and routeRisk <= 3.2 and threat <= 2.2 and enemyStructures <= 1)
                )

            metrics.TotalMass = metrics.TotalMass + massCount
            if outsideHome then
                metrics.OuterMass = metrics.OuterMass + massCount
            end
            if heldForward then
                metrics.ForwardOwnedMass = metrics.ForwardOwnedMass + math.max(1, massCount)
            end
            if contestable then
                metrics.ContestableZoneCount = metrics.ContestableZoneCount + 1
            end
            if safeForward then
                metrics.SafeForwardMexCount = metrics.SafeForwardMexCount + math.max(1, massCount)
            end
            if class == 'front' or class == 'contested' then
                depthTotal = depthTotal + math.min(6, hopHome)
                depthCount = depthCount + 1
            end
        end
    end

    metrics.OuterMexShare = (metrics.TotalMass > 0) and (metrics.OuterMass / metrics.TotalMass) or 0
    metrics.OuterHoldShare = (metrics.OuterMass > 0) and (metrics.ForwardOwnedMass / metrics.OuterMass) or 0
    metrics.LandRouteDepth = (depthCount > 0) and (depthTotal / depthCount) or 0
    metrics.FrontSecure =
        metrics.OuterMass <= 0
        or (
            metrics.OuterHoldShare >= 0.52
            and (metrics.SafeForwardMexCount >= 2 or metrics.ContestableZoneCount <= 2)
        )
    metrics.StructuralContestMap =
        metrics.TotalLandZones >= 6 and (
            metrics.OuterMexShare >= 0.36
            or metrics.SafeForwardMexCount >= 4
            or (metrics.ContestableZoneCount >= 3 and metrics.LandRouteDepth >= 1.7)
        )

    local mexPercentThreshold = 0.45
    if metrics.TotalMass > 80 or metrics.PlayerCount >= 4 then
        if metrics.TotalMass > 130 then
            mexPercentThreshold = 0.30
        else
            mexPercentThreshold = 0.375
        end
    end
    local outsideStartThreshold = 1 - mexPercentThreshold
    local smallMapLike = metrics.TotalLandZones <= 16
        or metrics.DirectEnemyDistance <= 1100
        or metrics.LandRouteDepth <= 2.6
    metrics.StartZoneMexShare = (metrics.TotalMass > 0) and Clamp(1 - metrics.OuterMexShare, 0, 1) or 0
    metrics.FocusOnT1SpamRaw =
        metrics.StructuralContestMap
        and metrics.PlayerCount <= 4
        and metrics.TotalMass > 0
        and metrics.TotalMass < 150
        and smallMapLike
        and metrics.OuterMexShare >= outsideStartThreshold
        and (metrics.SafeForwardMexCount >= 2 or metrics.ContestableZoneCount >= 2)
    metrics.FocusOnT1Spam = metrics.FocusOnT1SpamRaw and true or false

    return metrics
end

local function UpdateHistory(state, now, eco, ledger, structure)
    state.History = state.History or {}
    local history = state.History
    local last = history.Last or {}
    local dt = math.max(1, now - (last.Time or now))
    local mapMassHeld = (structure.ForwardOwnedMass or 0)
    local mem = state.MemorySnapshot or {}

    local massIncome = eco.MassIncome or 0
    local energyIncome = eco.EnergyIncome or 0
    local reclaimRecent = mem.ReclaimMassRecent or 0
    local aggregate = ledger.Aggregate or {}
    local factoryBusy = aggregate.FactoryBusyRatio or 0
    local engineerBusy = aggregate.EngineerBusyRatio or 0

    local velocity = state.Velocity or {}
    velocity.MassIncomeNow = massIncome
    velocity.EnergyIncomeNow = energyIncome
    velocity.MassIncomeTrendShort = (massIncome - (last.MassIncome or massIncome)) / dt
    velocity.EnergyIncomeTrendShort = (energyIncome - (last.EnergyIncome or energyIncome)) / dt
    velocity.MapMassHeld = mapMassHeld
    velocity.MapMassHeldTrend = (mapMassHeld - (last.MapMassHeld or mapMassHeld)) / dt
    velocity.ReclaimRateShort = reclaimRecent / 100
    velocity.FactoryThroughput = factoryBusy
    velocity.EngineerProductivity = engineerBusy
    velocity.SpendSaturation = aggregate.SpendSaturation or 0
    velocity.EcoGrowthRate = Clamp(
        (math.max(0, velocity.MassIncomeTrendShort) * 20)
        + (math.max(0, velocity.MapMassHeldTrend) * 0.9)
        + (velocity.ReclaimRateShort * 0.12)
        + (velocity.SpendSaturation * 0.35),
        0,
        2)

    if velocity.EcoGrowthRate <= 0.08 and (eco.MassIncome or 0) >= 3.5 and now >= 360 then
        velocity.EcoStagnationTime = (velocity.EcoStagnationTime or 0) + dt
    else
        velocity.EcoStagnationTime = 0
    end
    if factoryBusy <= 0.58 and (eco.MassStorageRatio or 0) >= 0.10 and now >= 300 then
        velocity.ProductionStagnationTime = (velocity.ProductionStagnationTime or 0) + dt
    else
        velocity.ProductionStagnationTime = 0
    end
    if reclaimRecent < 80 and (structure.StructuralContestMap or structure.OuterMexShare >= 0.32) and now >= 480 then
        velocity.ReclaimStagnationTime = (velocity.ReclaimStagnationTime or 0) + dt
    else
        velocity.ReclaimStagnationTime = 0
    end

    state.Velocity = velocity
    history.Last = {
        Time = now,
        MassIncome = massIncome,
        EnergyIncome = energyIncome,
        MapMassHeld = mapMassHeld,
    }
    return velocity
end

local function BuildPressure(runtime, now, eco, ledger, structure, velocity)
    local opp = runtime.OpponentModel or {}
    local raid = runtime.RaidDefense or {}
    local recovery = runtime.Recovery or {}
    local constraints = ((runtime.ProductionDirector or {}).ConstraintState) or {}
    local force = runtime.ForceDirector or {}
    local forceStats = force.Stats or {}
    local aggregate = ledger.Aggregate or {}
    local homePressure = constraints.BasePressure
        or ((opp.Theaters and opp.Theaters.Home and opp.Theaters.Home.PressureEMA) or 0)
    local frontPressure = constraints.FrontPressure
        or ((opp.Theaters and opp.Theaters.Front and opp.Theaters.Front.PressureEMA) or 0)
    local acuCrisis = now < (runtime.ACUCrisisUntil or -999)
    local ecoCrash = recovery.EcoCrash == true
        or ((eco.MassStorageRatio or 0) <= 0.01 and (eco.EnergyStorageRatio or 0) <= 0.01)
    local survival = acuCrisis
        or ecoCrash
        or recovery.ForceFactoryRecovery == true
        or recovery.ForceBaseEngineerRecovery == true
        or homePressure >= 7.5

    return {
        LandPressure = frontPressure,
        AirPressure = (raid.UnderAirHarass == true or constraints.AirPanic == true) and 1 or 0,
        NavalPressure = ((opp.Theaters and opp.Theaters.Navy and opp.Theaters.Navy.PressureEMA) or 0),
        HomePressure = homePressure,
        OuterPressure = math.max(0, frontPressure - homePressure * 0.55),
        ReclaimOpportunity = ((runtime.StrategicPlanner or {}).ReclaimFieldScore or 0) / 180,
        MapContestPressure = structure.StructuralContestMap and Clamp((structure.OuterMexShare or 0) + ((structure.ContestableZoneCount or 0) * 0.08), 0, 1.4) or 0,
        ProductionPressure = 1 - (aggregate.FactoryBusyRatio or 0),
        UpgradePressure = ((ledger.Upgrade or {}).ActiveMexUpgrades or 0) <= 0 and 1 or 0,
        EnergyPressure = (eco.EnergyStorageRatio or 0) < 0.08 and 1 or 0,
        MassPressure = (eco.MassStorageRatio or 0) < 0.06 and 1 or 0,
        SurvivalCrisis = survival and true or false,
        ACUCrisis = acuCrisis and true or false,
        ApproachFailurePressure = Clamp(
            ((velocity.EcoStagnationTime or 0) / 220)
            + ((velocity.ReclaimStagnationTime or 0) / 280)
            + (((forceStats.OuterContest or 0) <= 0 and structure.StructuralContestMap) and 0.18 or 0),
            0,
            1.25),
    }
end

local function BuildPolicySeed(runtime, now, eco, opp, recovery, structure, velocity, pressure)
    local intel = runtime.IntelModel or {}
    local graph = runtime.ZoneGraph or {}
    local zone = runtime.ZoneModel or {}
    local contestedZones = intel.ContestedZones or graph.ContestedZones or 0
    local zoneCount = TableCount(graph.Nodes or {})
    local mapControl = intel.MapControl or graph.MapControl or zone.MapControl or 0
    local navMarkerCount = structure.NavMarkerCount or zone.NavMarkerCount or graph.WaterZones or 0
    local landContestMap = structure.StructuralContestMap or (navMarkerCount < 3 and zoneCount >= 6)
    local stableTempoEco = (eco.MassIncome or 0) >= 3.6
        and (eco.EnergyIncome or 0) >= 50
        and (eco.MassTrend or 0) >= -0.08
        and (eco.EnergyTrend or 0) >= -4
    local focusOnT1Spam = structure.FocusOnT1Spam == true
    if focusOnT1Spam and (pressure.ApproachFailurePressure or 0) >= 0.82 and now >= 900 then
        focusOnT1Spam = false
        structure.FocusOnT1Spam = false
        structure.T1SpamSuppressedByFailure = true
    end

    local contestMapMode = landContestMap
        and (contestedZones >= 2 or structure.ContestableZoneCount >= 3)
        and now >= 150
        and now <= 1200
        and not pressure.SurvivalCrisis
    if focusOnT1Spam then
        contestMapMode = true
    end

    local productionFirst = (contestMapMode or focusOnT1Spam)
        and stableTempoEco
        and mapControl <= 0.68
        and (opp.RelativePower or 1) <= 1.10

    return {
        ContestMapMode = contestMapMode and true or false,
        PrioritizeProduction = productionFirst and true or false,
        FocusOnT1Spam = focusOnT1Spam and true or false,
        PreferTempoFromSurplus = productionFirst and stableTempoEco and not pressure.SurvivalCrisis,
        StructuralContestMap = structure.StructuralContestMap and true or false,
        PolicyReason = structure.T1SpamSuppressedByFailure and 'approach_failure' or (focusOnT1Spam and 't1_spam') or (contestMapMode and 'contest_map') or 'normal',
    }
end

function M.Update(aiBrain, now)
    local runtime = aiBrain.OvermindRuntime or {}
    aiBrain.OvermindRuntime = runtime
    runtime.EconomySignals = runtime.EconomySignals or {
        LastUpdate = -999,
        History = {},
    }
    local state = runtime.EconomySignals
    state.MemorySnapshot = aiBrain.OvermindMemory or {}

    local eco = runtime.EcoState or {}
    local opp = runtime.OpponentModel or {}
    local recovery = runtime.Recovery or {}
    local ledger = runtime.EconomyLedger or { Aggregate = {} }
    local structure = ComputeContestMapStructure(aiBrain, runtime)
    local velocity = UpdateHistory(state, now, eco, ledger, structure)
    local pressure = BuildPressure(runtime, now, eco, ledger, structure, velocity)
    local policySeed = BuildPolicySeed(runtime, now, eco, opp, recovery, structure, velocity, pressure)

    state.Structure = structure
    state.Velocity = velocity
    state.Pressure = pressure
    state.PolicySeed = policySeed
    state.StructuralContestMap = structure.StructuralContestMap and true or false
    state.FocusOnT1Spam = policySeed.FocusOnT1Spam and true or false
    state.ContestMapMode = policySeed.ContestMapMode and true or false
    state.LastUpdate = now

    runtime.EcoVelocity = velocity
    runtime.EcoPressure = pressure
    return state
end

function M.GetSignals(runtime)
    return (runtime and runtime.EconomySignals) or {}
end

function M.GetStructure(aiBrain, runtime, now)
    local signals = runtime and runtime.EconomySignals or false
    if signals and signals.Structure and (not now or ((now - (signals.LastUpdate or -999)) <= 6)) then
        return signals.Structure
    end
    return ComputeContestMapStructure(aiBrain, runtime or {})
end

function M.GetVelocity(runtime)
    return (runtime and (runtime.EcoVelocity or (runtime.EconomySignals and runtime.EconomySignals.Velocity))) or {}
end

function M.GetPressure(runtime)
    return (runtime and (runtime.EcoPressure or (runtime.EconomySignals and runtime.EconomySignals.Pressure))) or {}
end

function M.ComputeContestMapStructure(aiBrain, runtime)
    return ComputeContestMapStructure(aiBrain, runtime or {})
end

function Update(aiBrain, now)
    return M.Update(aiBrain, now)
end

function GetSignals(runtime)
    return M.GetSignals(runtime)
end

function GetStructure(aiBrain, runtime, now)
    return M.GetStructure(aiBrain, runtime, now)
end

function GetVelocity(runtime)
    return M.GetVelocity(runtime)
end

function GetPressure(runtime)
    return M.GetPressure(runtime)
end

return M
