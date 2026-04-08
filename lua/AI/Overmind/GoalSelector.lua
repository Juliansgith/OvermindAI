local function Clamp(v, minV, maxV)
    if v < minV then
        return minV
    end
    if v > maxV then
        return maxV
    end
    return v
end

local function GetNode(graph, key)
    if not graph or not key then
        return false
    end
    local byKey = graph.ByKey or {}
    return byKey[key] or false
end

local function GetMapControl(runtime)
    local intel = runtime.IntelModel or {}
    local graph = runtime.ZoneGraph or {}
    local zone = runtime.ZoneModel or {}
    return intel.MapControl or graph.MapControl or zone.MapControl or 0
end

local function GetStrategicSignals(aiBrain, now)
    local runtime = aiBrain.OvermindRuntime or {}
    local graph = runtime.ZoneGraph or {}
    local intel = runtime.IntelModel or {}
    local clusters = runtime.EnemyClusterTracker or {}
    local force = runtime.ForceDirector or runtime.ForceManager or {}
    local opp = runtime.OpponentModel or {}
    local planner = runtime.StrategicPlanner or {}
    local eco = runtime.EcoState or {}
    local recovery = runtime.Recovery or {}
    local policy = runtime.EcoPolicy or {}
    local zone = runtime.ZoneModel or {}
    local phase = policy.MacroPhase or 'consolidate'
    local momentum = runtime.CombatMomentum or 0
    local timeSec = now or 0

    local bestExpansionNode = GetNode(graph, intel.BestExpansionZoneKey or graph.BestExpansionNodeKey)
    local bestRaidNode = GetNode(graph, intel.BestRaidZoneKey or graph.BestRaidNodeKey)
    local frontNode = GetNode(graph, intel.FrontZoneKey or graph.FrontNodeKey)
    local approach = clusters.ApproachCluster or {}

    local approachThreat = approach.TotalThreat or 0
    local approachDistance = approach.HomeDistance or 999
    local approachAir = approach.EnemyAir or 0
    local approachConfidence = approach.ContactConfidence or 0
    local approachReal = ((approach.ConfirmedUnits or 0) > 0)
        or ((approach.MemoryThreat or 0) >= 1.25)
        or approachConfidence >= 0.46
    local approachClose = approachReal and approachDistance < 260 and approachThreat >= 4.5

    local mapControl = GetMapControl(runtime)
    local contestedZones = intel.ContestedZones or graph.ContestedZones or 0
    local staleZones = intel.StaleZones or 0
    local airThreatZones = intel.AirThreatZones or 0
    local friendlyZones = intel.FriendlyZones or graph.FriendlyZones or 0
    local enemyZones = intel.EnemyZones or graph.EnemyZones or 0

    local bestExpansionScore = (bestExpansionNode and bestExpansionNode.ExpansionValue) or zone.BestExpansionScore or 0
    local bestRaidScore = (bestRaidNode and bestRaidNode.RaidValue) or zone.BestRaidScore or 0
    local expansionThreat = (bestExpansionNode and bestExpansionNode.Threat) or zone.ExpansionThreat or 0
    local frontThreat = (frontNode and frontNode.Threat) or zone.HomeThreat or 0
    local raidThreat = (bestRaidNode and bestRaidNode.Threat) or 0
    local raidAirThreat = (bestRaidNode and math.max(bestRaidNode.AirThreat or 0, bestRaidNode.EnemyAir or 0)) or 0
    local expansionAirThreat = (bestExpansionNode and math.max(bestExpansionNode.AirThreat or 0, bestExpansionNode.EnemyAir or 0)) or 0
    local raidFreshnessDebt = bestRaidNode and (1 - (bestRaidNode.Freshness or 0)) or 0
    local expansionFreshnessDebt = bestExpansionNode and (1 - (bestExpansionNode.Freshness or 0)) or 0

    local massFloat = (eco.MassStored or 0) / math.max(1, 500 + (eco.UnitCount or 0))
    local energyFloat = (eco.EnergyStored or 0) / math.max(1, 3500 + ((eco.UnitCount or 0) * 6))
    local energySafe = ((eco.EnergyStored or 0) > 3000 and (eco.EnergyTrend or 0) > 10) and 1 or 0
    local relative = opp.RelativeMilitary or 1
    local powerRelative = opp.RelativePower or relative
    local stallingMass = eco.StallingMass or false
    local stallingEnergy = eco.StallingEnergy or false
    local forceFactoryRecovery = recovery.ForceFactoryRecovery == true
    local forceBaseRecovery = recovery.ForceBaseEngineerRecovery == true
    local stagnation = recovery.StagnationTime or 0

    local forceStats = force.Stats or {}
    local mainlineUnits = forceStats.MainLine or 0
    local baseGuardUnits = forceStats.BaseGuard or 0
    local airGuardUnits = forceStats.AirGuard or 0
    local bombers = forceStats.BomberStrike or 0
    local escortUnits = forceStats.ACUEscort or 0

    local graphReady = graph.StaticBuilt == true and table.getn(graph.Nodes or {}) > 0

    return {
        Runtime = runtime,
        Phase = phase,
        Time = timeSec,
        Momentum = momentum,
        MapControl = mapControl,
        ContestedZones = contestedZones,
        StaleZones = staleZones,
        AirThreatZones = airThreatZones,
        FriendlyZones = friendlyZones,
        EnemyZones = enemyZones,
        BestExpansionNode = bestExpansionNode,
        BestRaidNode = bestRaidNode,
        FrontNode = frontNode,
        BestExpansionScore = bestExpansionScore,
        BestRaidScore = bestRaidScore,
        ExpansionThreat = expansionThreat,
        ExpansionAirThreat = expansionAirThreat,
        FrontThreat = frontThreat,
        RaidThreat = raidThreat,
        RaidAirThreat = raidAirThreat,
        RaidFreshnessDebt = raidFreshnessDebt,
        ExpansionFreshnessDebt = expansionFreshnessDebt,
        Approach = approach,
        ApproachThreat = approachThreat,
        ApproachDistance = approachDistance,
        ApproachAir = approachAir,
        ApproachConfidence = approachConfidence,
        ApproachReal = approachReal,
        ApproachClose = approachClose,
        MassFloat = massFloat,
        EnergyFloat = energyFloat,
        EnergySafe = energySafe,
        RelativeMilitary = relative,
        RelativePower = powerRelative,
        StallingMass = stallingMass,
        StallingEnergy = stallingEnergy,
        RecoveryFactory = forceFactoryRecovery,
        RecoveryBase = forceBaseRecovery,
        Stagnation = stagnation,
        OpponentPosture = opp.Posture or 'balanced',
        EnemyLowAirThreat = opp.LowAirThreat == true,
        EnemyIndirectHeavy = opp.IndirectHeavy == true,
        EnemyT2Push = opp.T2Push == true,
        CounterAirWindow = opp.CounterAirWindow == true,
        MainlineUnits = mainlineUnits,
        BaseGuardUnits = baseGuardUnits,
        AirGuardUnits = airGuardUnits,
        BomberUnits = bombers,
        EscortUnits = escortUnits,
        GraphReady = graphReady,
        Planner = planner,
    }
end

local function GetGoalUtilities(signals)
    local util = {}
    local planner = signals.Planner or {}
    local goalBiases = planner.GoalBiases or {}

    util.hold =
        (signals.FrontThreat * 0.36)
        + (signals.ApproachThreat * 0.62)
        + (signals.ContestedZones * 0.58)
        + (signals.AirThreatZones * 0.22)
        + math.max(0, 1 - signals.RelativePower) * 3.6
        + math.max(0, 1 - signals.RelativeMilitary) * 1.9
        + math.max(0, signals.BaseGuardUnits - signals.MainlineUnits) * 0.08

    util.expand =
        (signals.BestExpansionScore * 0.105)
        + (signals.ExpansionFreshnessDebt * 1.1)
        + math.max(0, 0.82 - signals.MapControl) * 1.7
        + math.min(1.6, signals.StaleZones * 0.2)
        - (signals.ExpansionThreat * 0.26)
        - (signals.ExpansionAirThreat * 0.32)
        - (signals.ApproachClose and 2.2 or 0)
        - math.max(0, 0.95 - signals.RelativePower) * 1.4

    util.raid =
        (signals.BestRaidScore * 0.11)
        + (signals.RaidFreshnessDebt * 0.55)
        + math.max(0, signals.Momentum) * 1.9
        + math.max(0, signals.RelativePower - 0.95) * 1.2
        + ((signals.CounterAirWindow or (signals.EnemyLowAirThreat and (signals.EnemyIndirectHeavy or signals.EnemyT2Push))) and 0.8 or 0)
        - (signals.RaidThreat * 0.18)
        - (signals.RaidAirThreat * 0.28)
        - (signals.ApproachClose and 1.9 or 0)

    util.tech =
        (signals.MassFloat * 2.5)
        + (signals.EnergySafe * 1.8)
        + math.max(0, signals.EnergyFloat - 0.2) * 1.2
        + math.max(0, signals.MapControl - 0.72) * 1.1
        + math.max(0, signals.RelativePower - 0.95) * 0.9
        - (signals.ContestedZones * 0.28)
        - (signals.ApproachClose and 2.4 or 0)

    util.all_in =
        math.max(0, signals.RelativePower - 1.15) * 4.0
        + math.max(0, signals.Momentum) * 2.2
        + math.max(0, signals.MapControl - 0.85) * 1.3
        + ((signals.EnemyLowAirThreat and signals.EnemyT2Push) and 0.8 or 0)
        - (signals.ApproachClose and 1.4 or 0)
        - (signals.StallingMass and 1.6 or 0)

    if signals.Phase == 'bootstrap' then
        util.expand = util.expand + 1.2
        util.hold = util.hold + 0.8
        util.raid = util.raid - 2.0
        util.tech = util.tech - 2.4
        util.all_in = util.all_in - 3.2
    elseif signals.Phase == 'recover' then
        util.hold = util.hold + 1.9
        util.expand = util.expand - 0.9
        util.raid = util.raid - 2.2
        util.tech = util.tech - 1.4
        util.all_in = util.all_in - 2.8
    elseif signals.Phase == 'pressure' then
        util.raid = util.raid + 1.0
        util.expand = util.expand + 0.3
    elseif signals.Phase == 'tech' then
        util.tech = util.tech + 1.2
    end

    if signals.StallingMass then
        util.hold = util.hold + 1.1
        util.expand = util.expand - 0.6
        util.tech = util.tech - 1.3
        util.all_in = util.all_in - 1.6
    end
    if signals.StallingEnergy then
        util.hold = util.hold + 0.9
        util.expand = util.expand - 0.8
        util.raid = util.raid - 0.6
        util.all_in = util.all_in - 1.0
    end

    if signals.RecoveryFactory or signals.RecoveryBase or signals.Stagnation > 90 then
        util.expand = util.expand - 2.2
        util.raid = util.raid - 1.8
        util.all_in = util.all_in - 2.0
        util.hold = util.hold + 1.6
        util.tech = util.tech + 0.3
    end

    if signals.OpponentPosture == 'eco_greed' then
        util.raid = util.raid + 2.4
        util.all_in = util.all_in + 0.8
        util.tech = util.tech - 0.5
    elseif signals.OpponentPosture == 'air_rush' then
        util.hold = util.hold + 2.0
        util.raid = util.raid - 0.8
    elseif signals.OpponentPosture == 'turtle' then
        util.tech = util.tech + 1.5
        util.expand = util.expand + 0.7
    elseif signals.OpponentPosture == 'land_push' then
        util.hold = util.hold + 1.8
    elseif signals.OpponentPosture == 'no_presence' then
        util.expand = util.expand + 1.7
        util.raid = util.raid + 1.1
    elseif signals.OpponentPosture == 'experimental' then
        util.hold = util.hold + 2.1
        util.all_in = util.all_in - 1.5
    end

    if signals.EnemyLowAirThreat and (signals.EnemyIndirectHeavy or signals.EnemyT2Push) then
        util.raid = util.raid + 0.6
        util.tech = util.tech - 0.4
    end
    if signals.ApproachReal and signals.ApproachDistance < 190 then
        util.hold = util.hold + 1.8
        util.expand = util.expand - 1.5
        util.raid = util.raid - 1.0
        util.all_in = util.all_in - 0.8
    end

    if signals.Time < 240 then
        util.all_in = util.all_in - 3.0
        util.tech = util.tech - 0.5
    elseif signals.Time > 960 then
        util.all_in = util.all_in + 0.8
        util.tech = util.tech + 0.6
    end

    util.hold = util.hold + (goalBiases.hold or 0)
    util.expand = util.expand + (goalBiases.expand or 0)
    util.raid = util.raid + (goalBiases.raid or 0)
    util.tech = util.tech + (goalBiases.tech or 0)
    util.all_in = util.all_in + (goalBiases.all_in or 0)

    return util
end

local function PickBest(util)
    local bestGoal = 'hold'
    local bestValue = -999999
    for goal, value in util do
        if value > bestValue then
            bestGoal = goal
            bestValue = value
        end
    end
    return bestGoal, bestValue
end

local function DetermineGoalFocus(signals, goal)
    local runtime = signals.Runtime
    local graph = runtime.ZoneGraph or {}
    local intel = runtime.IntelModel or {}
    local zone = runtime.ZoneModel or {}
    local planner = runtime.StrategicPlanner or {}
    local approach = signals.Approach or {}

    if planner.FocusPos then
        return planner.FocusPos, planner.FocusZoneKey, planner.FocusReason or 'strategic_plan'
    end

    if goal == 'hold' then
        if signals.ApproachReal then
            return approach.StagePos or approach.Pos or intel.FrontLinePos or graph.FrontLinePos or zone.FrontLinePos, approach.StageZoneKey or approach.ZoneKey or intel.FrontZoneKey or graph.FrontNodeKey, 'approach_hold'
        end
        return intel.FrontLinePos or graph.FrontLinePos or zone.FrontLinePos or intel.OwnMainPos or graph.OwnMainPos or zone.OwnMainPos, intel.FrontZoneKey or graph.FrontNodeKey, 'front_hold'
    elseif goal == 'expand' then
        return intel.BestExpansionPos or graph.BestExpansionPos or zone.BestExpansionPos, intel.BestExpansionZoneKey or graph.BestExpansionNodeKey, 'graph_expand'
    elseif goal == 'raid' then
        return intel.BestRaidPos or graph.BestRaidPos or zone.BestRaidPos, intel.BestRaidZoneKey or graph.BestRaidNodeKey, 'graph_raid'
    elseif goal == 'tech' then
        return intel.BestExpansionPos or graph.BestExpansionPos or zone.BestExpansionPos or intel.FrontLinePos or graph.FrontLinePos, intel.BestExpansionZoneKey or graph.BestExpansionNodeKey or intel.FrontZoneKey or graph.FrontNodeKey, 'tech_expand'
    elseif goal == 'all_in' then
        return graph.EnemyMainPos or intel.EnemyMainPos or runtime.PrimaryEnemyPos or graph.BestRaidPos or zone.BestRaidPos, 'enemy_main', 'enemy_main'
    end

    return intel.FrontLinePos or graph.FrontLinePos or zone.FrontLinePos or intel.OwnMainPos or graph.OwnMainPos or zone.OwnMainPos, intel.FrontZoneKey or graph.FrontNodeKey, 'fallback'
end

function Update(aiBrain, now)
    aiBrain.OvermindRuntime = aiBrain.OvermindRuntime or {}
    local runtime = aiBrain.OvermindRuntime

    local signals = GetStrategicSignals(aiBrain, now)
    local util = GetGoalUtilities(signals)
    local goal, goalValue = PickBest(util)

    local previousGoal = runtime.StrategyGoal or 'hold'
    local previousValue = util[previousGoal] or -999999
    if previousGoal ~= goal and previousValue >= (goalValue - 0.75) then
        goal = previousGoal
        goalValue = previousValue
    end

    local focusPos, focusZoneKey, focusReason = DetermineGoalFocus(signals, goal)

    runtime.StrategyGoal = goal
    runtime.StrategyGoalScore = goalValue
    runtime.StrategyUtilities = util
    runtime.StrategyFocusPos = focusPos
    runtime.StrategyFocusZoneKey = focusZoneKey
    runtime.StrategyFocusReason = focusReason
    runtime.StrategySignals = {
        GraphReady = signals.GraphReady,
        MapControl = signals.MapControl,
        ContestedZones = signals.ContestedZones,
        StaleZones = signals.StaleZones,
        BestExpansionScore = signals.BestExpansionScore,
        BestRaidScore = signals.BestRaidScore,
        ApproachThreat = signals.ApproachThreat,
        ApproachDistance = signals.ApproachDistance,
        ApproachReal = signals.ApproachReal,
        PlannerDirective = (signals.Planner and signals.Planner.Directive) or 'stabilize',
        PlannerTheater = (signals.Planner and signals.Planner.PrimaryTheater) or 'Front',
        PlannerRaidDirective = (signals.Planner and signals.Planner.RaidDirective) or 'opportunistic',
        PlannerRaidCentrality = (signals.Planner and signals.Planner.RaidCentrality) or 0,
    }

    local aggressionShift = 0
    if goal == 'all_in' then
        aggressionShift = 0.25
    elseif goal == 'raid' then
        aggressionShift = 0.15
    elseif goal == 'tech' then
        aggressionShift = 0.05
    elseif goal == 'expand' then
        aggressionShift = 0.08
    elseif goal == 'hold' then
        aggressionShift = -0.2
    end

    if signals.RelativePower > 1.2 and goal ~= 'hold' then
        aggressionShift = aggressionShift - 0.08
    end
    if signals.ApproachReal and signals.ApproachDistance < 190 and goal ~= 'hold' then
        aggressionShift = aggressionShift - 0.06
    end
    aggressionShift = aggressionShift + (((signals.Planner and signals.Planner.AggressionBias) or 0))

    runtime.GoalAggressionModifier = Clamp(aggressionShift, -0.3, 0.3)
    runtime.GoalConfidence = goalValue - (util.hold or 0)
    runtime.LastGoalUpdate = now
end
