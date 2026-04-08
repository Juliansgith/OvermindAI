local function Clamp(v, minV, maxV)
    if v < minV then
        return minV
    end
    if v > maxV then
        return maxV
    end
    return v
end

local function GetGoalUtilities(aiBrain, now)
    local runtime = aiBrain.OvermindRuntime or {}
    local zone = runtime.ZoneModel or {}
    local intel = runtime.IntelModel or {}
    local force = runtime.ForceDirector or runtime.ForceManager or {}
    local opp = runtime.OpponentModel or {}
    local eco = runtime.EcoState or {}
    local recovery = runtime.Recovery or {}
    local policy = runtime.EcoPolicy or {}
    local phase = policy.MacroPhase or 'consolidate'
    local momentum = runtime.CombatMomentum or 0
    local timeSec = now or 0

    local massFloat = (eco.MassStored or 0) / math.max(1, 500 + (eco.UnitCount or 0))
    local energySafe = ((eco.EnergyStored or 0) > 3000 and (eco.EnergyTrend or 0) > 10) and 1 or 0
    local relative = opp.RelativeMilitary or 1
    local powerRelative = opp.RelativePower or relative
    local homeThreat = zone.HomeThreat or 0
    local expansionThreat = zone.ExpansionThreat or 0
    local mapControl = zone.MapControl or 0.5
    local contestedZones = intel.ContestedZones or 0
    local staleZones = intel.StaleZones or 0
    local raidPressure = (intel.BestRaidZoneKey and 1 or 0) + math.min(2, (force.RoleDemand and force.RoleDemand.Raider or 0))
    local stallingMass = eco.StallingMass or false
    local stallingEnergy = eco.StallingEnergy or false
    local forceFactoryRecovery = recovery.ForceFactoryRecovery == true
    local forceBaseRecovery = recovery.ForceBaseEngineerRecovery == true
    local stagnation = recovery.StagnationTime or 0

    local util = {}
    util.hold = (homeThreat * 0.42) + math.max(0, -momentum) * 2.2 + math.max(0, 1 - powerRelative) * 3.2
    util.expand = (zone.BestExpansionScore or 0) * 0.12 + massFloat * 1.8 + energySafe + math.max(0, 0.8 - mapControl) * 1.6 - expansionThreat * 0.2
    util.raid = (zone.BestRaidScore or 0) * 0.11 + math.max(0, momentum) * 1.9 + math.max(0, powerRelative - 0.95) * 0.9
    util.tech = massFloat * 2.8 + energySafe * 2.0 + math.max(0, powerRelative - 0.85) + math.max(0, mapControl - 0.85)
    util.all_in = math.max(0, powerRelative - 1.18) * 4.2 + math.max(0, momentum) * 2.4 + math.max(0, 0.7 - (zone.BestRaidScore or 0) * 0.04)
    util.hold = util.hold + (contestedZones * 0.55)
    util.expand = util.expand + math.min(1.4, staleZones * 0.2)
    util.raid = util.raid + (raidPressure * 0.8)
    util.tech = util.tech - (contestedZones * 0.25)

    if phase == 'bootstrap' then
        util.expand = util.expand + 1.1
        util.hold = util.hold + 0.7
        util.raid = util.raid - 1.8
        util.tech = util.tech - 2.2
        util.all_in = util.all_in - 3.0
    elseif phase == 'recover' then
        util.hold = util.hold + 1.8
        util.expand = util.expand - 0.8
        util.raid = util.raid - 2.2
        util.tech = util.tech - 1.4
        util.all_in = util.all_in - 2.8
    elseif phase == 'pressure' then
        util.raid = util.raid + 0.9
        util.expand = util.expand + 0.4
    elseif phase == 'tech' then
        util.tech = util.tech + 1.1
    end

    if stallingMass then
        util.hold = util.hold + 1.1
        util.tech = util.tech - 1.2
        util.all_in = util.all_in - 1.4
    end
    if stallingEnergy then
        util.hold = util.hold + 0.9
        util.expand = util.expand - 0.8
        util.all_in = util.all_in - 1.0
    end

    if forceFactoryRecovery or forceBaseRecovery or stagnation > 90 then
        util.expand = util.expand - 2.3
        util.raid = util.raid - 1.7
        util.all_in = util.all_in - 2.2
        util.hold = util.hold + 1.5
        util.tech = util.tech + 0.4
    end

    if opp.Posture == 'eco_greed' then
        util.raid = util.raid + 2.5
        util.all_in = util.all_in + 1
        util.tech = util.tech - 0.5
    elseif opp.Posture == 'air_rush' then
        util.hold = util.hold + 2
        util.raid = util.raid - 0.7
    elseif opp.Posture == 'turtle' then
        util.tech = util.tech + 1.5
        util.expand = util.expand + 0.7
    elseif opp.Posture == 'land_push' then
        util.hold = util.hold + 1.8
    elseif opp.Posture == 'no_presence' then
        util.expand = util.expand + 1.8
        util.raid = util.raid + 1.2
    elseif opp.Posture == 'experimental' then
        util.hold = util.hold + 2.2
        util.all_in = util.all_in - 1.5
    end

    if timeSec < 240 then
        util.all_in = util.all_in - 3.0
        util.tech = util.tech - 0.5
    elseif timeSec > 960 then
        util.all_in = util.all_in + 0.8
        util.tech = util.tech + 0.6
    end

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

function Update(aiBrain, now)
    aiBrain.OvermindRuntime = aiBrain.OvermindRuntime or {}
    local runtime = aiBrain.OvermindRuntime

    local util = GetGoalUtilities(aiBrain, now)
    local goal, goalValue = PickBest(util)

    local previousGoal = runtime.StrategyGoal or 'hold'
    local previousValue = util[previousGoal] or -999999
    if previousGoal ~= goal and previousValue >= (goalValue - 0.75) then
        goal = previousGoal
        goalValue = previousValue
    end

    runtime.StrategyGoal = goal
    runtime.StrategyGoalScore = goalValue
    runtime.StrategyUtilities = util

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

    if (runtime.OpponentModel and (runtime.OpponentModel.RelativePower or 1) > 1.2) and goal ~= 'hold' then
        aggressionShift = aggressionShift - 0.08
    end

    runtime.GoalAggressionModifier = Clamp(aggressionShift, -0.3, 0.3)
    runtime.GoalConfidence = goalValue - (util.hold or 0)
    runtime.LastGoalUpdate = now
end
