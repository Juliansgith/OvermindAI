local OvermindAutoTune = import('/mods/OvermindAI/lua/AI/Overmind/AutoTune.lua')
local OvermindEconomySignals = import('/mods/OvermindAI/lua/AI/Overmind/EconomySignals.lua')
local OvermindMemory = import('/mods/OvermindAI/lua/AI/Overmind/Memory.lua')

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
    local structure = OvermindEconomySignals.GetStructure(aiBrain, runtime, now)
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
    local reclaimScoreBias = tune.ReclaimScoreBias or 0
    local function TunedReclaimScore(base)
        return Clamp(base + reclaimScoreBias, 40, 420)
    end

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
    local acuCrisisActive = now < (runtime.ACUCrisisUntil or -999)
    local phase, macroCounts = DetermineMacroPhase(aiBrain, runtime, eco, opp, recovery, now)
    runtime.MacroPhase = phase
    runtime.MacroCounts = macroCounts

    local signalSnapshot = OvermindEconomySignals.Update(aiBrain, now)
    local structure = signalSnapshot.Structure or OvermindEconomySignals.GetStructure(aiBrain, runtime, now)
    local velocity = signalSnapshot.Velocity or runtime.EcoVelocity or {}
    local pressure = signalSnapshot.Pressure or runtime.EcoPressure or {}
    local policySeed = signalSnapshot.PolicySeed or {}
    local ledger = runtime.EconomyLedger or {}
    local mapControl = intel.MapControl or graph.MapControl or zone.MapControl or 0
    local contestedZones = intel.ContestedZones or graph.ContestedZones or 0
    local zoneCount = TableCount(graph.Nodes or {})
    local navMarkerCount = structure.NavMarkerCount or zone.NavMarkerCount or graph.WaterZones or 0
    local landContestMap = structure.StructuralContestMap or (navMarkerCount < 3 and zoneCount >= 6)
    local focusOnT1Spam = policySeed.FocusOnT1Spam == true or structure.FocusOnT1Spam == true
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
    if policySeed.ContestMapMode == true then
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
        or policySeed.PrioritizeProduction == true
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
    local reclaimFieldScore = planner.ReclaimFieldScore or 0
    local reclaimFieldAvailable = reclaimFieldScore >= TunedReclaimScore(110)
    local reclaimUnderPressure = reclaimFieldAvailable or (structure.SafeForwardMexCount or 0) >= 2
    local reclaimPressureMode = (contestMapMode or prioritizeProduction)
        and stableTempoEco
        and now >= 320
        and phase ~= 'bootstrap'
        and not forceFactoryRecovery
        and not forceBaseRecovery
        and not acuCrisisActive
        and (not enemyPressure or reclaimUnderPressure)
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
    policy.AlwaysEco = true
    policy.MexUpgradeConcurrency = 1
    policy.EngineerReclaimQuota = 0
    policy.EngineerExpansionQuota = 1
    policy.EngineerBaseQuota = 2
    policy.EcoGrowthPressure = 0
    policy.ApproachFailurePressure = pressure.ApproachFailurePressure or 0
    policy.PolicyReason = policySeed.PolicyReason or 'normal'
    policy.SpendSaturation = ((ledger.Aggregate or {}).SpendSaturation) or (velocity.SpendSaturation or 0)
    policy.FactoryBusyRatio = ((ledger.Aggregate or {}).FactoryBusyRatio) or (velocity.FactoryThroughput or 0)
    policy.EngineerBusyRatio = ((ledger.Aggregate or {}).EngineerBusyRatio) or (velocity.EngineerProductivity or 0)
    policy.ReclaimRateShort = velocity.ReclaimRateShort or 0
    policy.EcoStagnationTime = velocity.EcoStagnationTime or 0
    policy.ReclaimStagnationTime = velocity.ReclaimStagnationTime or 0
    policy.ContainmentCrisis = false
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
    policy.ReclaimRiskBias = tune.ReclaimRiskBias or 0
    policy.ReclaimSupportBias = tune.ReclaimSupportBias or 0
    policy.ReclaimNearbyBias = tune.ReclaimNearbyBias or 0
    policy.ReclaimFieldRadiusBias = tune.ReclaimFieldRadiusBias or 0
    policy.ReclaimFieldMassBias = tune.ReclaimFieldMassBias or 0
    policy.ReclaimRouteRiskBias = tune.ReclaimRouteRiskBias or 0
    policy.ReclaimEnemyMexBias = tune.ReclaimEnemyMexBias or 0
    policy.MexUpgradeBudgetBias = tune.MexUpgradeBudgetBias or 0
    policy.MexUpgradeRiskBias = tune.MexUpgradeRiskBias or 0
    policy.MexUpgradeCapBias = tune.MexUpgradeCapBias or 0
    policy.FactoryHQTimingBias = tune.FactoryHQTimingBias or 0
    policy.FactoryHQEcoBias = tune.FactoryHQEcoBias or 0
    policy.ForceOuterContestBias = tune.ForceOuterContestBias or 0
    policy.ForceHomeGuardBias = tune.ForceHomeGuardBias or 0
    policy.ForceRaidBias = tune.ForceRaidBias or 0
    policy.StrategyOuterRetentionBias = tune.StrategyOuterRetentionBias or 0
    policy.StrategyCollapseResistanceBias = tune.StrategyCollapseResistanceBias or 0
    policy.StrategyReclaimFieldBias = tune.StrategyReclaimFieldBias or 0
    policy.EarlyAirUnlockBias = tune.EarlyAirUnlockBias or 0
    policy.AcuOpeningMaxDistance = Clamp((tune.ACUOpeningMaxDistance or 28) + 10, 24, 42)
    policy.AcuMidMaxDistance = Clamp((tune.ACUMidMaxDistance or 40) + 8, 32, 58)
    policy.AcuLateMaxDistance = Clamp((tune.ACULateMaxDistance or 60) + 4, 42, 76)
    policy.AcuOpeningMexDistance = Clamp(260 + ((tune.ACUOpeningMaxDistance or 28) * 2), 240, 340)

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
    policy.AlwaysEco = pressure.SurvivalCrisis ~= true
    policy.EcoGrowthPressure = Clamp(
        ((velocity.EcoStagnationTime or 0) / 180)
        + ((velocity.ReclaimStagnationTime or 0) / 240)
        + (((ledger.Aggregate or {}).IdleEngineerCount or 0) * 0.08),
        0,
        1.5)
    policy.MexUpgradeConcurrency = 1
    if pressure.SurvivalCrisis == true then
        policy.MexUpgradeConcurrency = 0
    elseif (velocity.SpendSaturation or 0) >= 0.72 and (eco.MassTrend or 0) >= -0.10 and (eco.EnergyTrend or 0) >= -8 then
        policy.MexUpgradeConcurrency = 2
    elseif policy.EcoGrowthPressure >= 0.65 and (eco.MassIncome or 0) >= 3.4 and (eco.EnergyIncome or 0) >= 38 then
        policy.MexUpgradeConcurrency = 1
    end
    if focusOnT1Spam or contestMapMode or prioritizeProduction then
        policy.MexUpgradeConcurrency = math.min(policy.MexUpgradeConcurrency, frontSecureUpgradeWindow and 2 or 1)
    end
    policy.MexUpgradeConcurrency = Clamp(policy.MexUpgradeConcurrency, 0, 4)
    local reclaimCrisisOverride = reclaimFieldScore >= 150
        and (macroCounts.Engineers or 0) >= 7
        and (eco.MassTrend or 0) >= -0.45
        and (eco.EnergyTrend or 0) >= -24
        and (planner.ReclaimFirst == true or planner.OuterRetentionActive == true or reclaimPressureMode)
    local reclaimQuotaAllowed = now >= Clamp(180 + (tune.ReclaimQuotaTimeBias or 0), 90, 420)
        and phase ~= 'bootstrap'
        and (macroCounts.FactoryTotal or 0) >= 1
        and (not acuCrisisActive or reclaimCrisisOverride)
        and pressure.SurvivalCrisis ~= true
    local reclaimQuotaMexReady = (macroCounts.Mex or 0) >= 6
        or ((macroCounts.Mex or 0) >= 4 and reclaimFieldScore >= TunedReclaimScore(90))
        or ((macroCounts.Mex or 0) >= 5 and reclaimFieldScore >= TunedReclaimScore(110))
        or ((macroCounts.Mex or 0) >= 5 and reclaimPressureMode)
        or reclaimFieldScore >= TunedReclaimScore(180)
    local lowMexExpansionNeed = now < 1500 and (macroCounts.Mex or 0) < 11 and phase ~= 'bootstrap'
    local reclaimWorkerReady = (macroCounts.Engineers or 0) >= 8
    local reclaimConversionDebt = (velocity.ReclaimStagnationTime or 0) >= 45
        or ((velocity.ReclaimRateShort or 0) <= 0.15 and reclaimFieldScore >= 90)
    local containmentCrisis = now >= 360
        and phase ~= 'bootstrap'
        and mapControl < 0.44
        and (macroCounts.Mex or 0) <= 6
        and (
            enemyPressure
            or (opp.RelativePower or 1) < 0.55
            or (opp.RelativeLand or 1) < 0.55
            or (pressure.HomePressure or 0) >= 6.0
        )
    local containmentExpansionFloor = 8
    policy.ContainmentExpansionFloor = containmentExpansionFloor
    policy.EngineerReclaimQuota = 0
    if reclaimQuotaAllowed
        and reclaimQuotaMexReady
        and (reclaimPressureMode
            or reclaimFieldScore >= TunedReclaimScore(160)
            or ((planner.ReclaimFirst == true or planner.OuterRetentionActive == true) and reclaimFieldScore >= TunedReclaimScore(90))) then
        policy.EngineerReclaimQuota = 1
    end
    if reclaimQuotaAllowed and reclaimQuotaMexReady and reclaimFieldScore >= TunedReclaimScore(90) and (macroCounts.Engineers or 0) >= 6 then
        policy.EngineerReclaimQuota = math.max(policy.EngineerReclaimQuota, 1)
    end
    if reclaimQuotaAllowed and reclaimQuotaMexReady and reclaimFieldScore >= TunedReclaimScore(150) and (macroCounts.Engineers or 0) >= 7 then
        policy.EngineerReclaimQuota = math.max(policy.EngineerReclaimQuota, 2)
    end
    if reclaimQuotaAllowed and reclaimQuotaMexReady and reclaimFieldScore >= TunedReclaimScore(260) and reclaimWorkerReady then
        policy.EngineerReclaimQuota = math.max(policy.EngineerReclaimQuota, 3)
    end
    if reclaimQuotaAllowed and reclaimQuotaMexReady and reclaimWorkerReady and reclaimFieldScore >= TunedReclaimScore(90) and reclaimConversionDebt then
        policy.EngineerReclaimQuota = math.max(policy.EngineerReclaimQuota, 1)
    end
    if reclaimQuotaAllowed
        and reclaimQuotaMexReady
        and reclaimFieldScore >= TunedReclaimScore(120)
        and (planner.ReclaimFirst == true or planner.OuterRetentionActive == true or reclaimPressureMode)
        and (macroCounts.Engineers or 0) >= 7 then
        policy.EngineerReclaimQuota = math.max(policy.EngineerReclaimQuota, 1)
    end
    if reclaimQuotaAllowed and reclaimQuotaMexReady and reclaimFieldAvailable then
        policy.EngineerReclaimQuota = math.max(policy.EngineerReclaimQuota, 1)
    end
    if reclaimQuotaAllowed and reclaimQuotaMexReady and reclaimFieldScore >= TunedReclaimScore(190) and (velocity.ReclaimStagnationTime or 0) >= 45 and reclaimWorkerReady then
        policy.EngineerReclaimQuota = 2
    end
    if reclaimQuotaAllowed and reclaimQuotaMexReady and reclaimFieldScore >= TunedReclaimScore(220) and reclaimWorkerReady then
        policy.EngineerReclaimQuota = math.max(policy.EngineerReclaimQuota, 2)
    end
    if reclaimQuotaAllowed
        and reclaimQuotaMexReady
        and reclaimFieldScore >= TunedReclaimScore(150)
        and (velocity.ReclaimStagnationTime or 0) >= 60
        and (velocity.ReclaimRateShort or 0) <= 0.2
        and reclaimWorkerReady then
        policy.EngineerReclaimQuota = math.max(policy.EngineerReclaimQuota, 2)
    end
    policy.EngineerExpansionQuota = (contestMapMode or focusOnT1Spam or lowMexExpansionNeed) and 2 or 1
    if lowMexExpansionNeed and (macroCounts.Mex or 0) < 8 then
        policy.EngineerExpansionQuota = 3
    end
    if containmentCrisis then
        policy.ContainmentCrisis = true
        if (macroCounts.Mex or 0) <= 3 then
            policy.EngineerExpansionQuota = math.min(math.max(policy.EngineerExpansionQuota, 2), 2)
        elseif (macroCounts.Mex or 0) < containmentExpansionFloor then
            policy.EngineerExpansionQuota = math.min(math.max(policy.EngineerExpansionQuota, 2), 3)
        else
            policy.EngineerExpansionQuota = 0
        end
        if (macroCounts.Engineers or 0) >= 4 and pressure.SurvivalCrisis ~= true then
            policy.EngineerReclaimQuota = math.max(policy.EngineerReclaimQuota, 1)
        end
        if (macroCounts.Engineers or 0) >= 7 and (velocity.ReclaimStagnationTime or 0) >= 45 then
            policy.EngineerReclaimQuota = math.max(policy.EngineerReclaimQuota, 2)
        end
    end
    policy.EngineerReclaimQuota = policy.EngineerReclaimQuota + math.floor(tune.ReclaimQuotaBias or 0)
    policy.EngineerExpansionQuota = policy.EngineerExpansionQuota + math.floor(tune.ExpansionQuotaBias or 0)
    policy.EngineerLossPressure = OvermindMemory.GetEngineerLossPressure(aiBrain)
    if now >= 300 and policy.EngineerLossPressure >= 0.65 then
        policy.EngineerReclaimQuota = math.min(policy.EngineerReclaimQuota, 1)
        policy.EngineerExpansionQuota = math.min(policy.EngineerExpansionQuota, (macroCounts.Mex or 0) < 6 and 2 or 1)
    end
    policy.EngineerBaseQuota = pressure.SurvivalCrisis and 4 or ((phase == 'bootstrap' or phase == 'recover') and 3 or 2)

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
        policy.AcuOpeningMaxDistance = Clamp((tune.ACUOpeningMaxDistance or 28) + 10, 24, 42)
        policy.AcuMidMaxDistance = Clamp((tune.ACUMidMaxDistance or 40) + 8, 32, 58)
        policy.AcuOpeningMexDistance = Clamp(280 + ((tune.ACUOpeningMaxDistance or 28) * 2), 260, 350)
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
        policy.AcuOpeningMaxDistance = Clamp((tune.ACUOpeningMaxDistance or 28) + 8, 24, 42)
        policy.AcuMidMaxDistance = Clamp((tune.ACUMidMaxDistance or 40) + 8, 34, 58)
        policy.AcuOpeningMexDistance = Clamp(260 + ((tune.ACUOpeningMaxDistance or 28) * 2), 240, 340)
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

    if lowMexExpansionNeed
        or (reclaimFieldScore >= 130 and (velocity.ReclaimStagnationTime or 0) >= 60 and pressure.SurvivalCrisis ~= true) then
        policy.EngineerReserveMin = math.max(policy.EngineerReserveMin, 5)
        policy.BaseEngineerFloor = math.max(policy.BaseEngineerFloor, 4)
        policy.EngineerFactoryRatio = math.max(policy.EngineerFactoryRatio, 1.02)
    end
    if containmentCrisis then
        policy.SafeExpandDistance = math.min(policy.SafeExpandDistance, (macroCounts.Mex or 0) <= 3 and 360 or 300)
        policy.SafeExpandThreatCap = math.min(policy.SafeExpandThreatCap, 0.55)
        policy.SafeExpandEnemyBuffer = math.max(policy.SafeExpandEnemyBuffer, 120)
        policy.SafeExpandHotspotCap = math.min(policy.SafeExpandHotspotCap, 4.5)
        policy.EngineerReserveMin = math.max(policy.EngineerReserveMin, 5)
        policy.BaseEngineerFloor = math.max(policy.BaseEngineerFloor, 4)
    end

    policy.ProductionTempoBias = policy.ProductionTempoBias + (tune.FactoryTempoBias or 0)
    policy.FactoryMassIncome = policy.FactoryMassIncome + (tune.FactoryMassIncomeBias or 0)
    policy.FactoryEnergyIncome = policy.FactoryEnergyIncome + (tune.FactoryEnergyIncomeBias or 0)
    policy.FactoryMassRatio = policy.FactoryMassRatio + (tune.FactoryMassRatioBias or 0)
    policy.FactoryEnergyRatio = policy.FactoryEnergyRatio + (tune.FactoryEnergyRatioBias or 0)
    policy.FactoryMassPerFactory = policy.FactoryMassPerFactory + (tune.FactoryMassPerFactoryBias or 0)
    policy.FactoryToMexCap = policy.FactoryToMexCap + (tune.FactoryToMexCapBias or 0)
    policy.EngineerFactoryRatio = policy.EngineerFactoryRatio + (tune.EngineerFactoryRatioBias or 0)
    policy.BaseEngineerFloor = policy.BaseEngineerFloor + math.floor(tune.BaseEngineerFloorBias or 0)
    policy.SafeExpandDistance = policy.SafeExpandDistance + (tune.SafeExpandDistanceBias or 0)
    policy.SafeExpandThreatCap = policy.SafeExpandThreatCap + (tune.SafeExpandThreatCapBias or 0)
    policy.SafeExpandEnemyBuffer = policy.SafeExpandEnemyBuffer + (tune.SafeExpandEnemyBufferBias or 0)
    policy.T2MexMinTime = policy.T2MexMinTime + (tune.UpgradeTimeBias or 0)
    policy.AirFactoryMinTime = policy.AirFactoryMinTime + (tune.AirFactoryTimeBias or 0)
    policy.RadarMinTime = policy.RadarMinTime + (tune.RadarTimeBias or 0)
    policy.EnergyNeedRatio = policy.EnergyNeedRatio + (tune.PowerNeedRatioBias or 0)
    policy.SafeEnergyRatio = policy.SafeEnergyRatio + ((tune.PowerNeedRatioBias or 0) * 0.6)

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
    policy.MexUpgradeConcurrency = Clamp(policy.MexUpgradeConcurrency or 0, 0, 4)
    policy.EngineerReclaimQuota = Clamp(policy.EngineerReclaimQuota or 0, 0, 4)
    policy.EngineerExpansionQuota = Clamp(policy.EngineerExpansionQuota or 1, 0, 4)
    policy.EngineerBaseQuota = Clamp(policy.EngineerBaseQuota or 2, 1, 8)
    policy.EcoGrowthPressure = Clamp(policy.EcoGrowthPressure or 0, 0, 1.5)
    policy.ApproachFailurePressure = Clamp(policy.ApproachFailurePressure or 0, 0, 1.5)
    policy.LastUpdate = now
end
