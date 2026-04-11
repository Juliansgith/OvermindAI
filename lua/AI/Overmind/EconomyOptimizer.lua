local OvermindAutoTune = import('/mods/OvermindAI/lua/AI/Overmind/AutoTune.lua')

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
    metrics.FocusOnT1Spam =
        metrics.StructuralContestMap
        and metrics.PlayerCount <= 4
        and metrics.TotalMass > 0
        and metrics.TotalMass < 150
        and smallMapLike
        and metrics.OuterMexShare >= outsideStartThreshold
        and (metrics.SafeForwardMexCount >= 2 or metrics.ContestableZoneCount >= 2)

    return metrics
end

local function GetUnitCount(aiBrain, category)
    if not aiBrain or not category then
        return 0
    end
    return aiBrain:GetCurrentUnits(category) or 0
end

local function DetermineMacroPhase(aiBrain, runtime, eco, opp, recovery, now)
    local intel = runtime.IntelModel or {}
    local graph = runtime.ZoneGraph or {}
    local zone = runtime.ZoneModel or {}
    local structure = ComputeContestMapStructure(aiBrain, runtime)
    local mexCount = GetUnitCount(aiBrain, categories.MASSEXTRACTION * categories.STRUCTURE)
    local landFactories = GetUnitCount(aiBrain, categories.FACTORY * categories.LAND * categories.STRUCTURE)
    local airFactories = GetUnitCount(aiBrain, categories.FACTORY * categories.AIR * categories.STRUCTURE)
    local seaFactories = GetUnitCount(aiBrain, categories.FACTORY * categories.NAVAL * categories.STRUCTURE)
    local totalFactories = landFactories + airFactories + seaFactories
    local engineers = GetUnitCount(aiBrain, categories.ENGINEER * categories.MOBILE)

    local counts = {
        Mex = mexCount,
        LandFactory = landFactories,
        AirFactory = airFactories,
        SeaFactory = seaFactories,
        FactoryTotal = totalFactories,
        Engineers = engineers,
    }

    local massIncome = eco.MassIncome or 0
    local energyIncome = eco.EnergyIncome or 0
    local massRatio = eco.MassStorageRatio or 0
    local energyRatio = eco.EnergyStorageRatio or 0
    local massTrend = eco.MassTrend or 0
    local energyTrend = eco.EnergyTrend or 0
    local mapControl = intel.MapControl
        or graph.MapControl
        or zone.MapControl
        or 0
    local contestedZones = intel.ContestedZones or graph.ContestedZones or 0
    local zoneCount = TableCount(graph.Nodes or {})
    local navMarkerCount = structure.NavMarkerCount or zone.NavMarkerCount or graph.WaterZones or 0
    local relativePower = opp.RelativePower or 1
    local stagnation = recovery.StagnationTime or 0
    local landContestMap = structure.StructuralContestMap or (navMarkerCount < 3 and zoneCount >= 6)
    local focusOnT1Spam = structure.FocusOnT1Spam == true
    local contestTempoWindow = landContestMap
        and contestedZones >= 2
        and now >= 180
        and now <= 1020
        and mapControl <= 0.66
        and relativePower <= 1.08

    local weakMass = massIncome < 2.8 or (massRatio <= 0.07 and massTrend <= -0.06)
    local weakEnergy = energyIncome < 28 or (energyRatio <= 0.08 and energyTrend <= -6)
    local stableFactoryFeed = massIncome >= 4.8
        and energyIncome >= 70
        and massRatio >= 0.14
        and energyRatio >= 0.12
        and massTrend >= -0.02
        and energyTrend >= 0

    if recovery.ForceFactoryRecovery or recovery.ForceBaseEngineerRecovery or stagnation >= 75 then
        return 'recover', counts
    end

    if landFactories <= 0 or now < 180 or mexCount < 4 or engineers < 4 then
        return 'bootstrap', counts
    end

    if weakMass and totalFactories >= 2 then
        return 'recover', counts
    end

    if weakEnergy and airFactories > 0 and totalFactories >= 3 then
        return 'recover', counts
    end

    if focusOnT1Spam
        and now <= 1200
        and mexCount >= 4
        and landFactories >= 1
        and massIncome >= 3.2
        and energyIncome >= 40
        and not weakMass
        and not weakEnergy then
        return 'pressure', counts
    end

    if now >= 900 and stableFactoryFeed and mexCount >= 7 and relativePower >= 0.92 and mapControl >= 0.38 then
        return 'tech', counts
    end

    if stableFactoryFeed and mexCount >= 5 and landFactories >= 2 and totalFactories >= 2 and (relativePower >= 0.9 or mapControl >= 0.24) then
        return 'pressure', counts
    end

    if stableFactoryFeed and mexCount >= 6 and totalFactories >= 3 and (relativePower >= 0.98 or mapControl >= 0.44) then
        return 'pressure', counts
    end

    if contestTempoWindow and stableFactoryFeed and mexCount >= 5 and landFactories >= 2 then
        return 'pressure', counts
    end

    if stableFactoryFeed and contestedZones >= 2 and landFactories >= 2 and now < 900 then
        return 'pressure', counts
    end

    if landContestMap
        and stableFactoryFeed
        and landFactories >= 2
        and now < 1200
        and relativePower <= 1.12
        and mapControl <= 0.78
        and (
            structure.OuterMexShare >= 0.32
            or structure.SafeForwardMexCount >= 3
            or (structure.ContestableZoneCount >= 2 and not structure.FrontSecure)
        ) then
        return 'pressure', counts
    end

    return 'consolidate', counts
end

function UpdatePolicy(aiBrain, now)
    local runtime = aiBrain.OvermindRuntime or {}
    aiBrain.OvermindRuntime = runtime
    local tune = OvermindAutoTune.GetConfig(aiBrain)

    local eco = runtime.EcoState or {}
    local opp = runtime.OpponentModel or {}
    local planner = runtime.StrategicPlanner or {}
    local intel = runtime.IntelModel or {}
    local graph = runtime.ZoneGraph or {}
    local zone = runtime.ZoneModel or {}
    local recovery = runtime.Recovery or {}
    local goal = runtime.StrategyGoal or 'hold'
    local aggression = (runtime.Aggression or 1) + (runtime.GoalAggressionModifier or 0)

    local massStored = eco.MassStored or 0
    local energyStored = eco.EnergyStored or 0
    local massTrend = eco.MassTrend or 0
    local energyTrend = eco.EnergyTrend or 0

    local massFloat = massStored >= 800 and massTrend > 0.1
    local energyStall = energyStored < 2000 and energyTrend < -5
    local enemyPressure = (opp.Mobile or 0) > (opp.OwnMobile or 0) * 1.15
    local forceFactoryRecovery = recovery.ForceFactoryRecovery == true
    local forceBaseRecovery = recovery.ForceBaseEngineerRecovery == true
    local stagnation = recovery.StagnationTime or 0
    local phase, macroCounts = DetermineMacroPhase(aiBrain, runtime, eco, opp, recovery, now)
    runtime.MacroPhase = phase
    runtime.MacroCounts = macroCounts

    local structure = ComputeContestMapStructure(aiBrain, runtime)
    local mapControl = intel.MapControl or graph.MapControl or zone.MapControl or 0
    local contestedZones = intel.ContestedZones or graph.ContestedZones or 0
    local zoneCount = TableCount(graph.Nodes or {})
    local navMarkerCount = structure.NavMarkerCount or zone.NavMarkerCount or graph.WaterZones or 0
    local landContestMap = structure.StructuralContestMap or (navMarkerCount < 3 and zoneCount >= 6)
    local focusOnT1Spam = structure.FocusOnT1Spam == true
    local stableTempoEco = (eco.MassIncome or 0) >= 3.6
        and (eco.EnergyIncome or 0) >= 50
        and massTrend >= -0.08
        and energyTrend >= -4
        and not energyStall
    local contestMapMode = landContestMap
        and (contestedZones >= 2 or structure.ContestableZoneCount >= 3)
        and now >= 150
        and now <= 1200
        and phase ~= 'bootstrap'
        and phase ~= 'recover'
    if focusOnT1Spam then
        contestMapMode = true
    end
    local productionFirstWindow = (contestMapMode or focusOnT1Spam)
        and stableTempoEco
        and mapControl <= 0.68
        and (opp.RelativePower or 1) <= 1.08
    local prioritizeProduction = planner.TradeTechForTempo
        or planner.PunishGreed
        or goal == 'all_in'
        or goal == 'raid'
        or focusOnT1Spam
        or productionFirstWindow
        or (stableTempoEco and phase == 'pressure' and contestedZones >= 2 and now < 900 and mapControl < 0.55)
    local frontSecureUpgradeWindow = landContestMap
        and structure.FrontSecure
        and stableTempoEco
        and mapControl >= 0.44
        and contestedZones <= 1
        and (not focusOnT1Spam or (now >= 900 and structure.OuterHoldShare >= 0.62))
    local forwardContestBias = (contestMapMode or prioritizeProduction)
        and (
            not structure.FrontSecure
            or structure.OuterHoldShare < 0.5
            or structure.SafeForwardMexCount >= 2
            or structure.OuterMexShare >= 0.34
        )
    local reclaimPressureMode = (contestMapMode or prioritizeProduction)
        and stableTempoEco
        and now >= 240
        and not forceFactoryRecovery
        and not forceBaseRecovery
        and not enemyPressure
        and (
            structure.ContestableZoneCount >= 2
            or structure.OuterMexShare >= 0.34
            or structure.SafeForwardMexCount >= 2
        )
    local preferTempoFromSurplus = prioritizeProduction
        and stableTempoEco
        and not enemyPressure

    local policy = runtime.EcoPolicy or {}
    runtime.EcoPolicy = policy

    policy.MacroPhase = phase
    policy.PrioritizeProduction = false
    policy.ContestMapMode = false
    policy.PreferTempoFromSurplus = false
    policy.LocalMexUpgradeOnly = false
    policy.LocalMexUpgradeMaxConcurrent = 2
    policy.RelaxedFactoryTempo = false
    policy.SuppressEarlyAir = false
    policy.ForwardContestBias = false
    policy.ReclaimPressureMode = false
    policy.ProductionTempoBias = 0
    policy.FocusOnT1Spam = false
    policy.OuterMexShare = structure.OuterMexShare or 0
    policy.StartZoneMexShare = structure.StartZoneMexShare or 0
    policy.OuterHoldShare = structure.OuterHoldShare or 0
    policy.SafeForwardMexCount = structure.SafeForwardMexCount or 0
    policy.ContestableZoneCount = structure.ContestableZoneCount or 0
    policy.LandRouteDepth = structure.LandRouteDepth or 0
    policy.PlayerCount = structure.PlayerCount or 2
    policy.DirectEnemyDistance = structure.DirectEnemyDistance or 999
    policy.FrontSecure = structure.FrontSecure and true or false
    policy.StructuralContestMap = structure.StructuralContestMap and true or false
    policy.EnergyNeedRatio = 0.42
    policy.EnergyNeedTrend = -3
    policy.SafeEnergyRatio = 0.3
    policy.SafeEnergyTrend = 2
    policy.UpgradeMassIncome = 4 + (aggression * 1.2)
    policy.UpgradeEnergyIncome = 25 + (aggression * 20)
    policy.FactoryMassIncome = 5 + aggression * 0.9
    policy.FactoryEnergyIncome = 90 + aggression * 18
    policy.FactoryMassRatio = 0.38
    policy.FactoryEnergyRatio = 0.34
    policy.FactoryMinMassTrend = 0.0
    policy.FactoryMinEnergyTrend = 9
    policy.FactoryMassPerFactory = 1.25 + aggression * 0.08
    policy.FactoryToMexCap = 0.92
    policy.PgenPerMexCap = 1.8
    policy.PowerHardStopEnergyRatio = 0.58
    policy.PowerHardStopEnergyTrend = 18
    policy.PowerHardStopMassRatio = 0.78
    policy.PowerMaxEnergyRatio = 0.86
    policy.PowerMaxEnergyTrend = 36
    policy.MassFabMassRatio = 0.96
    policy.MassFabEnergyRatio = 0.95
    policy.MassFabEnergyIncome = 1400 + aggression * 120
    policy.MassFabMassTrend = 0.2
    policy.MassFabEnergyTrend = 130
    policy.MassFabMinT3Mex = 4
    policy.MassFabMinT3Pgen = 2
    policy.OpeningLockTime = 420
    policy.EngineerReserveMin = 4
    policy.SafeExpandDistance = 640
    policy.SafeExpandThreatCap = 1.0
    policy.SafeExpandEnemyBuffer = 70
    policy.SafeExpandHotspotCap = 8 + (tune.SafeExpandHotspotCapBias or 0)
    policy.T2MexMinTime = 210
    policy.T2MexMinFactories = 2
    policy.BaseEngineerFloor = math.max(3, tune.BaseEngineerFloorMin or 3)
    policy.EngineerFactoryRatio = 0.95
    policy.FarExpandMinTime = 360
    policy.FarExpandMinControl = 0.26
    policy.FarExpandMinRelativePower = 0.95
    policy.FarExpandMinArmy = 22
    policy.LandFactoryMinMex = 4
    policy.AirFactoryMinMex = 5
    policy.AirFactoryMinTime = 300
    policy.AirFactoryMinEnergyIncome = 28
    policy.RadarMinTime = 300
    policy.RadarMinEnergyIncome = 30
    policy.RadarMinEnergyStored = 1800
    policy.RadarDesiredCap = 1
    policy.MaxAirBomberShare = 0.32
    policy.PrimaryFactorySoftCap = 3
    policy.AcuOpeningMaxDistance = math.min(tune.ACUOpeningMaxDistance or 20, 16)
    policy.AcuMidMaxDistance = math.min(tune.ACUMidMaxDistance or 36, 24)
    policy.AcuLateMaxDistance = math.min(tune.ACULateMaxDistance or 60, 38)

    policy.ContestMapMode = contestMapMode and true or false
    policy.PrioritizeProduction = prioritizeProduction and true or false
    policy.PreferTempoFromSurplus = preferTempoFromSurplus and true or false
    policy.FocusOnT1Spam = focusOnT1Spam and true or false
    policy.LocalMexUpgradeOnly = ((contestMapMode or prioritizeProduction or focusOnT1Spam) and not frontSecureUpgradeWindow) and true or false
    policy.LocalMexUpgradeMaxConcurrent = ((contestMapMode or prioritizeProduction or focusOnT1Spam) and not frontSecureUpgradeWindow) and 1 or 2
    policy.RelaxedFactoryTempo = (contestMapMode or prioritizeProduction or focusOnT1Spam) and true or false
    policy.SuppressEarlyAir = (contestMapMode or prioritizeProduction or focusOnT1Spam) and true or false
    policy.ForwardContestBias = forwardContestBias and true or false
    policy.ReclaimPressureMode = reclaimPressureMode and true or false
    policy.ProductionTempoBias = (focusOnT1Spam and 0.42) or (contestMapMode and 0.28) or (prioritizeProduction and 0.16) or 0

    if now < 420 then
        policy.EngineerReserveMin = 5
        policy.SafeExpandDistance = 540
        policy.SafeExpandThreatCap = 0.72
        policy.SafeExpandEnemyBuffer = 92
        policy.SafeExpandHotspotCap = 5.5 + (tune.SafeExpandHotspotCapBias or 0)
        policy.T2MexMinTime = 280
        policy.BaseEngineerFloor = math.max(4, tune.BaseEngineerFloorMin or 3)
        policy.FarExpandMinTime = 330
        policy.FarExpandMinControl = 0.24
        policy.FarExpandMinRelativePower = 0.95
        policy.FarExpandMinArmy = 20
        policy.AcuOpeningMaxDistance = math.min(tune.ACUOpeningMaxDistance or 20, 16)
        policy.AcuMidMaxDistance = math.min(tune.ACUMidMaxDistance or 36, 24)
    elseif now < 720 then
        policy.EngineerReserveMin = 4
        policy.SafeExpandDistance = 660
        policy.SafeExpandThreatCap = 0.8
        policy.SafeExpandEnemyBuffer = 82
        policy.SafeExpandHotspotCap = 7 + (tune.SafeExpandHotspotCapBias or 0)
        policy.T2MexMinTime = 240
        policy.BaseEngineerFloor = math.max(3, tune.BaseEngineerFloorMin or 3)
        policy.FarExpandMinTime = 380
        policy.FarExpandMinControl = 0.28
        policy.FarExpandMinRelativePower = 0.94
        policy.FarExpandMinArmy = 24
        policy.AcuOpeningMaxDistance = math.min((tune.ACUOpeningMaxDistance or 20) + 2, 18)
        policy.AcuMidMaxDistance = math.min((tune.ACUMidMaxDistance or 36) + 4, 28)
    end

    if phase == 'bootstrap' then
        policy.FactoryMassIncome = policy.FactoryMassIncome + 1.6
        policy.FactoryEnergyIncome = policy.FactoryEnergyIncome + 24
        policy.FactoryMassRatio = math.max(policy.FactoryMassRatio, 0.42)
        policy.FactoryEnergyRatio = math.max(policy.FactoryEnergyRatio, 0.4)
        policy.FactoryMassPerFactory = policy.FactoryMassPerFactory + 0.24
        policy.FactoryToMexCap = math.min(policy.FactoryToMexCap, 0.78)
        policy.PgenPerMexCap = math.min(policy.PgenPerMexCap, 1.65)
        policy.BaseEngineerFloor = math.max(policy.BaseEngineerFloor, 4)
        policy.EngineerReserveMin = math.max(policy.EngineerReserveMin, 5)
        policy.EngineerFactoryRatio = 1.15
        policy.LandFactoryMinMex = 4
        policy.AirFactoryMinMex = 7
        policy.AirFactoryMinTime = 420
        policy.AirFactoryMinEnergyIncome = 55
        policy.RadarMinTime = 420
        policy.RadarMinEnergyIncome = 40
        policy.RadarMinEnergyStored = 3200
        policy.RadarDesiredCap = 1
        policy.MaxAirBomberShare = 0.18
        policy.PrimaryFactorySoftCap = 2
    elseif phase == 'recover' then
        policy.FactoryMassIncome = policy.FactoryMassIncome + 1.1
        policy.FactoryEnergyIncome = policy.FactoryEnergyIncome + 18
        policy.FactoryMassRatio = math.max(policy.FactoryMassRatio, 0.38)
        policy.FactoryEnergyRatio = math.max(policy.FactoryEnergyRatio, 0.36)
        policy.FactoryMassPerFactory = policy.FactoryMassPerFactory + 0.16
        policy.FactoryToMexCap = math.min(policy.FactoryToMexCap, 0.82)
        policy.PgenPerMexCap = math.min(policy.PgenPerMexCap, 1.75)
        policy.BaseEngineerFloor = math.max(policy.BaseEngineerFloor, 4)
        policy.EngineerReserveMin = math.max(policy.EngineerReserveMin, 5)
        policy.EngineerFactoryRatio = 1.05
        policy.LandFactoryMinMex = 4
        policy.AirFactoryMinMex = 6
        policy.AirFactoryMinTime = 360
        policy.AirFactoryMinEnergyIncome = 42
        policy.RadarMinTime = 380
        policy.RadarMinEnergyIncome = 36
        policy.RadarMinEnergyStored = 2600
        policy.RadarDesiredCap = 1
        policy.MaxAirBomberShare = 0.22
        policy.PrimaryFactorySoftCap = 2
    elseif phase == 'pressure' then
        policy.FactoryMassIncome = math.max(3.8, policy.FactoryMassIncome - 0.4)
        policy.FactoryEnergyIncome = math.max(70, policy.FactoryEnergyIncome - 12)
        policy.FactoryMassRatio = math.min(policy.FactoryMassRatio, 0.34)
        policy.FactoryEnergyRatio = math.min(policy.FactoryEnergyRatio, 0.3)
        policy.FactoryMassPerFactory = math.max(1.05, policy.FactoryMassPerFactory - 0.08)
        policy.FactoryToMexCap = math.max(policy.FactoryToMexCap, 0.98)
        policy.EngineerFactoryRatio = 0.88
        policy.AirFactoryMinMex = 4
        policy.AirFactoryMinTime = 240
        policy.AirFactoryMinEnergyIncome = 24
        policy.RadarMinTime = 240
        policy.RadarMinEnergyIncome = 24
        policy.RadarMinEnergyStored = 1400
        policy.RadarDesiredCap = 2
        policy.MaxAirBomberShare = 0.38
        policy.PrimaryFactorySoftCap = 4
    elseif phase == 'tech' then
        policy.FactoryMassIncome = math.max(4.2, policy.FactoryMassIncome - 0.2)
        policy.FactoryEnergyIncome = math.max(78, policy.FactoryEnergyIncome - 8)
        policy.FactoryMassRatio = math.min(policy.FactoryMassRatio, 0.34)
        policy.FactoryEnergyRatio = math.min(policy.FactoryEnergyRatio, 0.3)
        policy.FactoryMassPerFactory = math.max(1.08, policy.FactoryMassPerFactory - 0.06)
        policy.FactoryToMexCap = math.max(policy.FactoryToMexCap, 1.02)
        policy.EngineerFactoryRatio = 0.9
        policy.AirFactoryMinMex = 5
        policy.AirFactoryMinTime = 260
        policy.AirFactoryMinEnergyIncome = 30
        policy.RadarMinTime = 240
        policy.RadarMinEnergyIncome = 28
        policy.RadarMinEnergyStored = 1500
        policy.RadarDesiredCap = 2
        policy.MaxAirBomberShare = 0.4
        policy.PrimaryFactorySoftCap = 5
    end

    if massFloat then
        policy.UpgradeMassIncome = math.max(3, policy.UpgradeMassIncome - 1.5)
        policy.FactoryMassIncome = math.max(4, policy.FactoryMassIncome - 1.0)
        policy.FactoryMassRatio = 0.3
        policy.FactoryMinMassTrend = -0.03
        policy.FactoryMassPerFactory = math.max(1.1, policy.FactoryMassPerFactory - 0.1)
    end

    if energyStall then
        policy.EnergyNeedRatio = 0.56
        policy.EnergyNeedTrend = 6
        policy.SafeEnergyRatio = 0.4
        policy.SafeEnergyTrend = 8
        policy.FactoryEnergyIncome = policy.FactoryEnergyIncome + 30
        policy.FactoryEnergyRatio = 0.45
        policy.FactoryMinEnergyTrend = 16
        policy.PowerHardStopEnergyRatio = 0.65
        policy.PowerHardStopEnergyTrend = 30
        policy.MassFabEnergyIncome = policy.MassFabEnergyIncome + 250
        policy.MassFabEnergyTrend = 170
    end

    if enemyPressure or goal == 'hold' then
        policy.FactoryMassIncome = policy.FactoryMassIncome + 1.2
        policy.FactoryEnergyIncome = policy.FactoryEnergyIncome + 20
        policy.UpgradeMassIncome = policy.UpgradeMassIncome + 1.8
        policy.FactoryMassPerFactory = policy.FactoryMassPerFactory + 0.12
        policy.FactoryToMexCap = math.min(1.0, policy.FactoryToMexCap + 0.05)
    end

    if goal == 'all_in' or goal == 'raid' then
        policy.FactoryMassRatio = 0.28
        policy.FactoryEnergyRatio = 0.26
        policy.FactoryMassPerFactory = math.max(1.0, policy.FactoryMassPerFactory - 0.1)
        policy.UpgradeMassIncome = math.max(3.2, policy.UpgradeMassIncome - 0.8)
    elseif goal == 'tech' then
        policy.UpgradeMassIncome = math.max(3, policy.UpgradeMassIncome - 1)
        policy.UpgradeEnergyIncome = math.max(22, policy.UpgradeEnergyIncome - 8)
        policy.MassFabEnergyIncome = policy.MassFabEnergyIncome + 120
        policy.MassFabEnergyTrend = policy.MassFabEnergyTrend + 20
        policy.T2MexMinTime = math.max(170, policy.T2MexMinTime - 30)
    elseif goal == 'expand' and (opp.RelativePower or 1) >= 0.95 then
        policy.SafeExpandDistance = policy.SafeExpandDistance + 80
        policy.SafeExpandThreatCap = policy.SafeExpandThreatCap + 0.1
        policy.SafeExpandEnemyBuffer = math.max(45, policy.SafeExpandEnemyBuffer - 12)
        policy.FarExpandMinControl = math.max(0.2, policy.FarExpandMinControl - 0.06)
        policy.FarExpandMinRelativePower = math.max(0.9, policy.FarExpandMinRelativePower - 0.04)
    end

    if forceFactoryRecovery or stagnation > 90 then
        policy.FactoryMassIncome = math.max(2.2, policy.FactoryMassIncome - 1.8)
        policy.FactoryEnergyIncome = math.max(28, policy.FactoryEnergyIncome - 30)
        policy.FactoryMassRatio = math.min(policy.FactoryMassRatio, 0.26)
        policy.FactoryEnergyRatio = math.min(policy.FactoryEnergyRatio, 0.22)
        policy.FactoryMinMassTrend = math.min(policy.FactoryMinMassTrend, -0.12)
        policy.FactoryMinEnergyTrend = math.min(policy.FactoryMinEnergyTrend, -8)
        policy.FactoryMassPerFactory = math.max(0.95, policy.FactoryMassPerFactory - 0.2)
        policy.FactoryToMexCap = math.min(1.15, policy.FactoryToMexCap + 0.14)
        policy.SafeExpandDistance = math.min(policy.SafeExpandDistance, 520)
        policy.SafeExpandThreatCap = math.min(policy.SafeExpandThreatCap, 0.8)
        policy.SafeExpandEnemyBuffer = math.max(policy.SafeExpandEnemyBuffer, 92)
    end

    if forceBaseRecovery then
        policy.BaseEngineerFloor = math.max(policy.BaseEngineerFloor, 4, tune.BaseEngineerFloorMin or 3)
        policy.EngineerReserveMin = math.max(policy.EngineerReserveMin, 5)
        policy.FarExpandMinTime = math.max(policy.FarExpandMinTime, 520)
        policy.SafeExpandDistance = math.min(policy.SafeExpandDistance, 560)
    end

    if planner.TradeMapForTech then
        policy.UpgradeMassIncome = math.max(2.8, policy.UpgradeMassIncome - 0.8)
        policy.UpgradeEnergyIncome = math.max(18, policy.UpgradeEnergyIncome - 10)
        policy.T2MexMinTime = math.max(150, policy.T2MexMinTime - 35)
        policy.PrimaryFactorySoftCap = math.max(2, policy.PrimaryFactorySoftCap - 1)
        policy.FactoryMassIncome = policy.FactoryMassIncome + 0.2
    elseif planner.TradeTechForTempo or planner.PunishGreed then
        policy.FactoryMassIncome = math.max(3.0, policy.FactoryMassIncome - 0.6)
        policy.FactoryEnergyIncome = math.max(50, policy.FactoryEnergyIncome - 10)
        policy.FactoryMassPerFactory = math.max(0.95, policy.FactoryMassPerFactory - 0.08)
        policy.UpgradeMassIncome = policy.UpgradeMassIncome + 0.9
        policy.UpgradeEnergyIncome = policy.UpgradeEnergyIncome + 10
        policy.T2MexMinTime = policy.T2MexMinTime + 40
        policy.PrimaryFactorySoftCap = policy.PrimaryFactorySoftCap + 1
    end

    if planner.Directive == 'expand' or planner.PrimaryTheater == 'Enemy' then
        policy.SafeExpandDistance = policy.SafeExpandDistance + 70
        policy.SafeExpandThreatCap = policy.SafeExpandThreatCap + 0.08
        policy.SafeExpandEnemyBuffer = math.max(45, policy.SafeExpandEnemyBuffer - 10)
    elseif planner.Directive == 'stabilize' or planner.PrimaryTheater == 'Home' then
        policy.SafeExpandDistance = math.min(policy.SafeExpandDistance, 560)
        policy.SafeExpandThreatCap = math.min(policy.SafeExpandThreatCap, 0.82)
        policy.SafeExpandEnemyBuffer = math.max(policy.SafeExpandEnemyBuffer, 88)
    end

    if planner.ForceAirAnswer then
        policy.AirFactoryMinTime = math.max(180, policy.AirFactoryMinTime - 60)
        policy.AirFactoryMinEnergyIncome = math.max(18, policy.AirFactoryMinEnergyIncome - 6)
        policy.RadarDesiredCap = policy.RadarDesiredCap + 1
        policy.MaxAirBomberShare = policy.MaxAirBomberShare + 0.06
    end

    if prioritizeProduction then
        policy.FactoryMassIncome = math.max(2.9, policy.FactoryMassIncome - 0.9)
        policy.FactoryEnergyIncome = math.max(46, policy.FactoryEnergyIncome - 16)
        policy.FactoryMassRatio = math.min(policy.FactoryMassRatio, 0.3)
        policy.FactoryEnergyRatio = math.min(policy.FactoryEnergyRatio, 0.28)
        policy.FactoryMinMassTrend = math.min(policy.FactoryMinMassTrend, -0.06)
        policy.FactoryMinEnergyTrend = math.min(policy.FactoryMinEnergyTrend, -2)
        policy.FactoryMassPerFactory = math.max(0.95, policy.FactoryMassPerFactory - 0.12)
        policy.FactoryToMexCap = math.max(policy.FactoryToMexCap, 1.06)
        policy.T2MexMinTime = policy.T2MexMinTime + 75
        policy.UpgradeMassIncome = policy.UpgradeMassIncome + 1.2
        policy.UpgradeEnergyIncome = policy.UpgradeEnergyIncome + 14
        policy.PrimaryFactorySoftCap = policy.PrimaryFactorySoftCap + 1
        policy.AirFactoryMinMex = policy.AirFactoryMinMex + 1
        policy.AirFactoryMinTime = policy.AirFactoryMinTime + 90
        policy.AirFactoryMinEnergyIncome = policy.AirFactoryMinEnergyIncome + 10
        policy.MaxAirBomberShare = math.max(0.15, policy.MaxAirBomberShare - 0.08)
    end

    if contestMapMode then
        policy.FactoryMassIncome = math.max(2.6, policy.FactoryMassIncome - 0.7)
        policy.FactoryEnergyIncome = math.max(42, policy.FactoryEnergyIncome - 12)
        policy.FactoryMassRatio = math.min(policy.FactoryMassRatio, 0.28)
        policy.FactoryEnergyRatio = math.min(policy.FactoryEnergyRatio, 0.26)
        policy.FactoryMassPerFactory = math.max(0.92, policy.FactoryMassPerFactory - 0.1)
        policy.FactoryToMexCap = math.max(policy.FactoryToMexCap, 1.1)
        policy.EngineerFactoryRatio = math.max(0.82, policy.EngineerFactoryRatio - 0.05)
        policy.T2MexMinTime = policy.T2MexMinTime + 45
        policy.UpgradeMassIncome = policy.UpgradeMassIncome + 0.6
        policy.UpgradeEnergyIncome = policy.UpgradeEnergyIncome + 8
        policy.AirFactoryMinMex = policy.AirFactoryMinMex + 1
        policy.AirFactoryMinTime = policy.AirFactoryMinTime + 60
        policy.AirFactoryMinEnergyIncome = policy.AirFactoryMinEnergyIncome + 6
        policy.PrimaryFactorySoftCap = policy.PrimaryFactorySoftCap + 1
    end

    if focusOnT1Spam then
        policy.FactoryMassIncome = math.max(2.2, policy.FactoryMassIncome - 1.1)
        policy.FactoryEnergyIncome = math.max(36, policy.FactoryEnergyIncome - 18)
        policy.FactoryMassRatio = math.min(policy.FactoryMassRatio, 0.24)
        policy.FactoryEnergyRatio = math.min(policy.FactoryEnergyRatio, 0.24)
        policy.FactoryMinMassTrend = math.min(policy.FactoryMinMassTrend, -0.08)
        policy.FactoryMinEnergyTrend = math.min(policy.FactoryMinEnergyTrend, -4)
        policy.FactoryMassPerFactory = math.max(0.82, policy.FactoryMassPerFactory - 0.18)
        policy.FactoryToMexCap = math.max(policy.FactoryToMexCap, 1.14)
        policy.PgenPerMexCap = math.min(policy.PgenPerMexCap, 1.65)
        policy.EngineerFactoryRatio = math.max(0.8, policy.EngineerFactoryRatio - 0.08)
        policy.T2MexMinTime = policy.T2MexMinTime + 150
        policy.UpgradeMassIncome = policy.UpgradeMassIncome + 1.8
        policy.UpgradeEnergyIncome = policy.UpgradeEnergyIncome + 22
        policy.PrimaryFactorySoftCap = policy.PrimaryFactorySoftCap + 2
        policy.AirFactoryMinMex = policy.AirFactoryMinMex + 2
        policy.AirFactoryMinTime = policy.AirFactoryMinTime + 180
        policy.AirFactoryMinEnergyIncome = policy.AirFactoryMinEnergyIncome + 12
        policy.MaxAirBomberShare = math.max(0.12, policy.MaxAirBomberShare - 0.1)
        policy.MassFabMassRatio = math.max(policy.MassFabMassRatio, 0.98)
        policy.MassFabEnergyRatio = math.max(policy.MassFabEnergyRatio, 0.98)
        policy.MassFabEnergyIncome = policy.MassFabEnergyIncome + 400
        policy.MassFabMassTrend = policy.MassFabMassTrend + 0.2
        policy.MassFabEnergyTrend = policy.MassFabEnergyTrend + 40
        policy.MassFabMinT3Mex = policy.MassFabMinT3Mex + 2
    end

    policy.FactoryMassRatio = Clamp(policy.FactoryMassRatio, 0.18, 0.5)
    policy.FactoryEnergyRatio = Clamp(policy.FactoryEnergyRatio, 0.2, 0.6)
    policy.FactoryMassPerFactory = Clamp(policy.FactoryMassPerFactory, 0.9, 2.2)
    policy.FactoryToMexCap = Clamp(policy.FactoryToMexCap, 0.75, 1.2)
    policy.PgenPerMexCap = Clamp(policy.PgenPerMexCap, 1.4, 2.8)
    policy.PowerHardStopEnergyRatio = Clamp(policy.PowerHardStopEnergyRatio, 0.45, 0.95)
    policy.PowerHardStopMassRatio = Clamp(policy.PowerHardStopMassRatio, 0.45, 0.95)
    policy.PowerMaxEnergyRatio = Clamp(policy.PowerMaxEnergyRatio, 0.65, 0.99)
    policy.MassFabMassRatio = Clamp(policy.MassFabMassRatio, 0.85, 0.99)
    policy.MassFabEnergyRatio = Clamp(policy.MassFabEnergyRatio, 0.8, 0.99)
    policy.MassFabEnergyIncome = Clamp(policy.MassFabEnergyIncome, 900, 3500)
    policy.MassFabMassTrend = Clamp(policy.MassFabMassTrend, 0.05, 1.5)
    policy.MassFabEnergyTrend = Clamp(policy.MassFabEnergyTrend, 60, 300)
    policy.EngineerReserveMin = Clamp(policy.EngineerReserveMin, 3, 8)
    policy.SafeExpandDistance = Clamp(policy.SafeExpandDistance, 300, 1100)
    policy.SafeExpandThreatCap = Clamp(policy.SafeExpandThreatCap, 0.2, 3.5)
    policy.SafeExpandEnemyBuffer = Clamp(policy.SafeExpandEnemyBuffer, 35, 160)
    policy.SafeExpandHotspotCap = Clamp(policy.SafeExpandHotspotCap, 2, 20)
    policy.T2MexMinTime = Clamp(policy.T2MexMinTime, 120, 600)
    policy.T2MexMinFactories = Clamp(policy.T2MexMinFactories, 1, 5)
    policy.BaseEngineerFloor = Clamp(policy.BaseEngineerFloor, 2, 7)
    policy.EngineerFactoryRatio = Clamp(policy.EngineerFactoryRatio, 0.8, 1.25)
    policy.FarExpandMinTime = Clamp(policy.FarExpandMinTime, 240, 1200)
    policy.FarExpandMinControl = Clamp(policy.FarExpandMinControl, 0.05, 1.2)
    policy.FarExpandMinRelativePower = Clamp(policy.FarExpandMinRelativePower, 0.65, 1.8)
    policy.FarExpandMinArmy = Clamp(policy.FarExpandMinArmy, 10, 120)
    policy.LandFactoryMinMex = Clamp(policy.LandFactoryMinMex, 3, 8)
    policy.AirFactoryMinMex = Clamp(policy.AirFactoryMinMex, 4, 10)
    policy.AirFactoryMinTime = Clamp(policy.AirFactoryMinTime, 180, 900)
    policy.AirFactoryMinEnergyIncome = Clamp(policy.AirFactoryMinEnergyIncome, 18, 120)
    policy.RadarMinTime = Clamp(policy.RadarMinTime, 180, 900)
    policy.RadarMinEnergyIncome = Clamp(policy.RadarMinEnergyIncome, 18, 140)
    policy.RadarMinEnergyStored = Clamp(policy.RadarMinEnergyStored, 900, 6000)
    policy.RadarDesiredCap = Clamp(policy.RadarDesiredCap, 1, 4)
    policy.MaxAirBomberShare = Clamp(policy.MaxAirBomberShare, 0.15, 0.5)
    policy.PrimaryFactorySoftCap = Clamp(policy.PrimaryFactorySoftCap, 2, 6)
    policy.AcuOpeningMaxDistance = Clamp(policy.AcuOpeningMaxDistance, 16, 90)
    policy.AcuMidMaxDistance = Clamp(policy.AcuMidMaxDistance, 24, 110)
    policy.AcuLateMaxDistance = Clamp(policy.AcuLateMaxDistance, 35, 160)
    policy.UpgradeMassIncome = Clamp(policy.UpgradeMassIncome, 2.5, 12)
    policy.UpgradeEnergyIncome = Clamp(policy.UpgradeEnergyIncome, 15, 220)
    policy.LastUpdate = now
end
