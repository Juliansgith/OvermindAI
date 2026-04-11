local OvermindMemory = import('/mods/OvermindAI/lua/AI/Overmind/Memory.lua')

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

local function Distance2D(a, b)
    local dx = (a[1] or 0) - (b[1] or 0)
    local dz = (a[3] or 0) - (b[3] or 0)
    return math.sqrt((dx * dx) + (dz * dz))
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

local function GetOwnMainPos(aiBrain, runtime)
    local zone = runtime.ZoneModel or {}
    if zone.OwnMainPos then
        return zone.OwnMainPos
    end
    if aiBrain.BuilderManagers and aiBrain.BuilderManagers.MAIN and aiBrain.BuilderManagers.MAIN.Position then
        return aiBrain.BuilderManagers.MAIN.Position
    end
    local sx, sz = aiBrain:GetArmyStartPos()
    return { sx, 0, sz }
end

local function EstimateReclaimMassAtPos(pos, radius)
    if not pos then
        return 0, 0
    end

    local r = radius or 18
    local rect = Rect((pos[1] or 0) - r, (pos[3] or 0) - r, (pos[1] or 0) + r, (pos[3] or 0) + r)
    local reclaimables = GetReclaimablesInRect(rect) or {}
    local totalMass = 0
    local count = 0
    for _, reclaim in reclaimables do
        local mass = reclaim and reclaim.MaxMassReclaim or 0
        if mass > 0 then
            totalMass = totalMass + (mass * (reclaim.ReclaimLeft or 1))
            count = count + 1
            if count >= 24 and totalMass >= 750 then
                break
            end
        end
    end
    return totalMass, count
end

local function ScoreBattlefieldTarget(aiBrain, runtime, ownPos, pos, baseScore, reclaimWeight)
    if not pos then
        return -999999, 0
    end

    local reclaimMass = EstimateReclaimMassAtPos(pos, 18)
    local distHome = Distance2D(ownPos, pos)
    local threat = aiBrain:GetThreatAtPosition(pos, 1, true, 'AntiSurface') or 0
    local friendlyLand = aiBrain:GetNumUnitsAroundPoint(categories.MOBILE * categories.LAND - categories.ENGINEER - categories.SCOUT - categories.COMMAND, pos, 28, 'Ally') or 0
    local enemyLand = aiBrain:GetNumUnitsAroundPoint(categories.MOBILE * categories.LAND - categories.ENGINEER - categories.SCOUT - categories.COMMAND, pos, 28, 'Enemy') or 0
    local routeRisk = OvermindMemory.GetRouteRisk(aiBrain, ownPos, pos, 4, 46)

    local score =
        (baseScore or 0)
        + (reclaimMass * (reclaimWeight or 0.0065))
        + math.min(3.2, math.max(0, distHome - 70) * 0.018)
        + (friendlyLand * 0.6)
        - (enemyLand * 0.95)
        - (threat * 3.5)
        - (routeRisk * 1.2)

    return score, reclaimMass
end

local function BuildBattlefieldObjectives(aiBrain, runtime, signals, state, now)
    local ownPos = GetOwnMainPos(aiBrain, runtime)
    local policy = runtime.EcoPolicy or {}
    local candidateList = {}
    local reclaimFieldPos = false
    local reclaimFieldScore = 0
    local outerContestPos = false
    local outerContestValue = 0

    local function ConsiderCandidate(pos, baseScore, reclaimWeight)
        if not pos then
            return
        end
        local score, reclaimMass = ScoreBattlefieldTarget(aiBrain, runtime, ownPos, pos, baseScore, reclaimWeight)
        table.insert(candidateList, {
            Pos = pos,
            Score = score,
            ReclaimMass = reclaimMass,
        })
    end

    ConsiderCandidate(signals.BestRaidPos, (signals.BestRaidScore or 0) * 0.34 + 2.4, 0.0075)
    ConsiderCandidate(signals.BestExpansionPos, (signals.BestExpansionScore or 0) * 0.12 + 2.0, 0.007)
    ConsiderCandidate(signals.FrontPos, (signals.FrontPressure or 0) * 0.9 + 1.6, 0.0085)

    table.sort(candidateList, function(a, b)
        return (a.Score or -999999) > (b.Score or -999999)
    end)

    local best = candidateList[1]
    if best and best.Score > 1.8 then
        outerContestPos = best.Pos
        outerContestValue = best.Score
        if (best.ReclaimMass or 0) >= 110 then
            reclaimFieldPos = best.Pos
            reclaimFieldScore = best.ReclaimMass
        end
    end

    local strongHomeCollapse = signals.ACUCrisisActive
        or signals.ApproachClose
        or signals.HomePressure >= math.max(6.0, (signals.FrontPressure * 1.45) + 1.6)
    local outerRetentionWanted =
        not strongHomeCollapse
        and not signals.RecoveryActive
        and (signals.PrioritizeProduction or signals.ContestMapMode or signals.StructuralContestMap)
        and (
            (signals.ContestedZones or 0) >= 2
            or (policy.OuterHoldShare or 0) < 0.58
            or (policy.SafeForwardMexCount or 0) >= 2
            or (outerContestValue >= 3.0)
            or (reclaimFieldScore >= 160)
        )

    state.OuterRetentionUntil = state.OuterRetentionUntil or -999
    if outerRetentionWanted then
        state.OuterRetentionUntil = now + 72
    elseif strongHomeCollapse and signals.HomePressure >= math.max(7.0, (signals.FrontPressure * 1.55) + 2.0) then
        state.OuterRetentionUntil = now - 1
    end

    local outerRetentionActive = not strongHomeCollapse and (
        outerRetentionWanted
        or (now < (state.OuterRetentionUntil or -999))
    )
    local reclaimFirst = outerRetentionActive
        and reclaimFieldPos ~= false
        and reclaimFieldScore >= 140
        and signals.HomePressure < 4.5
        and not signals.ACUCrisisActive

    if not outerContestPos and outerRetentionActive then
        outerContestPos = signals.BestExpansionPos or signals.BestRaidPos or signals.FrontPos
        outerContestValue = math.max(outerContestValue, (signals.BestExpansionScore or 0) * 0.08)
    end

    return {
        OuterRetentionActive = outerRetentionActive and true or false,
        ReclaimFirst = reclaimFirst and true or false,
        OuterContestPos = outerContestPos,
        OuterContestValue = outerContestValue or 0,
        ReclaimFieldPos = reclaimFieldPos,
        ReclaimFieldScore = reclaimFieldScore or 0,
        StrongHomeCollapse = strongHomeCollapse and true or false,
    }
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
    local prioritizeProduction = policy.PrioritizeProduction == true
    local contestMapMode = policy.ContestMapMode == true
    local preferTempoFromSurplus = policy.PreferTempoFromSurplus == true
    local structuralContestMap = policy.StructuralContestMap == true
    local macro = runtime.MacroController or {}
    local macroObjective = macro.Phase or ((runtime.ProductionDirector or {}).MacroObjective) or 'land_factory_floor'
    local transitionLocked = macro.TransitionLocked == true
    local acuCrisisActive = now < (runtime.ACUCrisisUntil or -999)

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
            relativePower >= 0.98
            and mapControl >= 0.34
            and not ecoWeak
            and not recoveryActive
            and not transitionLocked
            and not approachClose
            and (((frontTheater.PressureEMA or frontTheater.Pressure or 0) >= 1.2) or bestRaidScore >= 18)
            and ((forceStats.MainLine or 0) + (forceStats.Artillery or 0) >= math.max(16, (forceStats.BaseGuard or 0) + 6))
        ) and true or false,
        DesperationCounterstrike = (
            (acuCrisisActive or (((raid.UnderLandHarass == true) or approachClose or ((homeTheater.PressureEMA or homeTheater.Pressure or 0) >= 4.0))))
            and ((forceStats.MainLine or 0) + (forceStats.Artillery or 0) >= math.max(14, (forceStats.BaseGuard or 0) + 4))
            and (relativePower <= 1.08 or opp.Posture == 'land_push' or opp.T2Push == true or (homeTheater.Confidence or 0) < 0.45)
        ) and true or false,
        ACUCrisisActive = acuCrisisActive,
        PrioritizeProduction = prioritizeProduction,
        ContestMapMode = contestMapMode,
        PreferTempoFromSurplus = preferTempoFromSurplus,
        StructuralContestMap = structuralContestMap,
        MacroObjective = macroObjective,
        TransitionLocked = transitionLocked,
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
        + (signals.ACUCrisisActive and 5.0 or 0)

    scores.Front =
        (signals.FrontPressure * 0.8)
        + (signals.ContestedZones * 0.8)
        + (signals.PushWindow and 1.4 or 0)
        + ((signals.ApproachReal and not signals.ApproachClose) and 0.9 or 0)
        + ((signals.MainlineUnits <= math.max(2, signals.BaseGuardUnits - 1)) and 0.9 or 0)
        - (signals.ACUCrisisActive and 1.2 or 0)

    scores.Enemy =
        (signals.BestRaidScore * 0.08)
        + (signals.BestExpansionScore * 0.03)
        + (signals.GreedWindow and 1.6 or 0)
        + (signals.DurableSurplus and 0.6 or 0)
        + math.max(0, signals.RelativePower - 0.96) * 1.2
        - (signals.ApproachClose and 1.4 or 0)
        - (signals.RecoveryActive and 0.8 or 0)
        - (signals.ACUCrisisActive and 1.6 or 0)

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
        + (signals.DesperationCounterstrike and 0.9 or 0)
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
        + (signals.DesperationCounterstrike and 1.5 or 0)
        + (signals.BestRaidScore * 0.04)
        + ((primaryTheater == 'Front') and 0.5 or 0)
        + ((primaryTheater == 'Enemy') and 0.4 or 0)
        - (signals.DurableSurplus and 0.4 or 0)
        - (signals.RecoveryActive and 1.2 or 0)

    if signals.AttackWindow then
        scores.stabilize = scores.stabilize - 1.4
        scores.expand = scores.expand - 0.4
    end
    if signals.OuterRetentionActive then
        scores.stabilize = scores.stabilize - (signals.StrongHomeCollapse and 0.3 or 1.7)
        scores.expand = scores.expand + 1.0 + math.min(1.0, (signals.OuterContestValue or 0) * 0.12)
        scores.punish_greed = scores.punish_greed + 0.35 + math.min(0.8, (signals.OuterContestValue or 0) * 0.07)
        scores.trade_tech_for_tempo = scores.trade_tech_for_tempo + 0.45 + math.min(0.6, (signals.OuterContestValue or 0) * 0.05)
    end
    if signals.DesperationCounterstrike then
        scores.stabilize = scores.stabilize - 1.4
        scores.expand = scores.expand - 0.5
        scores.punish_greed = scores.punish_greed + 1.0
        scores.trade_tech_for_tempo = scores.trade_tech_for_tempo + 1.5
    end
    if signals.ACUCrisisActive then
        scores.stabilize = scores.stabilize + 0.8
        scores.expand = scores.expand - 0.6
        scores.force_air_answer = scores.force_air_answer - 4.0
        scores.trade_map_for_tech = scores.trade_map_for_tech - 1.2
        scores.trade_tech_for_tempo = scores.trade_tech_for_tempo + 0.9
        scores.punish_greed = scores.punish_greed + 0.4
    end
    if signals.TransitionLocked and not signals.DesperationCounterstrike then
        scores.force_air_answer = scores.force_air_answer - 2.0
        scores.expand = scores.expand - 0.8
        scores.stabilize = scores.stabilize - 0.3
        scores.trade_map_for_tech = scores.trade_map_for_tech + 0.9
        scores.trade_tech_for_tempo = scores.trade_tech_for_tempo + 0.7
    end
    if signals.MacroObjective == 'first_land_hq'
        or signals.MacroObjective == 'first_t2_engineer'
        or signals.MacroObjective == 'first_t2_power' then
        scores.force_air_answer = scores.force_air_answer - 1.4
        scores.stabilize = scores.stabilize - 0.5
        scores.trade_tech_for_tempo = scores.trade_tech_for_tempo + 0.9
        scores.trade_map_for_tech = scores.trade_map_for_tech + 0.6
    end
    if signals.PrioritizeProduction then
        scores.trade_tech_for_tempo = scores.trade_tech_for_tempo + 1.2
        scores.punish_greed = scores.punish_greed + 0.5
        scores.trade_map_for_tech = scores.trade_map_for_tech - 1.2
        scores.expand = scores.expand - 0.4
        scores.stabilize = scores.stabilize - 0.3
    end
    if signals.ContestMapMode then
        scores.trade_tech_for_tempo = scores.trade_tech_for_tempo + 0.7
        scores.punish_greed = scores.punish_greed + 0.3
        scores.force_air_answer = scores.force_air_answer - (signals.ApproachClose and 0.0 or 0.8)
        scores.trade_map_for_tech = scores.trade_map_for_tech - 0.7
    end
    if signals.StructuralContestMap then
        scores.trade_tech_for_tempo = scores.trade_tech_for_tempo + 0.4
        scores.punish_greed = scores.punish_greed + 0.2
        scores.expand = scores.expand - 0.2
    end
    if signals.PreferTempoFromSurplus then
        scores.trade_tech_for_tempo = scores.trade_tech_for_tempo + 0.5
        scores.trade_map_for_tech = scores.trade_map_for_tech - 0.4
    end
    if signals.ReclaimFirst then
        scores.expand = scores.expand + 0.9
        scores.stabilize = scores.stabilize - 0.75
        scores.punish_greed = scores.punish_greed + 0.45
        scores.trade_map_for_tech = scores.trade_map_for_tech - 0.6
        scores.trade_tech_for_tempo = scores.trade_tech_for_tempo + 0.8
    end

    return scores
end

local function BuildDirectiveState(signals, primaryTheater, directive)
    local punishGreed = directive == 'punish_greed'
        or signals.GreedWindow
        or (signals.PrioritizeProduction and signals.AttackWindow)
    local tradeMapForTech = directive == 'trade_map_for_tech'
        and not signals.PrioritizeProduction
    local tradeTechForTempo = directive == 'trade_tech_for_tempo'
        or (directive == 'punish_greed' and not signals.DurableSurplus)
        or signals.PrioritizeProduction
    local forceAirAnswer = (directive == 'force_air_answer' or signals.ForceAirAnswerCandidate)
        and not (signals.MacroObjective == 'first_land_hq' or signals.MacroObjective == 'first_t2_engineer')
        and not signals.TransitionLocked
        and not signals.ACUCrisisActive
        and (not signals.PrioritizeProduction or signals.ApproachClose or signals.HomePressure >= 4.5 or signals.FrontPressure >= 5.0)

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
        tempoBias = signals.PrioritizeProduction and 0.68 or 0.55
        techBias = signals.PrioritizeProduction and -0.58 or -0.45
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
        DesperationCounterstrike = signals.DesperationCounterstrike and true or false,
        MacroObjective = signals.MacroObjective or 'land_factory_floor',
        TransitionLocked = signals.TransitionLocked and true or false,
        RaidCentrality = raidCentrality,
        RaidDirective = (raidCentrality >= 0.58) and 'central' or 'opportunistic',
        TempoMode = tempoMode,
        TempoBias = tempoBias,
        TechBias = techBias,
        AggressionBias = aggressionBias,
        OuterRetentionActive = signals.OuterRetentionActive and true or false,
        ReclaimFirst = signals.ReclaimFirst and true or false,
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
    if directiveState.DesperationCounterstrike then
        bias.raid = bias.raid + 1.4
        bias.all_in = bias.all_in + 2.6
        bias.hold = bias.hold - 1.2
    end
    if directiveState.TransitionLocked and not directiveState.DesperationCounterstrike then
        bias.tech = bias.tech + 1.0
        bias.hold = bias.hold - 0.3
    end
    if directiveState.MacroObjective == 'first_land_hq'
        or directiveState.MacroObjective == 'first_t2_engineer'
        or directiveState.MacroObjective == 'first_t2_power' then
        bias.tech = bias.tech + 0.8
        bias.raid = bias.raid + 0.4
        bias.hold = bias.hold - 0.4
    end
    if directiveState.OuterRetentionActive then
        bias.expand = bias.expand + 0.7
        bias.raid = bias.raid + 0.8
        bias.hold = bias.hold - 0.7
    end
    if directiveState.ReclaimFirst then
        bias.expand = bias.expand + 0.9
        bias.raid = bias.raid + 0.35
        bias.tech = bias.tech - 0.45
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
        if directiveState.OuterRetentionActive and signals.ReclaimFieldPos then
            return signals.ReclaimFieldPos, signals.FrontZoneKey, 'reclaim_field'
        end
        if directiveState.OuterRetentionActive and signals.OuterContestPos then
            return signals.OuterContestPos, signals.FrontZoneKey, 'outer_contest'
        end
        return signals.FrontPos, signals.FrontZoneKey, 'front_pressure'
    end

    if primaryTheater == 'Enemy' then
        if directiveState.OuterRetentionActive and signals.ReclaimFieldPos then
            return signals.ReclaimFieldPos, signals.BestExpansionZoneKey or signals.BestRaidZoneKey, 'reclaim_field'
        end
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
    local battlefield = BuildBattlefieldObjectives(aiBrain, runtime, signals, state, now)
    for key, value in pairs(battlefield) do
        signals[key] = value
    end
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
    state.AttackWindow = directiveState.AttackWindow
    state.DesperationCounterstrike = directiveState.DesperationCounterstrike
    state.MacroObjective = directiveState.MacroObjective
    state.Confidence = confidence
    state.OuterRetentionActive = battlefield.OuterRetentionActive and true or false
    state.ReclaimFirst = battlefield.ReclaimFirst and true or false
    state.OuterContestPos = battlefield.OuterContestPos
    state.OuterContestValue = battlefield.OuterContestValue or 0
    state.ReclaimFieldPos = battlefield.ReclaimFieldPos
    state.ReclaimFieldScore = battlefield.ReclaimFieldScore or 0
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
        OuterRetentionActive = signals.OuterRetentionActive and true or false,
        ReclaimFirst = signals.ReclaimFirst and true or false,
        OuterContestValue = signals.OuterContestValue or 0,
        ReclaimFieldScore = signals.ReclaimFieldScore or 0,
    }
    runtime.StrategicPlanner = state

    if now - (state.LastLogTime or -999) >= 30 then
        state.LastLogTime = now
        LOG(string.format('*OVERMIND STRAT A%d t=%.1f theater=%s dir=%s raid=%s:%.2f tempo=%s tb=%.2f tech=%.2f air=%d greed=%d outer=%d reclaim=%.0f focus=%s conf=%.2f map=%.2f press=%.1f/%.1f/%.1f',
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
            state.OuterRetentionActive and 1 or 0,
            state.ReclaimFieldScore or 0,
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
