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

local function SumRoleField(rolePlan, keys, field)
    local total = 0
    for _, key in keys do
        local entry = rolePlan[key]
        total = total + ((entry and entry[field]) or 0)
    end
    return total
end

local function GetRoleField(rolePlan, key, field)
    local entry = rolePlan[key]
    return (entry and entry[field]) or 0
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

local function CountIdleFactories(aiBrain)
    local idle = 0
    local factories = aiBrain:GetListOfUnits(categories.FACTORY * categories.STRUCTURE, false, true)
    if not factories then
        return 0
    end

    for _, fac in factories do
        if fac and not fac.Dead then
            local q = fac.GetCommandQueue and fac:GetCommandQueue() or false
            if not q or table.getn(q) == 0 then
                idle = idle + 1
            end
        end
    end
    return idle
end

function Capture(aiBrain, now)
    local runtime = aiBrain.OvermindRuntime or {}
    aiBrain.OvermindRuntime = runtime

    runtime.Telemetry = runtime.Telemetry or {
        Samples = {},
        Window = 90,
        Checkpoints = {},
    }

    local tele = runtime.Telemetry
    local eco = runtime.EcoState or {}
    local opp = runtime.OpponentModel or {}
    local planner = runtime.StrategicPlanner or {}
    local mem = aiBrain.OvermindMemory or {}
    local recovery = runtime.Recovery or {}
    local raid = runtime.RaidDefense or {}
    local prod = runtime.ProductionDirector or {}
    local intel = runtime.IntelModel or {}
    local clusters = runtime.EnemyClusterTracker or {}
    local force = runtime.ForceDirector or runtime.ForceManager or {}
    local graph = runtime.ZoneGraph or {}
    local tasks = force.Tasks or {}
    local roleDemand = force.RoleDemand or {}
    local forceStats = force.Stats or {}
    local current = prod.Current or {}
    local currentFactories = current.Factories or {}
    local factoryTask = current.FactoryTask or {}
    local engState = runtime.EngineerState or {}
    local structureTask = engState.UnfinishedStructureTask or {}
    local approachCluster = clusters.ApproachCluster or {}
    local capacity = prod.CapacityPlan or {}
    local rolePlan = prod.RolePlan or {}
    local structurePlan = prod.StructurePlan or {}
    local techPlan = prod.TechPlan or {}
    local riskHotspots = mem.RiskHotspots or {}
    local ownPos = GetMainPos(aiBrain, runtime)
    local factoryCount = aiBrain:GetCurrentUnits(categories.FACTORY * categories.STRUCTURE) or 0
    local engineerCount = aiBrain:GetCurrentUnits(categories.ENGINEER * categories.MOBILE) or 0
    local defenseCount = aiBrain:GetCurrentUnits(categories.DEFENSE * categories.STRUCTURE) or 0
    local baseEngineers = aiBrain:GetNumUnitsAroundPoint(categories.ENGINEER * categories.MOBILE, ownPos, 70, 'Ally') or 0
    local acuPos = false
    local acuUnits = aiBrain:GetListOfUnits(categories.COMMAND, false, true)
    if acuUnits and table.getn(acuUnits) > 0 and acuUnits[1] and not acuUnits[1].Dead then
        acuPos = acuUnits[1]:GetPosition()
    end
    local acuDist = runtime.LastAcuDistanceFromBase or 0
    local acuEscort = 0
    if acuPos then
        acuDist = Distance2D(ownPos, acuPos)
        acuEscort = aiBrain:GetNumUnitsAroundPoint(categories.MOBILE * (categories.LAND + categories.AIR) - categories.ENGINEER - categories.SCOUT - categories.COMMAND, acuPos, 32, 'Ally') or 0
    end

    local sample = {
        Time = now,
        Goal = runtime.StrategyGoal or 'hold',
        StrategyDirective = planner.Directive or 'stabilize',
        StrategyTheater = planner.PrimaryTheater or 'Front',
        StrategyRaidDirective = planner.RaidDirective or 'opportunistic',
        StrategyRaidCentrality = planner.RaidCentrality or 0,
        StrategyTempo = planner.TempoMode or 'balanced',
        StrategyTempoBias = planner.TempoBias or 0,
        Posture = opp.Posture or 'unknown',
        Pivot = opp.LikelyPivot or 'balanced',
        OppConfidence = (opp.Confidence and opp.Confidence.Global) or 0,
        OppFrontConfidence = (opp.Confidence and opp.Confidence.Front) or 0,
        OppFrontPressure = (opp.Theaters and opp.Theaters.Front and opp.Theaters.Front.PressureEMA) or 0,
        OppHomePressure = (opp.Theaters and opp.Theaters.Home and opp.Theaters.Home.PressureEMA) or 0,
        Aggression = runtime.Aggression or 1,
        MassStored = eco.MassStored or 0,
        EnergyStored = eco.EnergyStored or 0,
        MassTrend = eco.MassTrend or 0,
        EnergyTrend = eco.EnergyTrend or 0,
        UnitLoad = eco.UnitLoad or 0,
        CombatMomentum = runtime.CombatMomentum or 0,
        Kills = mem.KillMassRecent or 0,
        Losses = mem.LossMassRecent or 0,
        RiskHotspots = table.getn(riskHotspots),
        FactoryCount = factoryCount,
        IdleFactories = CountIdleFactories(aiBrain),
        EngineerCount = engineerCount,
        BaseEngineers = baseEngineers,
        DefenseCount = defenseCount,
        ACUDistance = acuDist,
        ACUEscort = acuEscort,
        MapControl = (runtime.IntelModel and runtime.IntelModel.MapControl) or (runtime.ZoneGraph and runtime.ZoneGraph.MapControl) or (runtime.ZoneModel and runtime.ZoneModel.MapControl) or 0,
        ProductionStagnation = recovery.StagnationTime or 0,
        RecoveryFactory = recovery.ForceFactoryRecovery and 1 or 0,
        RecoveryScout = recovery.ForceScoutRecovery and 1 or 0,
        RecoveryBaseEng = recovery.ForceBaseEngineerRecovery and 1 or 0,
        RecoveryDefense = recovery.ForceDefenseRecovery and 1 or 0,
        FactoryQueueDeficit = recovery.FactoryQueueDeficit or 0,
        FactoryQueueDeficitRatio = recovery.FactoryQueueDeficitRatio or 0,
        MacroPhase = runtime.MacroPhase or (runtime.EcoPolicy and runtime.EcoPolicy.MacroPhase) or 'unknown',
        ProdMode = prod.Mode or 'none',
        LandFacNeed = capacity.LandTarget or 0,
        AirFacNeed = capacity.AirTarget or 0,
        SeaFacNeed = capacity.SeaTarget or 0,
        LandStrengthHave = (current.DomainStrength and current.DomainStrength.Land) or 0,
        AirStrengthHave = (current.DomainStrength and current.DomainStrength.Air) or 0,
        SeaStrengthHave = (current.DomainStrength and current.DomainStrength.Navy) or 0,
        LandStrengthNeed = capacity.LandStrengthTarget or SumRoleField(rolePlan, { 'Engineer', 'LandDirect', 'LandAA', 'LandIndirect', 'LandScout' }, 'DesiredStrength'),
        AirStrengthNeed = capacity.AirStrengthTarget or SumRoleField(rolePlan, { 'AirFighter', 'AirBomber', 'AirScout' }, 'DesiredStrength'),
        SeaStrengthNeed = capacity.SeaStrengthTarget or SumRoleField(rolePlan, { 'SeaSurface', 'SeaSub', 'SeaAA' }, 'DesiredStrength'),
        LandStrengthGap = capacity.LandStrengthGap or SumRoleField(rolePlan, { 'Engineer', 'LandDirect', 'LandAA', 'LandIndirect', 'LandScout' }, 'StrengthGap'),
        AirStrengthGap = capacity.AirStrengthGap or SumRoleField(rolePlan, { 'AirFighter', 'AirBomber', 'AirScout' }, 'StrengthGap'),
        SeaStrengthGap = capacity.SeaStrengthGap or SumRoleField(rolePlan, { 'SeaSurface', 'SeaSub', 'SeaAA' }, 'StrengthGap'),
        LandFacHave = (currentFactories.Land and currentFactories.Land.Total) or 0,
        AirFacHave = (currentFactories.Air and currentFactories.Air.Total) or 0,
        SeaFacHave = (currentFactories.Navy and currentFactories.Navy.Total) or 0,
        FactoryGrowthPaused = capacity.PauseFactoryGrowth and 1 or 0,
        QueueDiscipline = capacity.QueueDiscipline or 'normal',
        FactoryTaskActive = factoryTask.Active and 1 or 0,
        FactoryTaskDomain = factoryTask.Domain or 'none',
        FactoryTaskAssigned = factoryTask.AssignedBuilders or 0,
        FactoryTaskRequired = factoryTask.RequiredBuilders or 0,
        FactoryTaskStall = factoryTask.StallTime or 0,
        StructureTaskActive = structureTask.Active and 1 or 0,
        StructureTaskKind = structureTask.Kind or 'none',
        StructureTaskAssigned = structureTask.AssignedBuilders or 0,
        StructureTaskRequired = structureTask.RequiredBuilders or 0,
        StructureTaskStall = structureTask.StallTime or 0,
        EngineerStrengthHave = GetRoleField(rolePlan, 'Engineer', 'CurrentStrength'),
        EngineerStrengthNeed = GetRoleField(rolePlan, 'Engineer', 'DesiredStrength'),
        EngineerUnitsHave = GetRoleField(rolePlan, 'Engineer', 'CurrentUnits'),
        EngineerUnitsNeed = GetRoleField(rolePlan, 'Engineer', 'DesiredUnits'),
        StructRadar = structurePlan.Radar or 0,
        StructBaseAA = structurePlan.BaseAA or 0,
        StructPD = structurePlan.PD or 0,
        TechEligible = techPlan.EligibleForTech and 1 or 0,
        TechBlock = techPlan.BlockReason or 'none',
        ExtractorUpgrades = techPlan.UpgradeExtractors and 1 or 0,
        ExtractorUpgradeMode = techPlan.AggressiveExtractorUpgrades and 'aggr' or (techPlan.ExtractorUpgradeReason or 'none'),
        ExtractorUpgradePriority = techPlan.ExtractorUpgradePriority or 0,
        GraphNodes = table.getn(graph.Nodes or {}),
        GraphContested = graph.ContestedZones or 0,
        GraphSource = graph.GraphSource or ((graph.NavGraphBuilt and 'nav') or ((graph.StaticBuilt and 'heuristic') or 'none')),
        IntelContested = intel.ContestedZones or 0,
        IntelStale = intel.StaleZones or 0,
        ClusterCount = clusters.ClusterCount or 0,
        ClusterThreat = approachCluster.TotalThreat or 0,
        ClusterDistance = approachCluster.HomeDistance or 999,
        ForceGuard = forceStats.BaseGuard or 0,
        ForceRaid = forceStats.Raiders or 0,
        ForceMain = forceStats.MainLine or 0,
        ForceArt = forceStats.Artillery or 0,
        TaskCount = table.getn(force.TaskList or {}),
        TaskFrontState = (tasks.front_hold and tasks.front_hold.ExecutionState) or 'none',
        TaskBaseState = (tasks.base_guard and tasks.base_guard.ExecutionState) or 'none',
        TaskRaidState = (tasks.raid and tasks.raid.ExecutionState) or 'none',
        DemandGuard = roleDemand.BaseGuard or 0,
        DemandRaid = roleDemand.Raider or 0,
        DemandMain = roleDemand.MainLine or 0,
        LandHarass = raid.UnderLandHarass and 1 or 0,
        AirHarass = raid.UnderAirHarass and 1 or 0,
        LandHarassEnemies = raid.LastLandEnemyCount or 0,
        AirHarassEnemies = raid.LastAirEnemyCount or 0,
        BomberWatch = (((runtime.OpponentModel or {}).Bomber or 0) >= 1) and 1 or 0,
        BomberPanic = ((raid.BomberPanicUntil or -999) > now) and 1 or 0,
        ExposedMexAirRaid = raid.ExposedMexUnderAirRaid and 1 or 0,
        BomberEnemies = raid.LastBomberEnemyCount or 0,
    }

    table.insert(tele.Samples, sample)
    if table.getn(tele.Samples) > tele.Window then
        table.remove(tele.Samples, 1)
    end

    runtime.LastTelemetry = sample

    local checkpoints = { 240, 480, 720 }
    for _, checkpoint in checkpoints do
        if now >= checkpoint and not tele.Checkpoints[checkpoint] then
            tele.Checkpoints[checkpoint] = true
            LOG(string.format('*OVERMIND CHECKPOINT A%d t=%ds fac=%d idleFac=%d qdef=%d qratio=%.2f harL=%d(%d) harA=%d(%d) raid=%d/%d/%d(%d) eng=%d baseEng=%d def=%d acuDist=%.1f acuEsc=%d risk=%d map=%.2f stagn=%.1f rf=%d rs=%d re=%d rd=%d phase=%s strat=%s/%s/%s:%.2f graph=%s/%d/%d intel=%d/%d cluster=%d:%.1f/%.0f force=%d/%d/%d tasks=%d[%s/%s/%s] goal=%s prod=%s fac=%d/%d/%d->%d/%d/%d pause=%d q=%s ft=%d:%s:%d/%d:%.1f st=%d:%s:%d/%d:%.1f str=%.1f/%.1f/%.1f->%.1f/%.1f/%.1f gap=%.1f/%.1f/%.1f engp=%.1f/%.1f(%d/%d) mex=%d:%s:%.2f struct=%d/%d/%d tech=%d:%s',
                aiBrain:GetArmyIndex(),
                checkpoint,
                sample.FactoryCount or 0,
                sample.IdleFactories or 0,
                sample.FactoryQueueDeficit or 0,
                sample.FactoryQueueDeficitRatio or 0,
                sample.LandHarass or 0,
                sample.LandHarassEnemies or 0,
                sample.AirHarass or 0,
                sample.AirHarassEnemies or 0,
                sample.BomberWatch or 0,
                sample.BomberPanic or 0,
                sample.ExposedMexAirRaid or 0,
                sample.BomberEnemies or 0,
                sample.EngineerCount or 0,
                sample.BaseEngineers or 0,
                sample.DefenseCount or 0,
                sample.ACUDistance or 0,
                sample.ACUEscort or 0,
                sample.RiskHotspots or 0,
                sample.MapControl or 0,
                sample.ProductionStagnation or 0,
                sample.RecoveryFactory or 0,
                sample.RecoveryScout or 0,
                sample.RecoveryBaseEng or 0,
                sample.RecoveryDefense or 0,
                sample.MacroPhase or 'unknown',
                sample.StrategyDirective or 'stabilize',
                sample.StrategyTheater or 'Front',
                sample.StrategyRaidDirective or 'opportunistic',
                sample.StrategyRaidCentrality or 0,
                sample.GraphSource or 'none',
                sample.GraphNodes or 0,
                sample.GraphContested or 0,
                sample.IntelContested or 0,
                sample.IntelStale or 0,
                sample.ClusterCount or 0,
                sample.ClusterThreat or 0,
                sample.ClusterDistance or 999,
                sample.ForceGuard or 0,
                sample.ForceRaid or 0,
                sample.ForceMain or 0,
                sample.TaskCount or 0,
                sample.TaskFrontState or 'none',
                sample.TaskBaseState or 'none',
                sample.TaskRaidState or 'none',
                sample.Goal or 'hold',
                sample.ProdMode or 'none',
                sample.LandFacHave or 0,
                sample.AirFacHave or 0,
                sample.SeaFacHave or 0,
                sample.LandFacNeed or 0,
                sample.AirFacNeed or 0,
                sample.SeaFacNeed or 0,
                sample.FactoryGrowthPaused or 0,
                sample.QueueDiscipline or 'normal',
                sample.FactoryTaskActive or 0,
                sample.FactoryTaskDomain or 'none',
                sample.FactoryTaskAssigned or 0,
                sample.FactoryTaskRequired or 0,
                sample.FactoryTaskStall or 0,
                sample.StructureTaskActive or 0,
                sample.StructureTaskKind or 'none',
                sample.StructureTaskAssigned or 0,
                sample.StructureTaskRequired or 0,
                sample.StructureTaskStall or 0,
                sample.LandStrengthHave or 0,
                sample.AirStrengthHave or 0,
                sample.SeaStrengthHave or 0,
                sample.LandStrengthNeed or 0,
                sample.AirStrengthNeed or 0,
                sample.SeaStrengthNeed or 0,
                sample.LandStrengthGap or 0,
                sample.AirStrengthGap or 0,
                sample.SeaStrengthGap or 0,
                sample.EngineerStrengthHave or 0,
                sample.EngineerStrengthNeed or 0,
                sample.EngineerUnitsHave or 0,
                sample.EngineerUnitsNeed or 0,
                sample.ExtractorUpgrades or 0,
                sample.ExtractorUpgradeMode or 'none',
                sample.ExtractorUpgradePriority or 0,
                sample.StructRadar or 0,
                sample.StructBaseAA or 0,
                sample.StructPD or 0,
                sample.TechEligible or 0,
                sample.TechBlock or 'none'))
        end
    end
end

function Tune(aiBrain, now)
    local runtime = aiBrain.OvermindRuntime
    if not runtime or not runtime.Telemetry then
        return
    end

    local tele = runtime.Telemetry
    local floatCount = 0
    local energyStallCount = 0
    local massStallCount = 0
    for _, sample in tele.Samples do
        if sample.MassStored > 900 and sample.MassTrend > 0.1 then
            floatCount = floatCount + 1
        end
        if sample.EnergyStored < 1600 and sample.EnergyTrend < -2 then
            energyStallCount = energyStallCount + 1
        end
        if sample.MassStored < 120 and sample.MassTrend < -0.05 then
            massStallCount = massStallCount + 1
        end
    end
    local n = math.max(1, table.getn(tele.Samples))
    local floatRate = floatCount / n
    local energyStallRate = energyStallCount / n
    local massStallRate = massStallCount / n

    runtime.Tuning = runtime.Tuning or {
        AggressionBias = 0,
        EconPressureBias = 0,
    }

    if floatRate > 0.24 then
        runtime.Tuning.EconPressureBias = Clamp((runtime.Tuning.EconPressureBias or 0) + 0.03, -0.25, 0.35)
    elseif energyStallRate > 0.2 or massStallRate > 0.2 then
        runtime.Tuning.EconPressureBias = Clamp((runtime.Tuning.EconPressureBias or 0) - 0.03, -0.25, 0.35)
    end

    if (runtime.CombatMomentum or 0) > 0.2 then
        runtime.Tuning.AggressionBias = Clamp((runtime.Tuning.AggressionBias or 0) + 0.03, -0.25, 0.35)
    elseif (runtime.CombatMomentum or 0) < -0.2 then
        runtime.Tuning.AggressionBias = Clamp((runtime.Tuning.AggressionBias or 0) - 0.03, -0.25, 0.35)
    end

    runtime.LastTuneTime = now

    if now - (runtime.LastMetricsLogTime or -999) >= 60 then
        runtime.LastMetricsLogTime = now
        local recovery = runtime.Recovery or {}
        local planner = runtime.StrategicPlanner or {}
        LOG(string.format('*OVERMIND METRICS A%d goal=%s strat=%s/%s/%s:%.2f posture=%s pivot=%s conf=%.2f prod=%s float=%.2f estall=%.2f mstall=%.2f aggr=%.2f stagn=%.1f rf=%d rs=%d',
            aiBrain:GetArmyIndex(),
            runtime.StrategyGoal or 'hold',
            (planner.Directive or 'stabilize'),
            (planner.PrimaryTheater or 'Front'),
            (planner.RaidDirective or 'opportunistic'),
            (planner.RaidCentrality or 0),
            (runtime.OpponentModel and runtime.OpponentModel.Posture) or 'unknown',
            (runtime.OpponentModel and runtime.OpponentModel.LikelyPivot) or 'balanced',
            ((runtime.OpponentModel and runtime.OpponentModel.Confidence and runtime.OpponentModel.Confidence.Global) or 0),
            ((runtime.ProductionDirector and runtime.ProductionDirector.Mode) or 'none'),
            floatRate,
            energyStallRate,
            massStallRate,
            runtime.Aggression or 1,
            recovery.StagnationTime or 0,
            recovery.ForceFactoryRecovery and 1 or 0,
            recovery.ForceScoutRecovery and 1 or 0))
    end
end
