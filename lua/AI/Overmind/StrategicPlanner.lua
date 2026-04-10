local Module = {
    Name = 'StrategicPlanner',
    StateSlice = 'StrategicPlanner',
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

local function TableCount(t)
    return t and table.getn(t) or 0
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

local function BuildSignals(aiBrain, runtime, now)
    local graph = runtime.ZoneGraph or {}
    local intel = runtime.IntelModel or {}
    local zone = runtime.ZoneModel or {}
    local clusters = runtime.EnemyClusterTracker or {}
    local opp = runtime.OpponentModel or {}
    local eco = runtime.EcoState or {}
    local recovery = runtime.Recovery or {}
    local raid = runtime.RaidDefense or {}
    local force = runtime.ForceDirector or runtime.ForceManager or {}
    local policy = runtime.EcoPolicy or {}
    local phase = runtime.MacroPhase or policy.MacroPhase or 'consolidate'

    local bestExpansionNode = GetNode(graph, intel.BestExpansionZoneKey or graph.BestExpansionNodeKey)
    local bestRaidNode = GetNode(graph, intel.BestRaidZoneKey or graph.BestRaidNodeKey)
    local frontNode = GetNode(graph, intel.FrontZoneKey or graph.FrontNodeKey)
    local approach = clusters.ApproachCluster or {}
    local theaters = opp.Theaters or {}
    local forceStats = force.Stats or {}

    local approachThreat = approach.TotalThreat or 0
    local approachDistance = approach.HomeDistance or 999
    local approachConfidence = approach.ContactConfidence or 0
    local approachReal = ((approach.ConfirmedUnits or 0) > 0)
        or ((approach.MemoryThreat or 0) >= 1.25)
        or approachConfidence >= 0.46
    local approachClose = approachReal and approachDistance < 260 and approachThreat >= 4.5

    local homeTheater = theaters.Home or {}
    local frontTheater = theaters.Front or {}
    local enemyTheater = theaters.Enemy or {}
    local navyTheater = theaters.Navy or {}

    local bestExpansionScore = (bestExpansionNode and bestExpansionNode.ExpansionValue) or zone.BestExpansionScore or 0
    local bestRaidScore = (bestRaidNode and bestRaidNode.RaidValue) or zone.BestRaidScore or 0
    local frontThreat = (frontNode and frontNode.Threat) or zone.HomeThreat or 0
    local mapControl = GetMapControl(runtime)
    local relativePower = opp.RelativePower or opp.RelativeMilitary or 1
    local contestedZones = intel.ContestedZones or graph.ContestedZones or 0

    local massRatio = eco.MassStorageRatio or 0
    local energyRatio = eco.EnergyStorageRatio or 0
    local massTrend = eco.MassTrend or 0
    local energyTrend = eco.EnergyTrend or 0
    local massIncome = eco.MassIncome or 0
    local energyIncome = eco.EnergyIncome or 0
    local ecoWeak = massRatio <= 0.08
        or energyRatio <= 0.08
        or massTrend <= -0.08
        or energyTrend <= -6
    local durableSurplus = massIncome >= 5
        and energyIncome >= 75
        and massRatio >= 0.18
        and energyRatio >= 0.16
        and massTrend >= -0.03
        and energyTrend >= 0
    local recoveryActive = recovery.ForceFactoryRecovery == true
        or recovery.ForceBaseEngineerRecovery == true
        or (recovery.StagnationTime or 0) >= 75
    local greedWindow = opp.LikelyPivot == 'greedy_tech'
        or opp.Posture == 'eco_greed'
        or opp.LikelyPivot == 'turtle'
        or opp.Posture == 'turtle'
    local pushWindow = opp.LikelyPivot == 'push_window'
        or opp.Posture == 'land_push'
        or opp.T2Push == true
        or opp.IndirectHeavy == true
    local forceAirAnswer = opp.CounterAirWindow == true
        or ((opp.LowAirThreat == true)
            and (opp.T2Push == true or opp.IndirectHeavy == true)
            and (approachClose or (frontTheater.PressureEMA or 0) >= 4.5 or bestRaidScore >= 12))
    local navalActive = ((zone.NavMarkerCount or 0) >= 3)
        or ((opp.Navy or 0) > 0)
        or ((navyTheater.PressureEMA or 0) > 0)

    return {
        Time = now or 0,
        Phase = phase,
        GraphReady = graph.StaticBuilt == true and TableCount(graph.Nodes or {}) > 0,
        BestExpansionPos = intel.BestExpansionPos or graph.BestExpansionPos or zone.BestExpansionPos,
        BestExpansionZoneKey = intel.BestExpansionZoneKey or graph.BestExpansionNodeKey,
        BestRaidPos = intel.BestRaidPos or graph.BestRaidPos or zone.BestRaidPos,
        BestRaidZoneKey = intel.BestRaidZoneKey or graph.BestRaidNodeKey,
        FrontPos = intel.FrontLinePos or graph.FrontLinePos or zone.FrontLinePos,
        FrontZoneKey = intel.FrontZoneKey or graph.FrontNodeKey,
        EnemyMainPos = graph.EnemyMainPos or intel.EnemyMainPos or runtime.PrimaryEnemyPos,
        Approach = approach,
        ApproachReal = approachReal,
        ApproachClose = approachClose,
        ApproachThreat = approachThreat,
        ApproachDistance = approachDistance,
        MapControl = mapControl,
        ContestedZones = contestedZones,
        BestExpansionScore = bestExpansionScore,
        BestRaidScore = bestRaidScore,
        FrontThreat = frontThreat,
        HomePressure = homeTheater.PressureEMA or homeTheater.Pressure or 0,
        FrontPressure = frontTheater.PressureEMA or frontTheater.Pressure or 0,
        EnemyPressure = enemyTheater.PressureEMA or enemyTheater.Pressure or 0,
        NavyPressure = navyTheater.PressureEMA or navyTheater.Pressure or 0,
        HomeConfidence = homeTheater.Confidence or 0,
        FrontConfidence = frontTheater.Confidence or 0,
        EnemyConfidence = enemyTheater.Confidence or 0,
        NavyConfidence = navyTheater.Confidence or 0,
        RelativePower = relativePower,
        EcoWeak = ecoWeak,
        DurableSurplus = durableSurplus,
        RecoveryActive = recoveryActive,
        GreedWindow = greedWindow,
        PushWindow = pushWindow,
        ForceAirAnswerCandidate = forceAirAnswer,
        NavalActive = navalActive,
        MainlineUnits = forceStats.MainLine or 0,
        BaseGuardUnits = forceStats.BaseGuard or 0,
        BomberUnits = forceStats.BomberStrike or 0,
        EscortUnits = forceStats.ACUEscort or 0,
        UnderLandHarass = raid.UnderLandHarass == true,
        UnderAirHarass = raid.UnderAirHarass == true,
        AttackWindow = (
            relativePower >= 1.04
            and mapControl >= 0.34
            and not ecoWeak
            and not recoveryActive
            and not approachClose
            and ((frontTheater.PressureEMA or frontTheater.Pressure or 0) >= 1.6)
            and ((forceStats.MainLine or 0) + (forceStats.Artillery or 0) >= math.max(18, (forceStats.BaseGuard or 0) + 8))
        ) and true or false,
    }
end

local function PickStableKey(state, fieldName, switchFieldName, scores, fallback, now, minHold, margin)
    local current = state[fieldName] or fallback
    local bestKey = fallback
    local bestScore = -999999
    local currentScore = scores[current] or -999999
    for key, score in scores do
        if score > bestScore then
            bestScore = score
            bestKey = key
        end
    end

    if current and currentScore >= (bestScore - (margin or 0)) then
        return current
    end

    if (now - (state[switchFieldName] or -999)) < (minHold or 0) then
        return current
    end

    state[switchFieldName] = now
    return bestKey
end

local function ScoreTheaters(signals)
    local scores = {}
    scores.Home =
        (signals.HomePressure * 0.85)
        + (signals.ApproachClose and 3.0 or 0)
        + ((signals.UnderLandHarass or signals.UnderAirHarass) and 2.0 or 0)
        + (signals.RecoveryActive and 1.6 or 0)
        + (signals.EcoWeak and 0.8 or 0)

    scores.Front =
        (signals.FrontPressure * 0.8)
        + (signals.ContestedZones * 0.8)
        + (signals.PushWindow and 1.4 or 0)
        + ((signals.ApproachReal and not signals.ApproachClose) and 0.9 or 0)
        + ((signals.MainlineUnits <= math.max(2, signals.BaseGuardUnits - 1)) and 0.9 or 0)

    scores.Enemy =
        (signals.BestRaidScore * 0.08)
        + (signals.BestExpansionScore * 0.03)
        + (signals.GreedWindow and 1.6 or 0)
        + (signals.DurableSurplus and 0.6 or 0)
        + math.max(0, signals.RelativePower - 0.96) * 1.2
        - (signals.ApproachClose and 1.4 or 0)
        - (signals.RecoveryActive and 0.8 or 0)

    scores.Navy =
        ((signals.NavalActive and (signals.NavyPressure * 0.75)) or -0.2)
        + (((signals.NavalActive and signals.NavyConfidence > 0) and signals.NavyConfidence * 0.9) or 0)
        + (((signals.NavalActive and signals.NavyPressure >= 3) and 0.8) or 0)

    if not signals.NavalActive then
        scores.Navy = -1
    end

    return scores
end

local function ScoreDirectives(signals, primaryTheater)
    local scores = {}
    scores.stabilize =
        (signals.EcoWeak and 1.6 or 0)
        + (signals.RecoveryActive and 2.2 or 0)
        + ((primaryTheater == 'Home') and 1.4 or 0)
        + (signals.HomePressure * 0.22)
        + (signals.FrontPressure * 0.08)
        + ((signals.Phase == 'bootstrap') and 1.8 or 0)
        + ((signals.Phase == 'recover') and 1.4 or 0)
        + (signals.ApproachClose and 1.2 or 0)

    scores.expand =
        math.max(0, 0.62 - signals.MapControl) * 2.1
        + (signals.BestExpansionScore * 0.05)
        + ((primaryTheater == 'Enemy' and not signals.GreedWindow) and 0.3 or 0)
        + (signals.DurableSurplus and 0.7 or 0)
        - (signals.ApproachClose and 1.4 or 0)
        - (signals.RecoveryActive and 1.0 or 0)
        - (signals.PushWindow and 0.8 or 0)

    scores.punish_greed =
        (signals.GreedWindow and 2.0 or 0)
        + (signals.BestRaidScore * 0.06)
        + math.max(0, signals.RelativePower - 0.92) * 1.1
        + (signals.AttackWindow and 1.1 or 0)
        + ((primaryTheater == 'Enemy') and 0.8 or 0)
        - (signals.ApproachClose and 0.8 or 0)
        - (signals.RecoveryActive and 1.0 or 0)

    scores.force_air_answer =
        (signals.ForceAirAnswerCandidate and 2.2 or 0)
        + (signals.FrontPressure * 0.12)
        + (signals.ApproachThreat * 0.08)
        + ((primaryTheater == 'Front') and 0.5 or 0)
        - (signals.RecoveryActive and 0.6 or 0)

    scores.trade_map_for_tech =
        (signals.DurableSurplus and 1.8 or 0)
        + math.max(0, signals.MapControl - 0.42) * 2.2
        + (signals.GreedWindow and 0.7 or 0)
        + (((signals.Phase == 'tech') or (signals.Phase == 'pressure')) and 0.4 or 0)
        - (signals.HomePressure * 0.08)
        - (signals.FrontPressure * 0.08)
        - (signals.RecoveryActive and 1.6 or 0)
        - (signals.ForceAirAnswerCandidate and 0.9 or 0)

    scores.trade_tech_for_tempo =
        (signals.GreedWindow and 1.2 or 0)
        + (signals.PushWindow and 0.8 or 0)
        + math.max(0, signals.RelativePower - 0.96) * 1.0
        + (signals.AttackWindow and 1.3 or 0)
        + (signals.BestRaidScore * 0.04)
        + ((primaryTheater == 'Front') and 0.5 or 0)
        + ((primaryTheater == 'Enemy') and 0.4 or 0)
        - (signals.DurableSurplus and 0.4 or 0)
        - (signals.RecoveryActive and 1.2 or 0)

    if signals.AttackWindow then
        scores.stabilize = scores.stabilize - 0.9
        scores.expand = scores.expand - 0.4
    end

    return scores
end

local function BuildDirectiveState(signals, primaryTheater, directive)
    local punishGreed = directive == 'punish_greed' or signals.GreedWindow
    local tradeMapForTech = directive == 'trade_map_for_tech'
    local tradeTechForTempo = directive == 'trade_tech_for_tempo'
        or (directive == 'punish_greed' and not signals.DurableSurplus)
    local forceAirAnswer = directive == 'force_air_answer' or signals.ForceAirAnswerCandidate

    local raidCentrality = Clamp(
        (signals.BestRaidScore * 0.04)
        + (punishGreed and 0.24 or 0)
        + (tradeTechForTempo and 0.18 or 0)
        + ((primaryTheater == 'Enemy') and 0.18 or 0)
        - ((primaryTheater == 'Home') and 0.34 or 0)
        - ((directive == 'stabilize') and 0.28 or 0)
        - (signals.RecoveryActive and 0.18 or 0)
        - ((directive == 'expand') and 0.18 or 0),
        0,
        1)

    local tempoMode = 'balanced'
    local tempoBias = 0
    local techBias = 0
    if tradeMapForTech then
        tempoMode = 'tech'
        tempoBias = -0.35
        techBias = 0.65
    elseif forceAirAnswer then
        tempoMode = 'tempo'
        tempoBias = 0.45
        techBias = -0.35
    elseif tradeTechForTempo or punishGreed then
        tempoMode = 'tempo'
        tempoBias = 0.55
        techBias = -0.45
    elseif directive == 'expand' then
        tempoMode = 'balanced'
        tempoBias = 0.18
        techBias = -0.05
    elseif directive == 'stabilize' then
        tempoMode = 'balanced'
        tempoBias = -0.12
        techBias = 0.05
    end

    local aggressionBias = Clamp(
        (tempoBias * 0.55)
        + ((primaryTheater == 'Enemy') and 0.06 or 0)
        - ((primaryTheater == 'Home') and 0.08 or 0),
        -0.25,
        0.25)

    return {
        PunishGreed = punishGreed and true or false,
        ForceAirAnswer = forceAirAnswer and true or false,
        TradeMapForTech = tradeMapForTech and true or false,
        TradeTechForTempo = tradeTechForTempo and true or false,
        AttackWindow = signals.AttackWindow and true or false,
        RaidCentrality = raidCentrality,
        RaidDirective = (raidCentrality >= 0.58) and 'central' or 'opportunistic',
        TempoMode = tempoMode,
        TempoBias = tempoBias,
        TechBias = techBias,
        AggressionBias = aggressionBias,
    }
end

local function BuildGoalBiases(primaryTheater, directiveState, directive)
    local bias = {
        hold = 0,
        expand = 0,
        raid = 0,
        tech = 0,
        all_in = 0,
    }

    if directive == 'stabilize' then
        bias.hold = bias.hold + 2.2
        bias.expand = bias.expand - 1.2
        bias.raid = bias.raid - 1.0
        bias.tech = bias.tech - 0.4
        bias.all_in = bias.all_in - 1.6
    elseif directive == 'expand' then
        bias.expand = bias.expand + 1.8
        bias.hold = bias.hold + 0.2
        bias.raid = bias.raid - 0.2
        bias.tech = bias.tech - 0.2
    elseif directive == 'punish_greed' then
        bias.raid = bias.raid + 1.8
        bias.all_in = bias.all_in + 0.5
        bias.tech = bias.tech - 0.8
    elseif directive == 'force_air_answer' then
        bias.raid = bias.raid + 0.7
        bias.hold = bias.hold + 0.5
        bias.tech = bias.tech - 0.6
    elseif directive == 'trade_map_for_tech' then
        bias.tech = bias.tech + 1.8
        bias.hold = bias.hold + 0.4
        bias.expand = bias.expand - 0.4
        bias.raid = bias.raid - 0.6
    elseif directive == 'trade_tech_for_tempo' then
        bias.raid = bias.raid + 1.3
        bias.all_in = bias.all_in + 0.8
        bias.tech = bias.tech - 1.4
    end

    if primaryTheater == 'Home' then
        bias.hold = bias.hold + 0.8
        bias.raid = bias.raid - 0.4
        bias.expand = bias.expand - 0.2
    elseif primaryTheater == 'Front' then
        bias.hold = bias.hold + 0.4
        bias.all_in = bias.all_in + 0.2
    elseif primaryTheater == 'Enemy' then
        bias.raid = bias.raid + 0.6
        bias.all_in = bias.all_in + 0.2
    elseif primaryTheater == 'Navy' then
        bias.hold = bias.hold + 0.2
        bias.tech = bias.tech + 0.2
    end

    bias.raid = bias.raid + (directiveState.RaidCentrality * 1.3)
    bias.tech = bias.tech + (directiveState.TechBias * 1.2)
    bias.all_in = bias.all_in + math.max(0, directiveState.TempoBias - 0.25) * 0.8
    if directiveState.AttackWindow then
        bias.raid = bias.raid + 0.9
        bias.all_in = bias.all_in + 1.4
        bias.hold = bias.hold - 0.7
    end

    return bias
end

local function DetermineFocus(signals, primaryTheater, directive, directiveState)
    if primaryTheater == 'Home' then
        local approach = signals.Approach or {}
        return approach.StagePos or approach.Pos or signals.FrontPos,
            approach.StageZoneKey or approach.ZoneKey or signals.FrontZoneKey,
            (signals.ApproachClose and 'home_approach') or 'home_defense'
    end

    if primaryTheater == 'Front' then
        return signals.FrontPos, signals.FrontZoneKey, 'front_pressure'
    end

    if primaryTheater == 'Enemy' then
        if directive == 'expand' and signals.BestExpansionPos then
            return signals.BestExpansionPos, signals.BestExpansionZoneKey, 'expand_lane'
        end
        if signals.BestRaidPos then
            return signals.BestRaidPos, signals.BestRaidZoneKey, directiveState.RaidDirective == 'central' and 'central_raid' or 'opportunistic_raid'
        end
        return signals.EnemyMainPos, 'enemy_main', 'enemy_main'
    end

    return signals.EnemyMainPos or signals.FrontPos, 'naval_axis', 'naval_axis'
end

function Module.Update(aiBrain, now)
    aiBrain.OvermindRuntime = aiBrain.OvermindRuntime or {}
    local runtime = aiBrain.OvermindRuntime
    runtime.StrategicPlanner = runtime.StrategicPlanner or {
        Directive = 'stabilize',
        PrimaryTheater = 'Front',
        LastDirectiveSwitch = -999,
        LastTheaterSwitch = -999,
        LastLogTime = -999,
    }

    local state = runtime.StrategicPlanner
    local signals = BuildSignals(aiBrain, runtime, now)
    local theaterScores = ScoreTheaters(signals)
    local primaryTheater = PickStableKey(state, 'PrimaryTheater', 'LastTheaterSwitch', theaterScores, 'Front', now, 45, 0.35)
    local directiveScores = ScoreDirectives(signals, primaryTheater)
    local directive = PickStableKey(state, 'Directive', 'LastDirectiveSwitch', directiveScores, 'stabilize', now, 55, 0.45)
    local directiveState = BuildDirectiveState(signals, primaryTheater, directive)
    local goalBiases = BuildGoalBiases(primaryTheater, directiveState, directive)
    local focusPos, focusZoneKey, focusReason = DetermineFocus(signals, primaryTheater, directive, directiveState)
    local confidence = Clamp(
        ((signals.GraphReady and 0.12) or 0)
        + (((signals.HomeConfidence or 0) + (signals.FrontConfidence or 0) + (signals.EnemyConfidence or 0)) / 3) * 0.55
        + math.min(0.2, signals.MapControl * 0.2)
        + math.min(0.13, signals.BestRaidScore * 0.008),
        0,
        1)

    state.Time = now
    state.TheaterScores = theaterScores
    state.PrimaryTheater = primaryTheater
    state.DirectiveScores = directiveScores
    state.Directive = directive
    state.FocusPos = focusPos
    state.FocusZoneKey = focusZoneKey
    state.FocusReason = focusReason
    state.GoalBiases = goalBiases
    state.RaidCentrality = directiveState.RaidCentrality
    state.RaidDirective = directiveState.RaidDirective
    state.TempoMode = directiveState.TempoMode
    state.TempoBias = directiveState.TempoBias
    state.TechBias = directiveState.TechBias
    state.AggressionBias = directiveState.AggressionBias
    state.PunishGreed = directiveState.PunishGreed
    state.ForceAirAnswer = directiveState.ForceAirAnswer
    state.TradeMapForTech = directiveState.TradeMapForTech
    state.TradeTechForTempo = directiveState.TradeTechForTempo
    state.Confidence = confidence
    state.Signals = {
        Phase = signals.Phase,
        MapControl = signals.MapControl,
        BestExpansionScore = signals.BestExpansionScore,
        BestRaidScore = signals.BestRaidScore,
        HomePressure = signals.HomePressure,
        FrontPressure = signals.FrontPressure,
        EnemyPressure = signals.EnemyPressure,
        NavyPressure = signals.NavyPressure,
        RelativePower = signals.RelativePower,
        GreedWindow = signals.GreedWindow,
        PushWindow = signals.PushWindow,
        ForceAirAnswerCandidate = signals.ForceAirAnswerCandidate,
        DurableSurplus = signals.DurableSurplus,
        RecoveryActive = signals.RecoveryActive,
        ApproachThreat = signals.ApproachThreat,
        ApproachDistance = signals.ApproachDistance,
    }
    runtime.StrategicPlanner = state

    if now - (state.LastLogTime or -999) >= 30 then
        state.LastLogTime = now
        LOG(string.format('*OVERMIND STRAT A%d t=%.1f theater=%s dir=%s raid=%s:%.2f tempo=%s tb=%.2f tech=%.2f air=%d greed=%d focus=%s conf=%.2f map=%.2f press=%.1f/%.1f/%.1f',
            aiBrain:GetArmyIndex(),
            now,
            state.PrimaryTheater or 'Front',
            state.Directive or 'stabilize',
            state.RaidDirective or 'opportunistic',
            state.RaidCentrality or 0,
            state.TempoMode or 'balanced',
            state.TempoBias or 0,
            state.TechBias or 0,
            state.ForceAirAnswer and 1 or 0,
            state.PunishGreed and 1 or 0,
            state.FocusReason or 'none',
            state.Confidence or 0,
            signals.MapControl or 0,
            signals.HomePressure or 0,
            signals.FrontPressure or 0,
            signals.EnemyPressure or 0))
    end
end

function Update(aiBrain, now)
    return Module.Update(aiBrain, now)
end

return Module
