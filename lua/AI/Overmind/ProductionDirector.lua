local Module = {
    Name = 'ProductionDirector',
    StateSlice = 'ProductionDirector',
}

local OvermindRoleWeights = import('/mods/OvermindAI/lua/AI/Overmind/RoleWeights.lua')

local LandFactoryCategory = categories.FACTORY * categories.LAND * categories.STRUCTURE
local AirFactoryCategory = categories.FACTORY * categories.AIR * categories.STRUCTURE
local SeaFactoryCategory = categories.FACTORY * categories.NAVAL * categories.STRUCTURE
local AnyFactoryCategory = categories.FACTORY * categories.STRUCTURE

local RadarCategory = categories.STRUCTURE * categories.RADAR
local SonarCategory = categories.STRUCTURE * categories.SONAR
local PDCategory = categories.STRUCTURE * categories.DEFENSE * categories.DIRECTFIRE - categories.ANTIAIR
local BaseAACategory = categories.STRUCTURE * categories.DEFENSE * categories.ANTIAIR
local ShieldCategory = categories.STRUCTURE * categories.SHIELD
local T2MissileDefenseCategory = categories.STRUCTURE * categories.ANTIMISSILE * categories.TECH2
local NavalDefenseCategory = categories.STRUCTURE * categories.DEFENSE * categories.NAVAL
local MexCategory = categories.STRUCTURE * categories.MASSEXTRACTION
local PowerCategory = categories.STRUCTURE * categories.ENERGYPRODUCTION
local MobileUnitCategory = categories.MOBILE - categories.COMMAND
local TechLandFactoryCategory = categories.FACTORY * categories.LAND * categories.STRUCTURE * (categories.TECH2 + categories.TECH3)
local TechEngineerCategory = categories.ENGINEER * categories.MOBILE * (categories.TECH2 + categories.TECH3)
local TechPowerCategory = categories.STRUCTURE * categories.ENERGYPRODUCTION * (categories.TECH2 + categories.TECH3)

local function Clamp(v, minV, maxV)
    if v < minV then
        return minV
    end
    if v > maxV then
        return maxV
    end
    return v
end

local function Round(v, digits)
    local scale = 10 ^ (digits or 0)
    return math.floor((v * scale) + 0.5) / scale
end

local function TableCount(t)
    return t and table.getn(t) or 0
end

local function NormalizeBudget(budget)
    local total = 0
    for _, value in pairs(budget) do
        total = total + math.max(0, value or 0)
    end
    if total <= 0 then
        return {
            Land = 0.34,
            Air = 0.16,
            Navy = 0,
            Intel = 0.14,
            Defense = 0.1,
            Eco = 0.18,
            Tech = 0.08,
        }
    end
    local out = {}
    for key, value in pairs(budget) do
        out[key] = math.max(0, value or 0) / total
    end
    return out
end

local function SumRoleField(rolePlan, keys, field)
    local total = 0
    for _, key in keys do
        local role = rolePlan[key]
        total = total + ((role and role[field]) or 0)
    end
    return total
end

local function CountCategory(aiBrain, category)
    if not aiBrain or not category then
        return 0
    end
    return aiBrain:GetCurrentUnits(category) or 0
end

local function NewRoleValueTable()
    return {
        Engineer = 0,
        LandDirect = 0,
        LandAA = 0,
        LandIndirect = 0,
        LandScout = 0,
        AirFighter = 0,
        AirBomber = 0,
        AirScout = 0,
        SeaSurface = 0,
        SeaSub = 0,
        SeaAA = 0,
    }
end

local function IsFinishedMobile(unit)
    if not unit or unit.Dead then
        return false
    end
    if unit:IsUnitState('BeingBuilt') or unit:IsUnitState('Upgrading') then
        return false
    end
    if unit.GetFractionComplete then
        local ok, fraction = pcall(function()
            return unit:GetFractionComplete()
        end)
        if ok and type(fraction) == 'number' and fraction < 0.95 then
            return false
        end
    end
    return true
end

local function CountExistingAndReady(aiBrain, category)
    local total = 0
    local ready = 0
    local units = aiBrain:GetListOfUnits(category, false, true) or {}
    for _, unit in units do
        if unit and not unit.Dead then
            total = total + 1
            local complete = true
            if unit.GetFractionComplete then
                local ok, fraction = pcall(function()
                    return unit:GetFractionComplete()
                end)
                if ok and type(fraction) == 'number' then
                    complete = fraction >= 0.95
                end
            end
            if complete and not unit:IsUnitState('BeingBuilt') and not unit:IsUnitState('Upgrading') then
                ready = ready + 1
            end
        end
    end
    return total, ready
end

local function BuildFactoryCounts(aiBrain)
    local landTotal, landReady = CountExistingAndReady(aiBrain, LandFactoryCategory)
    local airTotal, airReady = CountExistingAndReady(aiBrain, AirFactoryCategory)
    local seaTotal, seaReady = CountExistingAndReady(aiBrain, SeaFactoryCategory)
    local total, ready = CountExistingAndReady(aiBrain, AnyFactoryCategory)
    return {
        Land = { Total = landTotal, Ready = landReady, Pending = math.max(0, landTotal - landReady) },
        Air = { Total = airTotal, Ready = airReady, Pending = math.max(0, airTotal - airReady) },
        Navy = { Total = seaTotal, Ready = seaReady, Pending = math.max(0, seaTotal - seaReady) },
        Total = total,
        Ready = ready,
        Pending = math.max(0, total - ready),
    }
end

local function BuildRoleSupply(aiBrain)
    local supply = NewRoleValueTable()
    local units = NewRoleValueTable()
    local mobileUnits = aiBrain:GetListOfUnits(MobileUnitCategory, false, true) or {}

    for _, unit in mobileUnits do
        if IsFinishedMobile(unit) then
            local strength, roleName = OvermindRoleWeights.GetUnitStrength(unit)
            if roleName then
                units[roleName] = (units[roleName] or 0) + 1
                supply[roleName] = (supply[roleName] or 0) + strength
            end
        end
    end

    return supply, units
end

local function BuildStructureCounts(aiBrain)
    return {
        Radar = CountCategory(aiBrain, RadarCategory),
        Sonar = CountCategory(aiBrain, SonarCategory),
        PD = CountCategory(aiBrain, PDCategory),
        BaseAA = CountCategory(aiBrain, BaseAACategory),
        Shield = CountCategory(aiBrain, ShieldCategory),
        TMD = CountCategory(aiBrain, T2MissileDefenseCategory),
        NavalDefense = CountCategory(aiBrain, NavalDefenseCategory),
    }
end

local function BuildEcoCounts(aiBrain)
    local mexTotal, mexReady = CountExistingAndReady(aiBrain, MexCategory)
    local powerTotal, powerReady = CountExistingAndReady(aiBrain, PowerCategory)
    return {
        Mex = {
            Total = mexTotal,
            Ready = mexReady,
            Pending = math.max(0, mexTotal - mexReady),
        },
        Power = {
            Total = powerTotal,
            Ready = powerReady,
            Pending = math.max(0, powerTotal - powerReady),
        },
    }
end

local function BuildCurrent(aiBrain, runtime)
    local factories = BuildFactoryCounts(aiBrain)
    local roles, roleUnits = BuildRoleSupply(aiBrain)
    local structures = BuildStructureCounts(aiBrain)
    local ecoCounts = BuildEcoCounts(aiBrain)
    local engineerState = runtime and runtime.EngineerState or {}
    local factoryTask = engineerState.UnfinishedFactoryTask or {}
    return {
        Factories = factories,
        Roles = roles,
        RoleUnits = roleUnits,
        Structures = structures,
        Eco = ecoCounts,
        DomainUnits = {
            Land = roleUnits.LandDirect + roleUnits.LandAA + roleUnits.LandIndirect + roleUnits.LandScout,
            Air = roleUnits.AirFighter + roleUnits.AirBomber + roleUnits.AirScout,
            Navy = roleUnits.SeaSurface + roleUnits.SeaSub + roleUnits.SeaAA,
        },
        DomainStrength = {
            Land = roles.LandDirect + roles.LandAA + roles.LandIndirect + roles.LandScout,
            Air = roles.AirFighter + roles.AirBomber + roles.AirScout,
            Navy = roles.SeaSurface + roles.SeaSub + roles.SeaAA,
        },
        FactoryTask = {
            Active = factoryTask.Active == true,
            Domain = factoryTask.Domain or 'none',
            AssignedBuilders = factoryTask.AssignedBuilders or 0,
            RequiredBuilders = factoryTask.RequiredBuilders or 0,
            StallTime = factoryTask.StallTime or 0,
            Fraction = factoryTask.TargetFraction or factoryTask.Fraction or 1,
            ReadyFactories = factoryTask.ReadyFactories or 0,
        },
    }
end
local function GetTaskDeficit(task)
    if not task then
        return 0
    end
    return math.max(0, (task.DesiredStrength or 0) - (task.CurrentStrength or 0))
end

local function GetTaskPressure(task, deficit)
    local gap = math.max(0, deficit or 0)
    local desired = task and (task.DesiredStrength or 0) or 0
    if desired <= 0 then
        return gap > 0 and Clamp(gap, 0, 1.25) or 0
    end
    return Clamp(gap / math.max(1.25, desired), 0, 1.5)
end

local function ComputeOpponentTrends(state, opp, now)
    local prev = state.PreviousOpponent or {}
    local dt = math.max(1, now - (prev.Time or now))
    local landRate = ((opp.Land or 0) - (prev.Land or opp.Land or 0)) * 60 / dt
    local airRate = ((opp.Air or 0) - (prev.Air or opp.Air or 0)) * 60 / dt
    local navyRate = ((opp.Navy or 0) - (prev.Navy or opp.Navy or 0)) * 60 / dt

    local trends = state.OpponentTrends or {
        Land = 0,
        Air = 0,
        Navy = 0,
    }
    trends.Land = (trends.Land * 0.65) + (landRate * 0.35)
    trends.Air = (trends.Air * 0.65) + (airRate * 0.35)
    trends.Navy = (trends.Navy * 0.65) + (navyRate * 0.35)
    state.OpponentTrends = trends
    state.PreviousOpponent = {
        Time = now,
        Land = opp.Land or 0,
        Air = opp.Air or 0,
        Navy = opp.Navy or 0,
    }
    return trends
end

local function ComputeConfidence(runtime, current, navalActive)
    local graph = runtime.ZoneGraph or {}
    local intel = runtime.IntelModel or {}
    local nodes = math.max(1, TableCount(graph.Nodes or {}))
    local stale = Clamp(intel.StaleZones or nodes, 0, nodes)
    local freshRatio = Clamp((nodes - stale) / nodes, 0, 1)
    local sourcePenalty = ((graph.GraphSource or '') == 'nav' or graph.NavGraphBuilt) and 0 or 0.12
    local global = Clamp(0.32 + (freshRatio * 0.52) - sourcePenalty, 0.18, 0.95)
    local land = Clamp(global + (((intel.ContestedZones or 0) > 0) and 0.06 or 0), 0.2, 0.97)
    local airScoutUnits = (current.RoleUnits and current.RoleUnits.AirScout) or 0
    local air = Clamp(global + ((((intel.AirThreatZones or 0) > 0) or airScoutUnits > 0) and 0.08 or -0.04), 0.15, 0.97)
    local navy = Clamp(global - (navalActive and 0.02 or 0.16), 0.1, 0.9)
    return {
        Global = global,
        Land = land,
        Air = air,
        Navy = navy,
    }, 1 - freshRatio
end

local function BuildConstraints(runtime, current, confidence, scoutingDebt, navalActive, now)
    local eco = runtime.EcoState or {}
    local recovery = runtime.Recovery or {}
    local intel = runtime.IntelModel or {}
    local opp = runtime.OpponentModel or {}
    local force = runtime.ForceDirector or {}
    local tasks = force.Tasks or {}
    local roleDemand = force.RoleDemand or {}
    local policy = runtime.EcoPolicy or {}
    local raid = runtime.RaidDefense or {}
    local clusterState = runtime.EnemyClusterTracker or {}
    local approachCluster = clusterState.ApproachCluster or {}
    local enemyIndirectHeavy = opp.IndirectHeavy == true
    local enemyT2Push = opp.T2Push == true
    local enemyLowAirThreat = opp.LowAirThreat == true
    local engineerState = runtime.EngineerState or {}
    local factoryTask = engineerState.UnfinishedFactoryTask or {}
    local structureTask = engineerState.UnfinishedStructureTask or {}
    local criticalFactory = factoryTask.Active == true
    local criticalStructure = structureTask.Active == true
        and (string.lower(structureTask.Kind or 'none') == 'mex'
            or string.lower(structureTask.Kind or 'none') == 'power'
            or string.lower(structureTask.Kind or 'none') == 'radar')
        and ((structureTask.AssignedBuilders or 0) < (structureTask.RequiredBuilders or 0))

    local frontDeficit = math.max(GetTaskDeficit(tasks.front_hold), roleDemand.MainLine or 0)
    local baseDeficit = math.max(GetTaskDeficit(tasks.base_guard), roleDemand.BaseGuard or 0)
    local escortDeficit = math.max(GetTaskDeficit(tasks.acu_escort), roleDemand.ACUEscort or 0)
    local raidDeficit = math.max(GetTaskDeficit(tasks.raid), roleDemand.Raider or 0)
    local airGuardDeficit = math.max(GetTaskDeficit(tasks.air_guard), roleDemand.AirGuard or 0)
    local scoutDeficit = math.max(GetTaskDeficit(tasks.scout_screen), 0)
    local bomberDeficit = math.max(GetTaskDeficit(tasks.bomber_strike), roleDemand.BomberStrike or 0)
    local interceptDeficit = math.max(GetTaskDeficit(tasks.intercept_cluster), roleDemand.Intercept or 0)
    local frontPressure = GetTaskPressure(tasks.front_hold, frontDeficit)
    local basePressure = GetTaskPressure(tasks.base_guard, baseDeficit)
    local escortPressure = GetTaskPressure(tasks.acu_escort, escortDeficit)
    local raidPressure = GetTaskPressure(tasks.raid, raidDeficit)
    local airGuardPressure = GetTaskPressure(tasks.air_guard, airGuardDeficit)
    local scoutPressure = GetTaskPressure(tasks.scout_screen, scoutDeficit)
    local bomberPressure = GetTaskPressure(tasks.bomber_strike, bomberDeficit)
    local interceptPressure = GetTaskPressure(tasks.intercept_cluster, interceptDeficit)
    local approachThreat = approachCluster.TotalThreat or 0
    local approachDistance = approachCluster.HomeDistance or 999
    local approachConfidence = approachCluster.ContactConfidence or 0
    local approachConfirmedUnits = approachCluster.ConfirmedUnits or 0
    local approachMemoryThreat = approachCluster.MemoryThreat or 0
    local approachMemoryHits = approachCluster.MemoryHits or 0
    local bomberPanic = ((raid.BomberPanicUntil or -999) > now)
        or ((raid.UnderAirHarass or false) and ((raid.LastBomberEnemyCount or 0) >= 1))
    local bomberWatch = not bomberPanic
        and ((opp.Bomber or 0) >= 1)
        and (
            confidence.Air >= 0.32
            or (raid.LastBomberEnemyCount or 0) >= 1
            or (approachConfirmedUnits or 0) >= 1
        )
    local exposedMexAirRaid = raid.ExposedMexUnderAirRaid == true and raid.ExposedMexThreatPos ~= false
    local bomberRaidSeverity = math.max(raid.BomberRaidSeverity or 0, raid.LastBomberEnemyCount or 0)
    local severeBomberRaid = (bomberPanic or exposedMexAirRaid)
        and (bomberRaidSeverity >= 3 or (raid.LastBomberEnemyCount or 0) >= 2)
    local approachPressure = 0
    if approachThreat > 0 and (approachConfirmedUnits > 0 or approachMemoryThreat >= 1.2 or approachConfidence >= 0.42) then
        local landBaseline = math.max(5, ((current.DomainStrength and current.DomainStrength.Land) or 0) * 0.55)
        local distanceWeight = (approachDistance < 160) and 1.2 or ((approachDistance < 260) and 0.9 or 0.55)
        local confidenceWeight = Clamp(0.45 + (approachConfidence * 0.75), 0.45, 1.2)
        approachPressure = Clamp((approachThreat / landBaseline) * distanceWeight * confidenceWeight, 0, 1.5)
        if approachCluster.Classification == 'rear' then
            basePressure = math.max(basePressure, approachPressure)
        else
            frontPressure = math.max(frontPressure, approachPressure)
            if approachDistance < 180 then
                basePressure = math.max(basePressure, approachPressure * 0.72)
            end
        end
    end
    if interceptPressure > 0 then
        basePressure = math.max(basePressure, interceptPressure * 0.82)
        frontPressure = math.max(frontPressure, interceptPressure * 0.56)
    end

    local ecoWeak = (eco.MassStorageRatio or 0) <= 0.08 or (eco.EnergyStorageRatio or 0) <= 0.08
        or (eco.MassTrend or 0) <= -0.08 or (eco.EnergyTrend or 0) <= -6
    local ecoCrash = (eco.MassStorageRatio or 0) <= 0.01 and (eco.EnergyStorageRatio or 0) <= 0.01
        and (eco.MassTrend or 0) <= -0.7 and (eco.EnergyTrend or 0) <= -24
    local counterAirWindow = enemyT2Push
        and enemyLowAirThreat
        and current.Factories.Land.Ready >= 2
        and not ecoCrash
    local durableSurplus = (eco.MassIncome or 0) >= 7
        and (eco.EnergyIncome or 0) >= 120
        and (eco.MassStorageRatio or 0) >= 0.22
        and (eco.EnergyStorageRatio or 0) >= 0.2
        and (eco.MassTrend or 0) >= 0.02
        and (eco.EnergyTrend or 0) >= 8
    local engineerUnits = (current.RoleUnits and current.RoleUnits.Engineer) or 0
    local mexReady = (((current.Eco or {}).Mex or {}).Ready) or 0
    local powerReady = (((current.Eco or {}).Power or {}).Ready) or 0
    local radarReady = (current.Structures and current.Structures.Radar) or 0
    local bootstrapEngineerFloor = (current.Factories.Land.Ready <= 1) and 4 or 5
    local bootstrapMexFloor = (current.Factories.Land.Ready <= 1) and 3 or 4
    local bootstrapPowerFloor = (current.Factories.Land.Ready <= 1) and 1 or 2
    local starterEngineerFloor = (current.Factories.Land.Ready <= 1) and 6 or 7
    local starterMexFloor = (current.Factories.Land.Ready <= 1) and 5 or 6
    local starterPowerFloor = (current.Factories.Land.Ready <= 1) and 2 or 3
    local powerTotal = (((current.Eco or {}).Power or {}).Total) or 0
    local powerDesiredReady = math.max(starterPowerFloor, math.min(6, math.ceil(math.max(1, mexReady) / 2.5)))
    local powerBufferLow = now < 960 and (
        powerReady < powerDesiredReady
        or (mexReady >= 5 and ((eco.EnergyStorageRatio or 0) < 0.18 or (eco.EnergyTrend or 0) < 2))
    )
    local econBootstrap = now < 540 and (
        engineerUnits < bootstrapEngineerFloor
        or (mexReady < bootstrapMexFloor and (eco.MassIncome or 0) < 3.6)
        or powerReady < bootstrapPowerFloor
        or (powerTotal < bootstrapPowerFloor and ((eco.EnergyIncome or 0) < 55 or (eco.EnergyTrend or 0) < 4))
    )
    local starterRadarRequired = now >= 120
        and powerReady >= starterPowerFloor
        and mexReady >= math.max(2, starterMexFloor - 2)
    local radarCritical = powerReady > 0
        and radarReady <= 0
        and (
            starterRadarRequired
            or bomberWatch
            or bomberPanic
            or exposedMexAirRaid
            or raid.UnderAirHarass
            or ((intel.StaleZones or 0) >= 3 and now >= 180)
        )
    local starterPhase = now < 720 and (
        engineerUnits < starterEngineerFloor
        or mexReady < starterMexFloor
        or powerReady < starterPowerFloor
        or ((now < 360 or current.Factories.Total <= 1) and powerBufferLow)
        or (starterRadarRequired and radarReady < 1)
        or criticalFactory
        or (criticalStructure and ((structureTask.Kind == 'Power') or (structureTask.Kind == 'Radar') or (structureTask.Kind == 'Mex')))
    )

    local realApproach = ((approachConfirmedUnits > 0) and approachDistance < 230 and approachConfidence >= 0.28)
        or ((approachMemoryThreat >= 2.4) and approachMemoryHits >= 3 and approachDistance < 150 and approachConfidence >= 0.30)
    local confirmedHarass = raid.UnderLandHarass
        or raid.UnderAirHarass
        or bomberPanic
        or exposedMexAirRaid
        or (((approachPressure >= 0.56) and realApproach))
    local queueStarved = recovery.FactoryQueueExpansionBlocked
        or (((recovery.FactoryQueueDeficitRatio or 0) >= 0.34) and ((recovery.FactoryQueueStarvationTime or 0) >= 10))
    local unitCapPressure = (eco.UnitLoad or 0) >= 0.96
    local frontCollapse = confirmedHarass
        or ((confidence.Global >= 0.48) and (frontPressure >= 0.54 or (((opp.RelativeLand or 1) < 0.74) and (intel.ContestedZones or 0) >= 2)))
    local landPanic = raid.UnderLandHarass
        or (frontCollapse and confidence.Global >= 0.42)
        or (((basePressure >= 0.52) and confidence.Global >= 0.48))
        or (realApproach and approachPressure >= 0.92 and approachDistance < 170)
    local airPanic = raid.UnderAirHarass
        or bomberPanic
        or exposedMexAirRaid
        or (((airGuardPressure >= 0.48) or (((opp.RelativeAir or 1) < 0.78) and (opp.Air or 0) > 4)) and confidence.Air >= 0.5)
    local visionPanic = scoutingDebt >= 0.55 or scoutPressure >= 0.45 or ((intel.StaleZones or 0) >= math.max(2, math.floor(math.max(1, TableCount((runtime.ZoneGraph or {}).Nodes or {})) * 0.5)))
    local openerThreatLock = now < 240
        and confidence.Global < 0.48
        and not raid.UnderLandHarass
        and not raid.UnderAirHarass
        and (current.Factories.Ready or 0) <= 1
    if openerThreatLock then
        frontCollapse = false
        landPanic = false
        airPanic = false
    end
    local navyLowValue = (not navalActive) or (((opp.Navy or 0) <= 0) and ((runtime.ZoneModel and runtime.ZoneModel.MapControl) or 0) < 0.62 and now < 900)
    local surplusSpendWindow = not ecoCrash
        and not queueStarved
        and not criticalFactory
        and not criticalStructure
        and not unitCapPressure
        and not econBootstrap
        and engineerUnits >= math.max(6, starterEngineerFloor - 1)
        and powerReady >= math.max(3, starterPowerFloor)
        and mexReady >= math.max(5, starterMexFloor - 1)
        and (
            (
                (eco.MassStorageRatio or 0) >= 0.4
                and (eco.EnergyStorageRatio or 0) >= 0.3
                and (eco.MassTrend or 0) >= 0.08
                and (eco.EnergyTrend or 0) >= 4
            )
            or (
                durableSurplus
                and (eco.MassStorageRatio or 0) >= 0.28
                and (eco.EnergyStorageRatio or 0) >= 0.24
            )
        )
    local strongSurplusWindow = surplusSpendWindow
        and (eco.MassStorageRatio or 0) >= 0.62
        and (eco.EnergyStorageRatio or 0) >= 0.46
        and (eco.MassTrend or 0) >= 0.14
        and (eco.EnergyTrend or 0) >= 8
    local techBlocked = ecoWeak or queueStarved or frontCollapse or airPanic or visionPanic or unitCapPressure or confidence.Global < 0.5 or criticalFactory or criticalStructure or econBootstrap or starterPhase

    local engineerFloor = math.max((policy.EngineerReserveMin or 4), math.floor((current.Factories.Ready or 0) * ((policy.EngineerFactoryRatio or 1.0) + 0.1)))
    if now < 360 or current.Factories.Land.Ready <= 1 then
        engineerFloor = math.max(engineerFloor, 6)
    end
    if econBootstrap then
        engineerFloor = math.max(engineerFloor, 8)
    end
    if starterPhase then
        engineerFloor = math.max(engineerFloor, starterEngineerFloor)
    end
    if criticalFactory then
        engineerFloor = engineerFloor + math.max(1, (factoryTask.RequiredBuilders or 0) - (factoryTask.AssignedBuilders or 0) + 1)
    end
    if criticalStructure then
        engineerFloor = engineerFloor + math.max(1, (structureTask.RequiredBuilders or 0) - (structureTask.AssignedBuilders or 0))
    end
    if bomberPanic or exposedMexAirRaid then
        engineerFloor = engineerFloor + 2
    end
    if severeBomberRaid then
        engineerFloor = engineerFloor + 1
    end

    local contestStarterThreat = (policy.ContestMapMode == true or policy.PrioritizeProduction == true)
        and (
            (intel.ContestedZones or 0) >= 2
            or realApproach
            or frontPressure >= 0.24
            or basePressure >= 0.18
        )

    if starterPhase and not confirmedHarass and not contestStarterThreat then
        frontCollapse = false
        landPanic = false
        airPanic = false
        frontPressure = math.min(frontPressure, 0.22)
        basePressure = math.min(basePressure, 0.18)
        escortPressure = math.min(escortPressure, 0.2)
        approachPressure = math.min(approachPressure, 0.24)
    end

    return {
        FrontDeficit = frontDeficit,
        BaseDeficit = baseDeficit,
        EscortDeficit = escortDeficit,
        RaidDeficit = raidDeficit,
        AirGuardDeficit = airGuardDeficit,
        ScoutDeficit = scoutDeficit,
        BomberDeficit = bomberDeficit,
        FrontPressure = Round(frontPressure, 2),
        BasePressure = Round(basePressure, 2),
        EscortPressure = Round(escortPressure, 2),
        RaidPressure = Round(raidPressure, 2),
        AirGuardPressure = Round(airGuardPressure, 2),
        ScoutPressure = Round(scoutPressure, 2),
        BomberPressure = Round(bomberPressure, 2),
        InterceptPressure = Round(interceptPressure, 2),
        EcoWeak = ecoWeak,
        EcoCrash = ecoCrash,
        DurableSurplus = durableSurplus,
        SurplusSpendWindow = surplusSpendWindow and true or false,
        StrongSurplusWindow = strongSurplusWindow and true or false,
        QueueStarved = queueStarved,
        EconBootstrap = econBootstrap,
        UnitCapPressure = unitCapPressure,
        FrontCollapse = frontCollapse,
        LandPanic = landPanic,
        AirPanic = airPanic,
        VisionPanic = visionPanic,
        CriticalFactory = criticalFactory,
        CriticalFactoryDomain = factoryTask.Domain or 'none',
        CriticalFactoryAssigned = factoryTask.AssignedBuilders or 0,
        CriticalFactoryRequired = factoryTask.RequiredBuilders or 0,
        CriticalFactoryStall = factoryTask.StallTime or 0,
        CriticalFactoryFraction = factoryTask.TargetFraction or factoryTask.Fraction or 1,
        CriticalStructure = criticalStructure,
        CriticalStructureKind = structureTask.Kind or 'none',
        CriticalStructureAssigned = structureTask.AssignedBuilders or 0,
        CriticalStructureRequired = structureTask.RequiredBuilders or 0,
        CriticalStructureStall = structureTask.StallTime or 0,
        CriticalStructureFraction = structureTask.TargetFraction or structureTask.Fraction or 1,
        NavalActive = navalActive,
        NavyLowValue = navyLowValue,
        TechBlocked = techBlocked,
        EngineerFloor = engineerFloor,
        OpenerThreatLock = openerThreatLock,
        ApproachPressure = Round(approachPressure, 2),
        ApproachThreat = Round(approachThreat, 1),
        ApproachDistance = Round(approachDistance, 1),
        ApproachConfidence = Round(approachConfidence, 2),
        ApproachConfirmedUnits = approachConfirmedUnits,
        ApproachMemoryHits = approachMemoryHits,
        ApproachReal = realApproach and true or false,
        BootstrapMexFloor = bootstrapMexFloor,
        BootstrapPowerFloor = bootstrapPowerFloor,
        StarterPhase = starterPhase,
        StarterEngineerFloor = starterEngineerFloor,
        StarterMexFloor = starterMexFloor,
        StarterPowerFloor = starterPowerFloor,
        PowerDesiredReady = powerDesiredReady,
        PowerBufferLow = powerBufferLow and true or false,
        EnemyIndirectHeavy = enemyIndirectHeavy and true or false,
        EnemyT2Push = enemyT2Push and true or false,
        EnemyLowAirThreat = enemyLowAirThreat and true or false,
        CounterAirWindow = counterAirWindow and true or false,
        StarterRadarRequired = starterRadarRequired and true or false,
        ContestedZones = intel.ContestedZones or 0,
        StaleZones = intel.StaleZones or 0,
        AirThreatZones = intel.AirThreatZones or 0,
        MapControl = (runtime.ZoneModel and runtime.ZoneModel.MapControl) or 0,
        ConfirmedHarass = confirmedHarass and true or false,
        BomberWatch = bomberWatch and true or false,
        BomberPanic = bomberPanic and true or false,
        ExposedMexAirRaid = exposedMexAirRaid and true or false,
        BomberRaidSeverity = Round(bomberRaidSeverity, 2),
        SevereBomberRaid = severeBomberRaid and true or false,
        RadarCritical = radarCritical and true or false,
    }
end

local function ScoreModes(now, runtime, current, constraints, trends, confidence)
    local opp = runtime.OpponentModel or {}
    local recovery = runtime.Recovery or {}
    local raid = runtime.RaidDefense or {}
    local planner = runtime.StrategicPlanner or {}
    local directive = planner.Directive or 'stabilize'
    local primaryTheater = planner.PrimaryTheater or 'Front'

    local stabilize = 0
    stabilize = stabilize + ((now < 220) and 2.2 or 0)
    stabilize = stabilize + (constraints.EcoWeak and 2.5 or 0)
    stabilize = stabilize + (constraints.QueueStarved and 2.1 or 0)
    stabilize = stabilize + ((recovery.ForceFactoryRecovery or recovery.ForceBaseEngineerRecovery) and 2.2 or 0)
    stabilize = stabilize + ((current.Factories.Ready <= 1) and 1.6 or 0)
    stabilize = stabilize + (constraints.CriticalFactory and 2.8 or 0)
    stabilize = stabilize + (constraints.EconBootstrap and 2.8 or 0)
    stabilize = stabilize + (constraints.StarterPhase and 3.2 or 0)

    local defend = 0
    defend = defend + (constraints.LandPanic and 2.4 or 0)
    defend = defend + (constraints.AirPanic and 2.2 or 0)
    defend = defend + (constraints.FrontPressure * 3.0)
    defend = defend + (constraints.BasePressure * 2.6)
    defend = defend + (constraints.EscortPressure * 1.7)
    defend = defend + (constraints.InterceptPressure * 2.1)
    defend = defend + ((constraints.ApproachReal and constraints.ApproachPressure) or 0) * (1.2 + (constraints.ApproachConfidence * 0.8))
    defend = defend + (constraints.ExposedMexAirRaid and 0.9 or 0)
    defend = defend + (((opp.RelativePower or 1) < 0.95) and 1.1 or 0)
    defend = defend + (constraints.CriticalStructure and 1.4 or 0)
    defend = defend - (constraints.EconBootstrap and 0.9 or 0)
    defend = defend - (constraints.StarterPhase and (constraints.ConfirmedHarass and 0.4 or 2.4) or 0)
    if not raid.UnderLandHarass and not raid.UnderAirHarass and confidence.Global < 0.42 and current.Factories.Ready <= 2 then
        defend = defend - 1.8
        stabilize = stabilize + 1.2
    end
    if not constraints.ConfirmedHarass and constraints.ApproachConfidence < 0.42 then
        defend = defend - 1.1
        stabilize = stabilize + 0.8
    end
    if current.Factories.Ready <= 2 and not constraints.ConfirmedHarass and constraints.BasePressure < 0.55 then
        defend = defend - 0.9
        stabilize = stabilize + 0.5
    end
    if now < 320 and not constraints.ConfirmedHarass and not constraints.ApproachReal then
        defend = defend - 2.2
        stabilize = stabilize + 1.1
    end
    if constraints.RadarCritical and not constraints.ConfirmedHarass then
        defend = defend - 0.8
        stabilize = stabilize + 0.6
    end
    if constraints.CounterAirWindow and not constraints.AirPanic and not constraints.BomberPanic then
        defend = defend - 0.35
    end

    local pressure = 0
    pressure = pressure + (constraints.DurableSurplus and 1.9 or 0)
    pressure = pressure + (constraints.CounterAirWindow and 0.4 or 0)
    pressure = pressure + (((opp.RelativePower or 1) > 1.05) and 1.7 or 0)
    pressure = pressure + math.max(0, (constraints.MapControl - 0.48) * 4.2)
    pressure = pressure + math.max(0, trends.Land * 0.08)
    pressure = pressure - (constraints.LandPanic and 2.2 or 0)
    pressure = pressure - (constraints.AirPanic and 1.4 or 0)
    pressure = pressure - (constraints.CriticalFactory and 2.6 or 0)
    pressure = pressure - (constraints.EconBootstrap and 3.4 or 0)
    pressure = pressure - (constraints.StarterPhase and 3.2 or 0)

    local expand = 0
    expand = expand + math.max(0, (0.62 - constraints.MapControl) * 4.6)
    expand = expand + ((confidence.Global >= 0.55) and 0.8 or 0)
    expand = expand + (constraints.RaidPressure * 0.9)
    expand = expand - (constraints.EcoWeak and 1.2 or 0)
    expand = expand - (constraints.LandPanic and 1.8 or 0)
    expand = expand - (constraints.CriticalFactory and 2.4 or 0)
    expand = expand - (constraints.CriticalStructure and 1.6 or 0)
    expand = expand - (constraints.EconBootstrap and 2.6 or 0)
    expand = expand - (constraints.StarterPhase and 1.6 or 0)

    local airControl = 0
    airControl = airControl + (constraints.AirPanic and 2.5 or 0)
    airControl = airControl + (constraints.BomberWatch and 0.7 or 0)
    airControl = airControl + (constraints.BomberPanic and 1.6 or 0)
    airControl = airControl + (constraints.ExposedMexAirRaid and 1.0 or 0)
    airControl = airControl + (constraints.CounterAirWindow and 1.35 or 0)
    airControl = airControl + (constraints.AirGuardPressure * 2.8)
    airControl = airControl + math.max(0, ((opp.Air or 0) * (0.35 + (0.65 * confidence.Air))) - (current.DomainStrength.Air or 0)) * 0.08
    airControl = airControl + math.max(0, trends.Air * 0.12)
    airControl = airControl + (((opp.RelativeAir or 1) < 0.9) and 1.1 or 0)
    airControl = airControl - (constraints.EconBootstrap and 2.1 or 0)
    airControl = airControl - (constraints.StarterPhase and not (constraints.BomberPanic or constraints.ExposedMexAirRaid) and 2.3 or 0)

    local navalContest = -999
    if constraints.NavalActive and not constraints.NavyLowValue then
        navalContest = 0
        navalContest = navalContest + (((opp.Navy or 0) > 0) and 1.6 or 0)
        navalContest = navalContest + math.max(0, trends.Navy * 0.18)
        navalContest = navalContest + (((opp.RelativeNavy or 1) < 0.92) and 1.1 or 0)
        navalContest = navalContest - (constraints.EcoWeak and 0.8 or 0)
    end

    local techWindow = 0
    techWindow = techWindow + (constraints.DurableSurplus and 2.0 or 0)
    techWindow = techWindow + ((not constraints.TechBlocked) and 1.3 or -1.5)
    techWindow = techWindow + math.max(0, (constraints.MapControl - 0.45) * 2.8)
    techWindow = techWindow + (((opp.RelativePower or 1) >= 0.95) and 0.8 or 0)
    techWindow = techWindow - (constraints.VisionPanic and 1.0 or 0)
    techWindow = techWindow - (constraints.CriticalFactory and 2.8 or 0)
    techWindow = techWindow - (constraints.CriticalStructure and 1.8 or 0)
    techWindow = techWindow - (constraints.EconBootstrap and 3.0 or 0)
    techWindow = techWindow - (constraints.StarterPhase and 3.4 or 0)

    if directive == 'stabilize' then
        stabilize = stabilize + 1.9
        defend = defend + 0.9
        pressure = pressure - 0.8
        expand = expand - 0.8
        techWindow = techWindow - 0.4
    elseif directive == 'expand' then
        expand = expand + 1.6
        pressure = pressure + 0.3
    elseif directive == 'punish_greed' then
        pressure = pressure + 1.4
        techWindow = techWindow - 0.6
    elseif directive == 'force_air_answer' then
        airControl = airControl + 1.6
        pressure = pressure + 0.4
        techWindow = techWindow - 0.6
    elseif directive == 'trade_map_for_tech' then
        techWindow = techWindow + 1.6
        pressure = pressure - 0.4
    elseif directive == 'trade_tech_for_tempo' then
        pressure = pressure + 1.5
        techWindow = techWindow - 1.2
    end

    if planner.ForceAirAnswer then
        airControl = airControl + 0.9
    end
    if planner.PunishGreed then
        pressure = pressure + 0.8
    end
    if primaryTheater == 'Home' then
        defend = defend + 0.7
        stabilize = stabilize + 0.5
    elseif primaryTheater == 'Front' then
        pressure = pressure + 0.6
        defend = defend + 0.25
    elseif primaryTheater == 'Enemy' then
        pressure = pressure + 0.8
        expand = expand + 0.2
    elseif primaryTheater == 'Navy' then
        techWindow = techWindow + 0.2
    end

    return {
        stabilize = stabilize,
        defend = defend,
        pressure = pressure,
        expand = expand,
        air_control = airControl,
        naval_contest = navalContest,
        tech_window = techWindow,
    }
end
local function PickMode(state, scores, now)
    local currentMode = state.Mode or 'stabilize'
    local currentScore = scores[currentMode] or -999
    local bestMode = currentMode
    local bestScore = currentScore
    for mode, score in pairs(scores) do
        if score > bestScore then
            bestMode = mode
            bestScore = score
        end
    end

    if currentMode ~= bestMode and (now - (state.LastModeSwitch or -999)) >= 45 and bestScore > (currentScore + 0.45) then
        state.Mode = bestMode
        state.LastModeSwitch = now
    elseif not state.Mode then
        state.Mode = bestMode
        state.LastModeSwitch = now
    end

    return state.Mode or bestMode, bestScore, currentMode, currentScore
end

local function BaseDomainBudget(mode)
    if mode == 'defend' then
        return { Land = 0.36, Air = 0.18, Navy = 0.04, Intel = 0.1, Defense = 0.14, Eco = 0.12, Tech = 0.06 }
    elseif mode == 'pressure' then
        return { Land = 0.42, Air = 0.2, Navy = 0.04, Intel = 0.08, Defense = 0.06, Eco = 0.11, Tech = 0.09 }
    elseif mode == 'expand' then
        return { Land = 0.32, Air = 0.16, Navy = 0.02, Intel = 0.16, Defense = 0.07, Eco = 0.2, Tech = 0.07 }
    elseif mode == 'air_control' then
        return { Land = 0.26, Air = 0.3, Navy = 0.02, Intel = 0.13, Defense = 0.11, Eco = 0.11, Tech = 0.07 }
    elseif mode == 'naval_contest' then
        return { Land = 0.22, Air = 0.14, Navy = 0.29, Intel = 0.1, Defense = 0.07, Eco = 0.1, Tech = 0.08 }
    elseif mode == 'tech_window' then
        return { Land = 0.28, Air = 0.18, Navy = 0.03, Intel = 0.08, Defense = 0.06, Eco = 0.12, Tech = 0.25 }
    end
    return { Land = 0.34, Air = 0.14, Navy = 0.02, Intel = 0.14, Defense = 0.1, Eco = 0.18, Tech = 0.08 }
end

local function BuildDemandLedger(runtime, current, constraints, trends, confidence, mode)
    local opp = runtime.OpponentModel or {}
    local raid = runtime.RaidDefense or {}

    local raidWindow = Clamp((constraints.RaidPressure * 0.82) + ((mode == 'pressure' or mode == 'expand') and 0.18 or 0) - (constraints.LandPanic and 0.12 or 0), 0, 1)
    local airRisk = ((opp.Air or 0) * (0.3 + (0.7 * confidence.Air))) + (math.max(0, trends.Air) * 0.4) + (constraints.AirThreatZones * 2)
    local landRisk = ((opp.Land or 0) * (0.35 + (0.65 * confidence.Land))) + (math.max(0, trends.Land) * 0.35) + (constraints.ContestedZones * 3)
    local navyRisk = constraints.NavalActive and (((opp.Navy or 0) * (0.25 + (0.75 * confidence.Navy))) + math.max(0, trends.Navy) * 0.45) or 0
    local counterStrike = constraints.CounterAirWindow
        and Clamp((math.max(constraints.FrontPressure, constraints.ApproachPressure, constraints.InterceptPressure) * 1.55)
            + (constraints.EnemyIndirectHeavy and 0.28 or 0)
            + (constraints.EnemyT2Push and 0.18 or 0), 0, 1)
        or 0

    return {
        FrontHold = constraints.FrontPressure,
        BaseGuard = constraints.BasePressure,
        ACUEscort = constraints.EscortPressure,
        Raid = constraints.RaidPressure,
        AirGuard = constraints.AirGuardPressure,
        ScoutScreen = constraints.ScoutPressure,
        BomberStrike = constraints.BomberPressure,
        FrontPressure = constraints.FrontPressure,
        BasePressure = constraints.BasePressure,
        EscortPressure = constraints.EscortPressure,
        RaidPressure = constraints.RaidPressure,
        AirGuardPressure = constraints.AirGuardPressure,
        ScoutPressure = constraints.ScoutPressure,
        BomberPressure = constraints.BomberPressure,
        RaidWindow = raidWindow,
        LandRisk = landRisk,
        NavyRisk = navyRisk,
        ScoutingDebt = constraints.StaleZones + (constraints.VisionPanic and 2 or 0),
        ExpansionPressure = math.max(0,
            math.max(0, (0.58 - constraints.MapControl) * 10)
            + ((mode == 'expand') and 2 or 0)
            - (constraints.BomberWatch and 1 or 0)
            - ((constraints.ExposedMexAirRaid or constraints.BomberPanic) and 3 or 0)),
        IntelNeed = (constraints.StaleZones * 1.35) + (constraints.ScoutPressure * 5.2) + ((confidence.Global < 0.55) and 2 or 0),
        EcoRecovery = (constraints.EcoWeak and 3 or 0)
            + ((((current.RoleUnits and current.RoleUnits.Engineer) or 0) < constraints.EngineerFloor) and 2 or 0)
            + (constraints.CriticalStructure and 1.5 or 0)
            + (constraints.EconBootstrap and 3.5 or 0)
            + (constraints.BomberWatch and 0.8 or 0)
            + ((constraints.BomberPanic or constraints.ExposedMexAirRaid) and 2.5 or 0),
        DefensePressure = (constraints.LandPanic and 3 or 0)
            + (constraints.AirPanic and 3 or 0)
            + (constraints.ExposedMexAirRaid and 2 or 0)
            + constraints.ContestedZones,
        AirRisk = airRisk + (constraints.BomberWatch and 6 or 0) + ((constraints.BomberPanic or constraints.ExposedMexAirRaid) and 16 or 0),
        BomberOpportunity = (((raid.LastAirEnemyCount or 0) <= 2 and not constraints.AirPanic and not constraints.BomberPanic and confidence.Global >= 0.48) or counterStrike > 0.18) and 1 or 0,
        CounterStrike = counterStrike,
    }
end

local function DecideDomainBudget(runtime, mode, constraints, demand, confidence, macroObjective)
    local policy = runtime.EcoPolicy or {}
    local prioritizeProduction = policy.PrioritizeProduction == true
    local contestMapMode = policy.ContestMapMode == true
    local preferTempoFromSurplus = policy.PreferTempoFromSurplus == true
    local raw = BaseDomainBudget(mode)

    raw.Land = raw.Land + (demand.FrontPressure * 0.14) + (demand.BasePressure * 0.09) + (demand.EscortPressure * 0.06)
    raw.Air = raw.Air + (demand.AirGuardPressure * 0.18) + (demand.AirRisk * 0.0022)
    raw.Navy = raw.Navy + (constraints.NavalActive and demand.NavyRisk * 0.003 or -0.08)
    raw.Intel = raw.Intel + (demand.IntelNeed * 0.015) + (demand.ScoutingDebt * 0.006)
    raw.Defense = raw.Defense + (demand.DefensePressure * 0.018)
    raw.Eco = raw.Eco + (constraints.EcoWeak and 0.1 or 0) + (demand.EcoRecovery * 0.018)
    raw.Tech = raw.Tech + ((not constraints.TechBlocked) and 0.06 or -0.08)

    if constraints.AirPanic then
        raw.Air = raw.Air + 0.07
        raw.Defense = raw.Defense + 0.04
        raw.Tech = raw.Tech - 0.06
    end
    if constraints.LandPanic then
        raw.Land = raw.Land + 0.08
        raw.Defense = raw.Defense + 0.05
        raw.Tech = raw.Tech - 0.05
    end
    if constraints.QueueStarved then
        raw.Eco = raw.Eco + 0.06
        raw.Tech = raw.Tech - 0.04
    end
    if constraints.CriticalFactory then
        raw.Eco = raw.Eco + 0.07
        if constraints.CriticalFactoryDomain == 'Land' then
            raw.Land = raw.Land + 0.08
        elseif constraints.CriticalFactoryDomain == 'Air' then
            raw.Air = raw.Air + 0.07
        elseif constraints.CriticalFactoryDomain == 'Navy' then
            raw.Navy = raw.Navy + 0.08
        end
        raw.Tech = raw.Tech - 0.08
        raw.Intel = raw.Intel - 0.02
    end
    if constraints.VisionPanic then
        raw.Intel = raw.Intel + 0.08
        raw.Air = raw.Air - 0.02
        raw.Tech = raw.Tech - 0.03
    end
    if constraints.NavyLowValue then
        raw.Navy = 0
        raw.Land = raw.Land + 0.03
        raw.Eco = raw.Eco + 0.01
    end
    if confidence.Global < 0.45 then
        raw.Intel = raw.Intel + 0.05
        raw.Tech = raw.Tech - 0.03
        raw.Air = raw.Air - 0.01
    end
    if macroObjective == 'bootstrap_factory' then
        raw.Land = 0.12
        raw.Air = 0
        raw.Navy = 0
        raw.Intel = 0.02
        raw.Defense = 0
        raw.Eco = 0.86
        raw.Tech = 0
    elseif macroObjective == 'starter_mex_claim' then
        raw.Land = 0.10
        raw.Air = 0
        raw.Navy = 0
        raw.Intel = math.min(raw.Intel, 0.06)
        raw.Defense = 0
        raw.Eco = math.max(raw.Eco, 0.82)
        raw.Tech = 0
    elseif macroObjective == 'land_factory_floor' then
        raw.Land = raw.Land + 0.12
        raw.Eco = raw.Eco + 0.14
        raw.Tech = raw.Tech - 0.08
        raw.Air = raw.Air - 0.18
        raw.Defense = raw.Defense - 0.12
        raw.Intel = raw.Intel - 0.03
    elseif macroObjective == 'mass_consolidation' then
        raw.Land = raw.Land + 0.04
        raw.Eco = raw.Eco + 0.08
        raw.Tech = raw.Tech + 0.06
        raw.Air = raw.Air - 0.08
        raw.Defense = raw.Defense - 0.06
    elseif macroObjective == 'first_land_hq' then
        raw.Land = raw.Land + 0.08
        raw.Eco = raw.Eco + 0.05
        raw.Tech = raw.Tech + 0.16
        raw.Air = raw.Air - (constraints.ConfirmedHarass and 0.05 or 0.14)
        raw.Defense = raw.Defense - (constraints.ConfirmedHarass and 0.03 or 0.10)
        raw.Intel = raw.Intel - 0.03
    elseif macroObjective == 'first_t2_engineer' or macroObjective == 'first_t2_power' then
        raw.Land = raw.Land + 0.06
        raw.Eco = raw.Eco + 0.04
        raw.Tech = raw.Tech + 0.14
        raw.Air = raw.Air - (constraints.ConfirmedHarass and 0.04 or 0.10)
        raw.Defense = raw.Defense - (constraints.ConfirmedHarass and 0.02 or 0.08)
    end
    if (runtime.MacroController or {}).HQPressureEscape == true then
        raw.Land = raw.Land + 0.18
        raw.Eco = raw.Eco + 0.04
        raw.Tech = raw.Tech - 0.18
        raw.Air = raw.Air - 0.18
        raw.Defense = raw.Defense - (constraints.ConfirmedHarass and 0.02 or 0.06)
    end
    if prioritizeProduction then
        raw.Land = raw.Land + 0.12 + (policy.ProductionTempoBias or 0)
        raw.Eco = raw.Eco - 0.06
        raw.Tech = raw.Tech - 0.12
        raw.Air = raw.Air - (constraints.CounterAirWindow and 0.02 or 0.10)
        raw.Defense = raw.Defense - (constraints.ConfirmedHarass and 0.01 or 0.04)
    end
    if contestMapMode then
        raw.Land = raw.Land + 0.08
        raw.Eco = raw.Eco - 0.04
        raw.Tech = raw.Tech - 0.08
        raw.Air = raw.Air - (constraints.CounterAirWindow and 0.01 or 0.08)
    end
    if preferTempoFromSurplus and constraints.SurplusSpendWindow then
        raw.Land = raw.Land + 0.10
        raw.Eco = raw.Eco - 0.04
        raw.Tech = raw.Tech - 0.08
    end
    if constraints.CounterAirWindow then
        raw.Air = raw.Air + 0.11
        raw.Land = raw.Land + 0.02
        raw.Defense = raw.Defense - 0.04
        raw.Eco = raw.Eco - 0.03
        raw.Tech = raw.Tech - 0.04
    end
    if constraints.EconBootstrap then
        raw.Land = raw.Land - 0.16
        raw.Air = raw.Air - 0.16
        raw.Defense = raw.Defense - 0.12
        raw.Eco = raw.Eco + 0.32
        raw.Tech = raw.Tech - 0.06
        raw.Intel = raw.Intel - 0.02
    end
    if constraints.StarterPhase and not constraints.ConfirmedHarass then
        raw.Land = 0.1
        raw.Air = 0
        raw.Navy = 0
        raw.Intel = constraints.StarterRadarRequired and 0.12 or 0.04
        raw.Defense = 0
        raw.Eco = constraints.StarterRadarRequired and 0.74 or 0.86
        raw.Tech = 0
    end

    return NormalizeBudget(raw)
end

local function SelectReason(primary, secondary, tertiary)
    local reasons = {}
    if primary and primary ~= '' then
        table.insert(reasons, primary)
    end
    if secondary and secondary ~= '' and secondary ~= primary then
        table.insert(reasons, secondary)
    end
    if tertiary and tertiary ~= '' and tertiary ~= primary and tertiary ~= secondary then
        table.insert(reasons, tertiary)
    end
    if table.getn(reasons) <= 0 then
        return 'baseline'
    end
    return table.concat(reasons, '+')
end

local function BuildRoleEntry(roleName, currentStrength, currentUnits, desiredUnits, priority, reason)
    local desiredCount = math.max(0, math.floor((desiredUnits or 0) + 0.5))
    local currentCount = math.max(0, currentUnits or 0)
    local currentValue = Round(currentStrength or 0, 2)
    local desiredStrength = OvermindRoleWeights.ComputeDesiredRoleStrength(roleName, desiredCount, currentValue, currentCount)
    local strengthDelta = Round(desiredStrength - currentValue, 2)
    local unitDelta = desiredCount - currentCount
    return {
        Current = currentValue,
        Desired = desiredStrength,
        CurrentStrength = currentValue,
        DesiredStrength = desiredStrength,
        CurrentUnits = currentCount,
        DesiredUnits = desiredCount,
        StrengthDelta = strengthDelta,
        StrengthGap = math.max(0, strengthDelta),
        UnitDelta = unitDelta,
        UnitGap = math.max(0, unitDelta),
        Priority = Clamp(priority or 0, 0.01, 0.99),
        Reason = reason or 'baseline',
    }
end

local function DecideRolePlan(runtime, current, constraints, demand, budget, confidence, mode, trends, now)
    local policy = runtime.EcoPolicy or {}
    local opp = runtime.OpponentModel or {}
    local mexReady = (((current.Eco or {}).Mex or {}).Ready) or 0
    local mexPeakReady = ((runtime.EngineerState or {}).PeakMexReady) or mexReady
    local mexLossCount = math.max(0, mexPeakReady - mexReady)
    local mexPressure = mexLossCount >= 1
    local severeMexDeficit = mexReady < math.max(5, (constraints.StarterMexFloor or 6) - 1)
    local powerReady = (((current.Eco or {}).Power or {}).Ready) or 0
    local prioritizeProduction = policy.PrioritizeProduction == true
    local contestMapMode = policy.ContestMapMode == true
    local outerRetentionActive = (runtime.StrategicPlanner or {}).OuterRetentionActive == true
    local reclaimFirst = (runtime.StrategicPlanner or {}).ReclaimFirst == true
    local outerControlStable = policy.FrontSecure == true and (policy.OuterHoldShare or 0) >= 0.55
    local contestUtilityAirWindow = (prioritizeProduction or contestMapMode)
        and current.Factories.Land.Ready >= 2
        and mexReady >= 4
        and powerReady >= 3
        and not constraints.EconBootstrap
        and not constraints.StarterPhase
        and not constraints.EcoCrash
        and not constraints.QueueStarved
        and not constraints.CriticalFactory
        and not constraints.CriticalStructure

    local landTotal = 8
        + (constraints.FrontPressure * 12)
        + (constraints.BasePressure * 7)
        + (constraints.EscortPressure * 5)
        + (constraints.ContestedZones * 2)
        + (budget.Land * 18)
        + ((mode == 'pressure') and 5 or 0)
        + ((mode == 'expand') and 2 or 0)
    if constraints.LandPanic then
        landTotal = landTotal + 5
    end
    if constraints.EconBootstrap and not constraints.LandPanic and not constraints.AirPanic then
        landTotal = Clamp(1 + (constraints.FrontPressure * 4) + (constraints.BasePressure * 3) + (constraints.EscortPressure * 2), 0, 8)
    end
    if constraints.StarterPhase and not constraints.LandPanic and not constraints.AirPanic and not constraints.ConfirmedHarass then
        landTotal = Clamp(1 + (constraints.FrontPressure * 3) + (constraints.BasePressure * 2) + (constraints.EscortPressure * 2), 0, 6)
    end
    if prioritizeProduction then
        landTotal = landTotal + 4 + math.floor((policy.ProductionTempoBias or 0) * 12)
    end
    if contestMapMode then
        landTotal = landTotal + 3
    end
    if outerRetentionActive then
        landTotal = landTotal + 3
    end
    if mexPressure and not constraints.EconBootstrap then
        landTotal = landTotal + math.min(8, 3 + (mexLossCount * 2))
    end
    landTotal = Clamp(landTotal, ((constraints.EconBootstrap or constraints.StarterPhase) and 0) or 6, 72)

    local scoutDesired = Clamp(1 + math.floor(demand.IntelNeed * 0.18) + ((constraints.RaidPressure > 0.16) and 1 or 0), 1, 5)
    if constraints.EconBootstrap and not constraints.LandPanic and not constraints.AirPanic then
        scoutDesired = 0
    end
    if constraints.StarterPhase and not constraints.ConfirmedHarass then
        scoutDesired = 0
    end
    if outerRetentionActive or reclaimFirst then
        scoutDesired = math.max(scoutDesired, current.Factories.Land.Ready >= 3 and 2 or 1)
    end
    local indirectCounterWindow = (constraints.EnemyIndirectHeavy or constraints.EnemyT2Push)
        and (constraints.FrontPressure >= 0.14 or constraints.BasePressure >= 0.14 or constraints.ApproachReal)
        and not constraints.EconBootstrap
    local landAAShare = 0.14 + math.min(0.16, (demand.AirRisk / 100)) + (constraints.AirPanic and 0.08 or 0)
        + ((constraints.BomberWatch or constraints.BomberPanic or constraints.ExposedMexAirRaid) and 0.08 or 0)
    if constraints.SevereBomberRaid then
        landAAShare = landAAShare + 0.05
    end
    local landIndirectShare = 0.08 + ((mode == 'pressure') and 0.06 or 0) + math.min(0.08, constraints.ContestedZones * 0.02)
    if indirectCounterWindow then
        landIndirectShare = landIndirectShare + 0.08 + math.min(0.06, constraints.FrontPressure * 0.18)
    end
    if constraints.LandPanic then
        landIndirectShare = landIndirectShare - 0.03
    end
    landAAShare = Clamp(landAAShare, 0.12, 0.34)
    landIndirectShare = Clamp(landIndirectShare, 0.05, 0.22)

    local landAADesired = Clamp(math.floor(landTotal * landAAShare), (constraints.AirPanic and 2 or 1), 22)
    local landIndirectDesired = Clamp(math.floor(landTotal * landIndirectShare), ((mode == 'pressure' or constraints.ContestedZones >= 2) and 2 or 0), 16)
    local landDirectDesired = Clamp(landTotal - landAADesired - landIndirectDesired - scoutDesired, 4, 42)
    if mexPressure then
        landDirectDesired = Clamp(landDirectDesired + math.min(6, 2 + mexLossCount), 4, 42)
        if constraints.BomberPanic or constraints.ExposedMexAirRaid then
            landAADesired = Clamp(landAADesired + 1, 1, 22)
        end
    end
    if constraints.BomberWatch then
        landAADesired = math.max(landAADesired, constraints.StarterPhase and 1 or 2)
    end
    if constraints.BomberPanic or constraints.ExposedMexAirRaid then
        landAADesired = math.max(landAADesired, constraints.StarterPhase and 2 or 4)
    end
    if constraints.SevereBomberRaid then
        local severeAAFloor = (constraints.StarterPhase and 3 or 5) + math.min(1, math.floor((constraints.BomberRaidSeverity or 0) / 4))
        landAADesired = math.max(landAADesired, severeAAFloor)
    end
    if indirectCounterWindow then
        local indirectFloor = Clamp(
            2
                + ((current.Factories.Land.Ready >= 2) and 1 or 0)
                + (((constraints.BasePressure >= 0.2) or (constraints.ApproachThreat >= 8)) and 1 or 0),
            2,
            6)
        landIndirectDesired = math.max(landIndirectDesired, indirectFloor)
    end
    if constraints.EnemyIndirectHeavy and not constraints.LandPanic then
        landIndirectDesired = math.max(landIndirectDesired, math.min(6, 2 + current.Factories.Land.Ready))
        landDirectDesired = math.max(4, landTotal - landAADesired - landIndirectDesired - scoutDesired)
    end
    if constraints.EconBootstrap and not constraints.LandPanic and not constraints.AirPanic then
        landAADesired = 0
        landIndirectDesired = 0
        landDirectDesired = Clamp(landTotal, 0, 8)
    end
    if constraints.StarterPhase and not constraints.ConfirmedHarass then
        landAADesired = 0
        landIndirectDesired = 0
        landDirectDesired = Clamp(landTotal, 0, 6)
    end
    local earlyLandScreenUnits = ((current.RoleUnits and current.RoleUnits.LandDirect) or 0)
        + ((current.RoleUnits and current.RoleUnits.LandAA) or 0)
        + ((current.RoleUnits and current.RoleUnits.LandIndirect) or 0)
    if current.Factories.Land.Ready >= 1
        and (now or 0) < 660
        and not constraints.EcoCrash then
        local earlyScreenFloor = ((now or 0) < 240) and 4 or (((now or 0) < 420) and 8 or 12)
        landDirectDesired = math.max(landDirectDesired, earlyScreenFloor)
        if (now or 0) >= 150 then
            scoutDesired = math.max(scoutDesired, 1)
        end
    end

    local airEnabled = (not constraints.EconBootstrap and (current.Factories.Air.Total > 0 or budget.Air >= 0.14 or constraints.AirPanic or constraints.VisionPanic))
        or constraints.AirPanic
        or ((((constraints.BomberWatch and not constraints.StarterPhase) or constraints.BomberPanic or constraints.ExposedMexAirRaid) and powerReady > 0 and current.Factories.Land.Ready >= 1) and true or false)
        or (constraints.CounterAirWindow and powerReady >= 2 and current.Factories.Land.Ready >= 2)
    if constraints.StarterPhase and not constraints.AirPanic and not constraints.ConfirmedHarass then
        airEnabled = false
    end
    if (prioritizeProduction or contestMapMode)
        and current.Factories.Land.Ready < 4
        and not contestUtilityAirWindow
        and not constraints.AirPanic
        and not constraints.BomberPanic
        and not constraints.ExposedMexAirRaid
        and not constraints.CounterAirWindow then
        airEnabled = false
    end
    if (constraints.BomberWatch or constraints.BomberPanic or constraints.ExposedMexAirRaid) and powerReady > 0 and current.Factories.Land.Ready >= 1 then
        airEnabled = true
    end
    local clusterStrikeWindow = airEnabled
        and constraints.EnemyLowAirThreat
        and (constraints.EnemyIndirectHeavy or constraints.EnemyT2Push)
        and (constraints.BasePressure >= 0.12 or constraints.FrontPressure >= 0.14 or constraints.ApproachThreat >= 5.5 or constraints.ApproachReal)
    local airTotal = 0
    if airEnabled then
        airTotal = 2 + math.floor((budget.Air * 22) + (constraints.AirGuardPressure * 7) + (demand.IntelNeed * 0.25))
        if constraints.AirPanic then
            airTotal = airTotal + 3
        end
        if constraints.BomberWatch then
            airTotal = airTotal + 1
        end
        if constraints.BomberPanic or constraints.ExposedMexAirRaid then
            airTotal = airTotal + 4
        end
        if constraints.SevereBomberRaid then
            airTotal = airTotal + 2 + math.min(3, math.floor(constraints.BomberRaidSeverity or 0))
        end
        if constraints.CounterAirWindow then
            airTotal = airTotal + 3 + (constraints.EnemyIndirectHeavy and 1 or 0)
        end
        if mode == 'pressure' and not constraints.AirPanic then
            airTotal = airTotal + 2
        end
    end
    airTotal = Clamp(airTotal, 0, 34)
    local airScoutDesired = airEnabled and Clamp(1 + math.floor(demand.IntelNeed * 0.15), 1, 4) or 0
    local bomberConfidence = Clamp((confidence.Global * 0.65) + (confidence.Air * 0.35) - (constraints.AirPanic and 0.3 or 0), 0, 1)
    local bomberDesired = 0
    if airEnabled then
        bomberDesired = math.floor((airTotal * (0.08 + (demand.RaidWindow * 0.18) + (demand.BomberOpportunity * 0.04))) * bomberConfidence)
        if constraints.VisionPanic then
            bomberDesired = math.min(bomberDesired, 1)
        end
        if constraints.AirPanic then
            bomberDesired = 0
        end
    end
    if constraints.BomberPanic or constraints.ExposedMexAirRaid then
        bomberDesired = 0
    end
    if (outerRetentionActive or reclaimFirst)
        and not outerControlStable
        and not constraints.CounterAirWindow
        and not constraints.BomberWatch
        and not constraints.BomberPanic
        and not constraints.ExposedMexAirRaid
        and not constraints.AirPanic then
        bomberDesired = 0
        airScoutDesired = Clamp(math.max(airScoutDesired, airEnabled and 1 or 0), airEnabled and 1 or 0, 2)
    end
    if contestUtilityAirWindow
        and current.Factories.Land.Ready < 4
        and current.Factories.Air.Total <= 1
        and not constraints.CounterAirWindow
        and not constraints.BomberWatch
        and not constraints.BomberPanic
        and not constraints.ExposedMexAirRaid then
        bomberDesired = 0
        airScoutDesired = Clamp(math.max(airScoutDesired, 1), 1, 2)
    end
    if constraints.CounterAirWindow and airEnabled and not constraints.AirPanic and not constraints.BomberPanic and not constraints.ExposedMexAirRaid then
        local counterBomberFloor = Clamp(2 + math.floor(((opp.T2Land or 0) + (opp.LandIndirect or 0)) * 0.08) + math.floor((demand.CounterStrike or 0) * 2), 2, 6)
        bomberDesired = math.max(bomberDesired, math.min(counterBomberFloor, math.max(2, math.floor(airTotal * 0.42))))
    end
    if airEnabled
        and current.Factories.Air.Total > 0
        and (constraints.CounterAirWindow or indirectCounterWindow)
        and not constraints.AirPanic
        and not constraints.BomberPanic
        and not constraints.ExposedMexAirRaid then
        local counterBomberFloor = Clamp(
            2
                + current.Factories.Air.Ready
                + (((constraints.BasePressure >= 0.16) or (constraints.ApproachThreat >= 6)) and 1 or 0),
            2,
            7)
        bomberDesired = math.max(bomberDesired, math.min(counterBomberFloor, math.max(2, math.floor(math.max(airTotal, 4) * 0.48))))
    end
    if clusterStrikeWindow
        and current.Factories.Air.Ready >= 1
        and not constraints.AirPanic
        and not constraints.BomberPanic
        and not constraints.ExposedMexAirRaid then
        local strikeBomberFloor = Clamp(
            2
                + current.Factories.Air.Ready
                + (((constraints.BasePressure >= 0.16) or (constraints.ApproachThreat >= 6.5)) and 1 or 0),
            2,
            8)
        bomberDesired = math.max(bomberDesired, math.min(strikeBomberFloor, math.max(2, math.floor(math.max(airTotal, 4) * 0.55))))
    end
    if airEnabled
        and current.Factories.Air.Ready >= 1
        and constraints.EnemyLowAirThreat
        and (constraints.EnemyIndirectHeavy or constraints.EnemyT2Push)
        and (constraints.ApproachReal or constraints.BasePressure >= 0.12 or constraints.FrontPressure >= 0.18)
        and not constraints.AirPanic
        and not constraints.BomberPanic
        and not constraints.ExposedMexAirRaid then
        local earlyBomberFloor = Clamp(2 + math.min(2, current.Factories.Air.Ready - 1), 2, 4)
        bomberDesired = math.max(bomberDesired, earlyBomberFloor)
    end
    bomberDesired = Clamp(bomberDesired, 0, 8)
    local fighterDesired = airEnabled and Clamp(airTotal - airScoutDesired - bomberDesired, 1, 28) or 0
    if constraints.BomberWatch then
        fighterDesired = math.max(fighterDesired, current.Factories.Air.Total > 0 and 2 or 0)
    end
    if constraints.BomberPanic or constraints.ExposedMexAirRaid then
        fighterDesired = math.max(fighterDesired, constraints.StarterPhase and 3 or 5)
    end
    if constraints.SevereBomberRaid then
        local severeFighterFloor = (constraints.StarterPhase and 4 or 7) + math.min(2, math.floor((constraints.BomberRaidSeverity or 0) / 3))
        fighterDesired = math.max(fighterDesired, severeFighterFloor)
    end
    if constraints.CounterAirWindow and airEnabled and not constraints.AirPanic then
        fighterDesired = math.max(fighterDesired, math.min(6, math.max(2, bomberDesired)))
    end
    if clusterStrikeWindow and bomberDesired > 0 and airEnabled then
        fighterDesired = math.max(fighterDesired, math.min(5, math.max(2, bomberDesired - 1)))
    end
    if bomberDesired > 0 and airEnabled then
        fighterDesired = math.max(fighterDesired, math.min(6, math.max(2, bomberDesired - 1)))
    end
    if contestUtilityAirWindow
        and current.Factories.Land.Ready < 4
        and current.Factories.Air.Total <= 1
        and not constraints.CounterAirWindow
        and not constraints.BomberWatch
        and not constraints.BomberPanic
        and not constraints.ExposedMexAirRaid then
        fighterDesired = Clamp(math.max(fighterDesired, 1), 1, 3)
    end
    if (outerRetentionActive or reclaimFirst)
        and not outerControlStable
        and not constraints.CounterAirWindow
        and not constraints.BomberWatch
        and not constraints.BomberPanic
        and not constraints.ExposedMexAirRaid
        and not constraints.AirPanic then
        fighterDesired = Clamp(math.max(fighterDesired, airEnabled and 1 or 0), airEnabled and 1 or 0, 2)
    end

    local seaEnabled = constraints.NavalActive and not constraints.NavyLowValue
    local seaTotal = seaEnabled and Clamp(2 + math.floor((budget.Navy * 18) + (demand.NavyRisk * 0.06)), 2, 20) or 0
    local seaAADesired = seaEnabled and Clamp(math.floor(seaTotal * (0.18 + ((opp.Air or 0) > 0 and 0.06 or 0))), 0, 8) or 0
    local seaSubDesired = seaEnabled and Clamp(math.floor(seaTotal * 0.28), 0, 8) or 0
    local seaSurfaceDesired = seaEnabled and Clamp(seaTotal - seaAADesired - seaSubDesired, 1, 16) or 0

    local engineerDesired = math.max(
        constraints.EngineerFloor,
        3 + math.floor(current.Factories.Ready * ((policy.EngineerFactoryRatio or 1) + 0.15)) + math.floor(demand.ExpansionPressure * 0.15))
    if constraints.EcoWeak then
        engineerDesired = engineerDesired + 1
    end
    if current.Factories.Land.Ready <= 1 then
        engineerDesired = math.max(engineerDesired, 7)
    end
    if constraints.EconBootstrap then
        engineerDesired = math.max(engineerDesired, 8)
    end
    if constraints.StarterPhase then
        engineerDesired = math.max(engineerDesired, constraints.StarterEngineerFloor or 6)
    end
    if constraints.CriticalFactory then
        engineerDesired = engineerDesired + math.max(1, constraints.CriticalFactoryRequired - constraints.CriticalFactoryAssigned)
    end
    if constraints.CriticalStructure then
        engineerDesired = engineerDesired + math.max(1, constraints.CriticalStructureRequired - constraints.CriticalStructureAssigned)
    end
    if constraints.BomberWatch then
        engineerDesired = engineerDesired + 1
    end
    if constraints.BomberPanic or constraints.ExposedMexAirRaid then
        engineerDesired = engineerDesired + 2
    end
    if constraints.SevereBomberRaid then
        engineerDesired = engineerDesired + 1
    end
    if severeMexDeficit then
        engineerDesired = engineerDesired + math.min(4, math.max(1, 6 - mexReady))
    end
    if mexPressure then
        engineerDesired = engineerDesired + math.min(3, mexLossCount + 1)
    end
    if outerRetentionActive then
        engineerDesired = engineerDesired + 1
    end
    if reclaimFirst then
        engineerDesired = engineerDesired + 1
    end
    local reclaimQuota = policy.EngineerReclaimQuota or 0
    local reclaimConversionDebt = (now or 0) >= 360
        and (reclaimQuota > 0
            or ((policy.ReclaimStagnationTime or 0) >= 60
            and (policy.ReclaimRateShort or 0) <= 0.2
            and (((runtime.StrategicPlanner or {}).ReclaimFieldScore or 0) >= 100)))
    local lowMexOwnership = (now or 0) >= 420
        and (now or 0) < 1500
        and mexReady < 10
        and current.Factories.Land.Ready >= 2
        and not constraints.EcoCrash
    if lowMexOwnership or reclaimConversionDebt then
        local expansionWorkerFloor = 8
            + math.floor((current.Factories.Ready or 0) * 1.45)
            + math.max(0, 10 - mexReady)
            + (reclaimQuota * 2)
        if mexReady < 7 then
            expansionWorkerFloor = expansionWorkerFloor + 2
        end
        if reclaimConversionDebt then
            expansionWorkerFloor = expansionWorkerFloor + 2
        end
        engineerDesired = math.max(engineerDesired, math.min(26, expansionWorkerFloor))
    end
    if current.Factories.Land.Ready >= 1
        and (now or 0) < 660
        and earlyLandScreenUnits < (((now or 0) < 240) and 4 or (((now or 0) < 420) and 8 or 12))
        and not lowMexOwnership
        and not reclaimConversionDebt
        and not constraints.CriticalFactory
        and not constraints.CriticalStructure
        and not constraints.EcoCrash then
        local engineerCap = ((now or 0) < 420) and 6 or 8
        engineerDesired = math.min(engineerDesired, math.max(engineerCap, current.RoleUnits.Engineer or 0))
    end
    engineerDesired = Clamp(engineerDesired, 3, 28)

    return {
        Engineer = BuildRoleEntry('Engineer', current.Roles.Engineer, current.RoleUnits.Engineer, engineerDesired, Clamp(0.42 + (demand.EcoRecovery * 0.08) + (constraints.CriticalFactory and 0.18 or 0) + (mexPressure and 0.14 or 0) + (severeMexDeficit and 0.1 or 0), 0.2, 0.98), SelectReason((mexPressure or severeMexDeficit) and 'mex_recovery' or ((constraints.BomberPanic or constraints.ExposedMexAirRaid) and 'engineer_preserve' or (constraints.BomberWatch and 'bomber_watch' or (constraints.CriticalFactory and 'critical_factory' or (constraints.EcoWeak and 'eco_recovery' or 'worker_floor')))), (demand.ExpansionPressure > 0) and 'expansion' or nil, (constraints.QueueStarved and 'queue_recovery' or nil))),
        LandDirect = BuildRoleEntry('LandDirect', current.Roles.LandDirect, current.RoleUnits.LandDirect, landDirectDesired, Clamp(0.48 + (constraints.FrontPressure * 0.22) + (constraints.LandPanic and 0.15 or 0), 0.2, 0.98), SelectReason((constraints.FrontPressure > 0.08) and 'front_hold' or 'screen', (constraints.BasePressure > 0.08) and 'base_guard' or nil, (constraints.EscortPressure > 0.08) and 'acu_escort' or nil)),
        LandAA = BuildRoleEntry('LandAA', current.Roles.LandAA, current.RoleUnits.LandAA, landAADesired, Clamp(0.36 + (demand.AirRisk * 0.0035) + (constraints.AirPanic and 0.2 or 0), 0.15, 0.98), SelectReason((constraints.BomberPanic or constraints.ExposedMexAirRaid) and 'bomber_resilience' or (constraints.BomberWatch and 'bomber_watch' or ((constraints.AirPanic or demand.AirRisk > 25) and 'enemy_air_risk' or 'air_guard')), (constraints.FrontPressure > 0.08) and 'front_hold' or nil, (constraints.EscortPressure > 0.08) and 'acu_escort' or nil)),
        LandIndirect = BuildRoleEntry('LandIndirect', current.Roles.LandIndirect, current.RoleUnits.LandIndirect, landIndirectDesired, Clamp(0.24 + (constraints.ContestedZones * 0.05) + ((mode == 'pressure') and 0.08 or 0), 0.08, 0.9), SelectReason((mode == 'pressure') and 'front_support' or 'contested_lane', (constraints.ContestedZones >= 2) and 'front_hold' or nil, nil)),
        LandScout = BuildRoleEntry('LandScout', current.Roles.LandScout, current.RoleUnits.LandScout, scoutDesired, Clamp(0.22 + (demand.IntelNeed * 0.03), 0.08, 0.86), SelectReason((constraints.StaleZones > 0) and 'scouting_debt' or 'screen', (constraints.RaidPressure > 0.1) and 'raid_lane' or nil, nil)),
        AirFighter = BuildRoleEntry('AirFighter', current.Roles.AirFighter, current.RoleUnits.AirFighter, fighterDesired, Clamp(0.3 + (constraints.AirGuardPressure * 0.24) + (constraints.AirPanic and 0.2 or 0) + (constraints.CounterAirWindow and 0.08 or 0), 0.1, 0.98), SelectReason((constraints.BomberPanic or constraints.ExposedMexAirRaid) and 'bomber_intercept' or (constraints.CounterAirWindow and 'strike_cover' or (constraints.BomberWatch and 'bomber_watch' or ((constraints.AirPanic or demand.AirRisk > 22) and 'enemy_air_risk' or 'air_guard'))), (constraints.VisionPanic and 'intel_cover' or nil), nil)),
        AirBomber = BuildRoleEntry('AirBomber', current.Roles.AirBomber, current.RoleUnits.AirBomber, bomberDesired, Clamp(0.12 + (demand.RaidWindow * 0.38 * bomberConfidence) + ((demand.CounterStrike or 0) * 0.28), 0.04, 0.9), SelectReason(((constraints.CounterAirWindow or clusterStrikeWindow) and bomberDesired > 0) and 't2_counter' or ((bomberDesired > 0) and 'raid_window' or 'suppressed'), (bomberConfidence < 0.55) and 'low_confidence' or nil, nil)),
        AirScout = BuildRoleEntry('AirScout', current.Roles.AirScout, current.RoleUnits.AirScout, airScoutDesired, Clamp(0.22 + (demand.IntelNeed * 0.04), 0.08, 0.9), SelectReason((constraints.VisionPanic or constraints.StaleZones > 0) and 'scouting_debt' or 'screen', (bomberDesired > 0) and 'strike_support' or nil, nil)),
        SeaSurface = BuildRoleEntry('SeaSurface', current.Roles.SeaSurface, current.RoleUnits.SeaSurface, seaSurfaceDesired, Clamp(0.18 + (demand.NavyRisk * 0.004), 0.05, 0.92), SelectReason(seaEnabled and 'naval_presence' or 'suppressed', (trends.Navy > 0) and 'enemy_navy_trend' or nil, nil)),
        SeaSub = BuildRoleEntry('SeaSub', current.Roles.SeaSub, current.RoleUnits.SeaSub, seaSubDesired, Clamp(0.14 + (demand.NavyRisk * 0.003), 0.04, 0.82), SelectReason(seaEnabled and 'naval_contest' or 'suppressed', nil, nil)),
        SeaAA = BuildRoleEntry('SeaAA', current.Roles.SeaAA, current.RoleUnits.SeaAA, seaAADesired, Clamp(0.12 + ((((opp.Air or 0) > 0) and 0.12 or 0)), 0.04, 0.78), SelectReason(seaEnabled and 'naval_air_cover' or 'suppressed', nil, nil)),
    }
end

local function DecideCapacityPlan(runtime, current, constraints, rolePlan)
    local state = runtime.ProductionDirector or {}
    local planner = runtime.StrategicPlanner or {}
    local policy = runtime.EcoPolicy or {}
    local eco = runtime.EcoState or {}
    local upgradeDirector = runtime.UpgradeDirector or {}
    local factoryUpgrade = upgradeDirector.Factory or {}
    local velocity = runtime.EcoVelocity or {}
    local ledgerAgg = ((runtime.EconomyLedger or {}).Aggregate) or {}
    local macroObjective = state.MacroObjective or 'land_factory_floor'
    local now = GetGameTimeSeconds()
    local totalUnfinished = current.Factories.Pending or 0
    local factoryTask = current.FactoryTask or {}
    local landRoleLoad = SumRoleField(rolePlan, { 'Engineer', 'LandDirect', 'LandAA', 'LandIndirect', 'LandScout' }, 'DesiredStrength')
    local airRoleLoad = SumRoleField(rolePlan, { 'AirFighter', 'AirBomber', 'AirScout' }, 'DesiredStrength')
    local seaRoleLoad = SumRoleField(rolePlan, { 'SeaSurface', 'SeaSub', 'SeaAA' }, 'DesiredStrength')
    local landRoleUnits = SumRoleField(rolePlan, { 'Engineer', 'LandDirect', 'LandAA', 'LandIndirect', 'LandScout' }, 'DesiredUnits')
    local airRoleUnits = SumRoleField(rolePlan, { 'AirFighter', 'AirBomber', 'AirScout' }, 'DesiredUnits')
    local seaRoleUnits = SumRoleField(rolePlan, { 'SeaSurface', 'SeaSub', 'SeaAA' }, 'DesiredUnits')
    local landRoleGap = SumRoleField(rolePlan, { 'Engineer', 'LandDirect', 'LandAA', 'LandIndirect', 'LandScout' }, 'StrengthGap')
    local airRoleGap = SumRoleField(rolePlan, { 'AirFighter', 'AirBomber', 'AirScout' }, 'StrengthGap')
    local seaRoleGap = SumRoleField(rolePlan, { 'SeaSurface', 'SeaSub', 'SeaAA' }, 'StrengthGap')
    local engineerUnits = (current.RoleUnits and current.RoleUnits.Engineer) or 0
    local engineerGap = (rolePlan.Engineer and rolePlan.Engineer.UnitGap) or 0
    local mexReady = (((current.Eco or {}).Mex or {}).Ready) or 0
    local powerReady = (((current.Eco or {}).Power or {}).Ready) or 0
    local radarReady = (current.Structures and current.Structures.Radar) or 0
    local totalFactories = (current.Factories and current.Factories.Total) or 0
    local readyFactories = (current.Factories and current.Factories.Ready) or 0
    local unfinishedFactoryCount = math.max(0, totalFactories - readyFactories)
    local massTrend = eco.MassTrend or 0
    local massStorageRatio = eco.MassStorageRatio or 0
    local factoryBusyRatio = policy.FactoryBusyRatio or ledgerAgg.FactoryBusyRatio or velocity.FactoryThroughput or 0
    local spendSaturation = policy.SpendSaturation or ledgerAgg.SpendSaturation or velocity.SpendSaturation or 0
    local reclaimRateShort = policy.ReclaimRateShort or velocity.ReclaimRateShort or 0
    local reclaimStagnation = policy.ReclaimStagnationTime or velocity.ReclaimStagnationTime or 0
    local powerBufferLow = constraints.PowerBufferLow == true
    local factoryTaskDebt = factoryTask.Active
        and ((factoryTask.AssignedBuilders or 0) < math.max(1, factoryTask.RequiredBuilders or 0))
    local factoryTaskStalled = factoryTask.Active
        and ((factoryTask.StallTime or 0) >= 8)
    local genericFactoryCompletionDebt = factoryTaskDebt or factoryTaskStalled
    local genericUnstaffedFactoryShell = factoryTask.Active
        and ((factoryTask.AssignedBuilders or 0) <= 0 or factoryTaskStalled)
    local landFactoryCompletionDebt = factoryTask.Active
        and factoryTask.Domain == 'Land'
        and ((factoryTask.AssignedBuilders or 0) < math.max(1, factoryTask.RequiredBuilders or 0))
    local landFactoryStalled = landFactoryCompletionDebt and (factoryTask.StallTime or 0) >= 8
    local staffedFactoryShell = factoryTask.Active
        and factoryTask.Domain == 'Land'
        and not landFactoryCompletionDebt
    local unstaffedFactoryShell = factoryTask.Active
        and factoryTask.Domain == 'Land'
        and ((factoryTask.AssignedBuilders or 0) <= 0 or landFactoryStalled)
    local emergencyAirFactory = (constraints.BomberPanic or constraints.ExposedMexAirRaid)
        and powerReady > 0
        and (current.Factories.Land.Ready >= 2
            or (current.Factories.Land.Total >= 2 and powerReady >= math.max(3, constraints.StarterPowerFloor or 2)))
        and engineerUnits >= 3
        and not constraints.EcoCrash
        and not constraints.CriticalFactory
    local landCoreOnline = current.Factories.Land.Ready >= 2
        or (current.Factories.Land.Total >= 2 and powerReady >= math.max(3, constraints.StarterPowerFloor or 2))
    local secondLandEcoReady = current.Factories.Land.Total <= 1
        and current.Factories.Land.Ready >= 1
        and current.Factories.Air.Total <= 0
        and powerReady >= math.max(3, constraints.StarterPowerFloor or 2)
        and mexReady >= math.max(4, (constraints.StarterMexFloor or 5) - 1)
        and engineerUnits >= math.max(5, (constraints.StarterEngineerFloor or 6) - 1)
        and not constraints.EcoWeak
        and not powerBufferLow
        and not constraints.EcoCrash
        and not constraints.CriticalFactory
        and not constraints.CriticalStructure
        and not constraints.UnitCapPressure
    local secondLandTempoReady = current.Factories.Land.Total <= 1
        and current.Factories.Land.Ready >= 1
        and current.Factories.Air.Total <= 0
        and now >= 120
        and powerReady >= math.max(2, (constraints.StarterPowerFloor or 2) - 1)
        and engineerUnits >= 4
        and not constraints.EcoCrash
        and not constraints.CriticalFactory
        and not constraints.UnitCapPressure
    local watchAirFactory = constraints.BomberWatch
        and powerReady >= 2
        and engineerUnits >= 4
        and landCoreOnline
        and current.Factories.Air.Total <= 0
        and not constraints.EcoCrash
        and not constraints.CriticalFactory
        and ((not constraints.StarterPhase) or radarReady > 0)
    local threatenedAirUnlock = (constraints.BomberWatch or constraints.BomberPanic or constraints.ExposedMexAirRaid)
        and current.Factories.Air.Total <= 0
        and landCoreOnline
        and powerReady >= 2
        and engineerUnits >= 4
        and not constraints.EcoCrash
        and not constraints.CriticalFactory
    local lowAirCounterWindow = constraints.EnemyLowAirThreat
        and (constraints.EnemyIndirectHeavy or constraints.EnemyT2Push)
        and (constraints.ApproachReal or constraints.BasePressure >= 0.12 or constraints.FrontPressure >= 0.18)
    local counterAirFactory = constraints.CounterAirWindow
        and current.Factories.Air.Total <= 0
        and current.Factories.Land.Ready >= 2
        and powerReady >= math.max(3, constraints.StarterPowerFloor or 2)
        and engineerUnits >= math.max(6, constraints.StarterEngineerFloor or 6)
        and not constraints.EcoWeak
        and not powerBufferLow
        and not constraints.EcoCrash
        and not constraints.CriticalFactory
        and not constraints.CriticalStructure
        and not constraints.UnitCapPressure
    local secondLandBootstrap = current.Factories.Land.Total <= 1
        and current.Factories.Land.Ready >= 1
        and current.Factories.Air.Total <= 0
        and (radarReady >= 1 or secondLandEcoReady or constraints.StarterRadarRequired ~= true)
        and powerReady >= math.max(2, constraints.StarterPowerFloor or 2)
        and mexReady >= math.max(4, (constraints.StarterMexFloor or 5) - 1)
        and engineerUnits >= math.max(5, (constraints.StarterEngineerFloor or 6) - 1)
        and not constraints.EcoWeak
        and not powerBufferLow
        and not constraints.EcoCrash
        and not constraints.CriticalFactory
        and not constraints.CriticalStructure
        and not constraints.UnitCapPressure

    if secondLandEcoReady or secondLandTempoReady or secondLandBootstrap or current.Factories.Land.Total >= 2 or current.Factories.Land.Ready >= 2 then
        state.SecondLandFloorLatched = true
    end
    local secondLandLatched = state.SecondLandFloorLatched == true
    local tempoRecoveryWindow = now >= 300
        and secondLandLatched
        and current.Factories.Land.Total >= 2
        and current.Factories.Land.Ready >= 2
        and mexReady >= math.max(7, constraints.StarterMexFloor or 5)
        and powerReady >= math.max(5, constraints.StarterPowerFloor or 2)
        and engineerUnits >= math.max(8, constraints.StarterEngineerFloor or 6)
        and not constraints.EcoWeak
        and not powerBufferLow
        and not constraints.EcoCrash
        and not constraints.CriticalFactory
        and not constraints.UnitCapPressure
    local sustainedTempoWindow = tempoRecoveryWindow
        and now >= 450
        and mexReady >= math.max(8, constraints.StarterMexFloor or 5)
        and powerReady >= math.max(7, constraints.StarterPowerFloor or 2)
        and engineerUnits >= math.max(10, constraints.StarterEngineerFloor or 6)
    local needsFirstLandHQ = factoryUpgrade.NeedsFirstLandHQ == true
    local earlyAirUnlockBias = policy.EarlyAirUnlockBias or 0
    local earlyAirRelax = math.max(0, earlyAirUnlockBias)
    local earlyAirConservatism = math.max(0, -earlyAirUnlockBias)
    local landCrisisAirVeto = planner.ForceAirAnswer == true
        and (
            constraints.LandPanic
            or constraints.FrontCollapse
            or (now < (runtime.ACUCrisisUntil or -999))
            or landRoleGap >= 12
        )
        and not constraints.AirPanic
        and not constraints.BomberPanic
        and not constraints.ExposedMexAirRaid
        and not constraints.CounterAirWindow
    local preserveAirWindow = emergencyAirFactory
        or threatenedAirUnlock
        or watchAirFactory
        or counterAirFactory
        or (planner.ForceAirAnswer and not landCrisisAirVeto)
        or constraints.AirPanic
        or constraints.BomberPanic
        or constraints.ExposedMexAirRaid
        or constraints.CounterAirWindow
    local severeAirRaidRecovery = constraints.SevereBomberRaid
        and (now >= 300 or (constraints.BomberRaidSeverity or 0) >= 3)
        and powerReady >= math.max(2, (constraints.StarterPowerFloor or 2) - 1)
        and landCoreOnline
        and not constraints.EcoCrash
        and not constraints.CriticalFactory
    local unfinishedFactoryHardCap = (constraints.SevereBomberRaid or constraints.BomberPanic or constraints.ExposedMexAirRaid) and 2 or 1
    if constraints.EcoWeak then
        unfinishedFactoryHardCap = 1
    end
    local tooManyUnfinishedFactoryShells = unfinishedFactoryCount >= unfinishedFactoryHardCap
    local chronicMassDeficit = totalFactories >= 4
        and massTrend <= -0.08
        and massStorageRatio <= 0.34
        and not constraints.EcoCrash
    local deepMassStall = (
            (massTrend <= -0.18 and massStorageRatio <= 0.22)
            or (massTrend <= -0.3)
            or (massTrend <= -0.1 and massStorageRatio <= 0.08)
        )
        and not constraints.EcoCrash
    local reclaimFundedTempo = spendSaturation >= 0.64
        and factoryBusyRatio >= 0.68
        and massTrend >= -0.16
        and (eco.EnergyTrend or 0) >= -10
        and (
            reclaimRateShort >= 0.18
            or (policy.EngineerReclaimQuota or 0) > 0
            or reclaimStagnation >= 45
        )
        and not deepMassStall
        and not constraints.EcoCrash
    local preHQAirClamp = false
    local objectivePreHQ = macroObjective == 'mass_consolidation'
        or macroObjective == 'first_land_hq'
        or macroObjective == 'first_t2_engineer'
        or macroObjective == 'first_t2_power'
    local objectiveStarterClamp = macroObjective == 'starter_mex_claim'
        or macroObjective == 'land_factory_floor'
    local prioritizeProduction = policy.PrioritizeProduction == true
    local contestMapMode = policy.ContestMapMode == true
    local focusOnT1Spam = policy.FocusOnT1Spam == true
    local relaxedFactoryTempo = policy.RelaxedFactoryTempo == true
    local suppressEarlyAir = policy.SuppressEarlyAir == true and earlyAirUnlockBias < 0.6
    local hqPressureEscape = (runtime.MacroController or {}).HQPressureEscape == true
    local outerRetentionActive = planner.OuterRetentionActive == true
    local reclaimFirst = planner.ReclaimFirst == true
    local frontSecure = policy.FrontSecure == true
    local outerControlStable = frontSecure and (policy.OuterHoldShare or 0) >= 0.55
    local outerMexShare = policy.OuterMexShare or 0
    local safeForwardMexCount = policy.SafeForwardMexCount or 0
    local contestScoutLandReadyMin = earlyAirRelax >= 0.75 and 1 or 2
    local contestScoutMexMin = Clamp(4 - math.floor(earlyAirRelax * 1.4) + math.floor(earlyAirConservatism * 1.2), 3, 6)
    local contestScoutPowerMin = Clamp(3 - math.floor(earlyAirRelax * 1.2) + math.floor(earlyAirConservatism), 2, 5)
    local contestScoutForwardMexMin = Clamp(3 - math.floor(earlyAirRelax), 1, 4)
    local contestScoutOuterMexMin = Clamp(0.34 - (earlyAirUnlockBias * 0.05), 0.22, 0.46)
    local contestScoutAirWindow = (contestMapMode or prioritizeProduction)
        and current.Factories.Land.Ready >= contestScoutLandReadyMin
        and mexReady >= contestScoutMexMin
        and powerReady >= contestScoutPowerMin
        and not constraints.EcoCrash
        and not constraints.QueueStarved
        and not constraints.CriticalFactory
        and not constraints.CriticalStructure
        and (frontSecure or safeForwardMexCount >= contestScoutForwardMexMin or outerMexShare >= contestScoutOuterMexMin)
    local contestScoutAirFloor = contestScoutAirWindow and 1 or 0
    local contestStarterTempo = (contestMapMode or prioritizeProduction)
        and current.Factories.Land.Ready >= 1
        and current.Factories.Air.Total <= 0
        and mexReady >= math.max(3, math.max(4, (constraints.StarterMexFloor or 5) - 1) - math.floor(earlyAirRelax))
        and powerReady >= math.max(2, math.max(2, (constraints.StarterPowerFloor or 2) - 1) - math.floor(earlyAirRelax))
        and engineerUnits >= math.max(3, math.max(4, (constraints.StarterEngineerFloor or 6) - 2) - math.floor(earlyAirRelax))
        and not constraints.EcoCrash
        and not constraints.CriticalFactory
        and not constraints.CriticalStructure
        and not constraints.UnitCapPressure
        and not powerBufferLow
        and (
            constraints.ContestedZones >= 2
            or constraints.ApproachReal
            or constraints.FrontPressure >= 0.14
            or constraints.BasePressure >= 0.12
        )
    if earlyAirUnlockBias >= 0.95 and (contestScoutAirWindow or contestStarterTempo) then
        preserveAirWindow = true
    end
    preHQAirClamp = needsFirstLandHQ
        and current.Factories.Land.Ready >= (earlyAirUnlockBias >= 0.75 and 5 or 4)
        and not preserveAirWindow

    local landCap = math.max(
        6,
        current.Factories.Land.Ready + 2,
        4 + math.max(0, math.floor(((eco.MassIncome or 0) - 6) / 3)),
        4 + math.max(0, math.floor(((mexReady or 0) - 8) / 2))
    )
    local airCap = math.max(
        4,
        current.Factories.Air.Ready + 1,
        2 + math.max(0, math.floor(((eco.EnergyIncome or 0) - 90) / 70))
    )
    local seaCap = math.max(
        3,
        current.Factories.Navy.Ready + 1,
        2 + math.max(0, math.floor(((eco.MassIncome or 0) - 10) / 4))
    )
    if constraints.SurplusSpendWindow then
        landCap = landCap + 2
        airCap = airCap + 1
        seaCap = seaCap + 1
    end
    if constraints.StrongSurplusWindow then
        landCap = landCap + 2
        airCap = airCap + 1
        seaCap = seaCap + 1
    end
    if preHQAirClamp then
        airCap = math.min(airCap, math.min(current.Factories.Air.Total, earlyAirUnlockBias >= 0.85 and 2 or 1))
    end

    local landTarget = Clamp(math.max(1, math.ceil(landRoleLoad / 9.5), math.ceil(landRoleUnits / 12)), 1, landCap)
    local airTarget = Clamp((((airRoleLoad > 0 or airRoleUnits > 0) and math.max(1, math.ceil(airRoleLoad / 8.5), math.ceil(airRoleUnits / 8))) or 0), 0, airCap)
    local seaTarget = Clamp((((seaRoleLoad > 0 or seaRoleUnits > 0) and math.max(1, math.ceil(seaRoleLoad / 10.5), math.ceil(seaRoleUnits / 8))) or 0), 0, seaCap)

    -- Keep the opener grounded: do not scale into a second factory before the first land
    -- factory has produced at least a minimal worker base.
    if current.Factories.Land.Ready <= 1 and engineerUnits <= 1 then
        airTarget = 0
    end
    if current.Factories.Land.Ready <= 1 and engineerGap >= 3 then
        landTarget = math.min(landTarget, 1)
        airTarget = 0
    end
    if secondLandTempoReady or secondLandBootstrap then
        landTarget = math.max(landTarget, 2)
        if not (watchAirFactory or threatenedAirUnlock or emergencyAirFactory or counterAirFactory) then
            airTarget = 0
        end
    end
    if secondLandLatched and not constraints.EcoCrash then
        landTarget = math.max(landTarget, 2)
        if not (watchAirFactory or threatenedAirUnlock or emergencyAirFactory or counterAirFactory) and current.Factories.Air.Total <= 0 and not contestScoutAirWindow then
            airTarget = 0
        end
    end
    if current.Factories.Air.Total <= 0
        and not landCoreOnline
        and not emergencyAirFactory
        and not threatenedAirUnlock
        and not counterAirFactory
        and not contestScoutAirWindow then
        airTarget = 0
    end

    if landRoleGap >= 6 and current.Factories.Land.Ready >= landTarget and not constraints.EcoWeak then
        landTarget = math.min(landCap, landTarget + 1)
    end
    if airRoleGap >= 4.5 and current.Factories.Air.Ready >= airTarget and not constraints.EcoWeak then
        airTarget = math.min(airCap, airTarget + 1)
    end
    if seaRoleGap >= 4.5 and current.Factories.Navy.Ready >= seaTarget and not constraints.EcoWeak then
        seaTarget = math.min(seaCap, seaTarget + 1)
    end

    local liveCombatWindow = not constraints.EcoCrash
        and (constraints.FrontPressure >= 0.16
            or constraints.BasePressure >= 0.14
            or constraints.CounterAirWindow
            or constraints.EnemyIndirectHeavy
            or constraints.EnemyT2Push
            or constraints.ApproachReal)
    local landEmergencyTempo = (contestMapMode or prioritizeProduction or planner.TradeTechForTempo or planner.PunishGreed)
        and landCoreOnline
        and not constraints.EcoCrash
        and not constraints.UnitCapPressure
        and not constraints.CriticalFactory
        and not constraints.CriticalStructure
        and (
            constraints.LandPanic
            or constraints.FrontCollapse
            or constraints.ApproachReal
            or constraints.FrontPressure >= 0.22
            or constraints.BasePressure >= 0.18
        )
        and (
            landRoleGap >= 10
            or landRoleLoad >= 26
            or current.Factories.Land.Ready <= 2
        )

    if constraints.EcoWeak or constraints.QueueStarved then
        landTarget = math.min(landTarget, math.max(1, current.Factories.Land.Ready + (current.Factories.Land.Total <= 0 and 1 or 0)))
        airTarget = math.min(airTarget, current.Factories.Air.Ready + ((constraints.AirPanic and current.Factories.Air.Total <= 0) and 1 or 0))
        seaTarget = math.min(seaTarget, current.Factories.Navy.Ready)
    end
    local structurePausesGrowth = constraints.CriticalStructure and (constraints.CriticalStructureAssigned or 0) > 0
    if structurePausesGrowth then
        landTarget = math.min(landTarget, math.max(1, current.Factories.Land.Ready + (current.Factories.Land.Total <= 0 and 1 or 0)))
        airTarget = math.min(airTarget, current.Factories.Air.Ready)
        seaTarget = math.min(seaTarget, current.Factories.Navy.Ready)
    end
    if constraints.EconBootstrap then
        landTarget = 1
        airTarget = 0
        seaTarget = 0
    end
    if constraints.StarterPhase then
        landTarget = 1
        if secondLandEcoReady or secondLandTempoReady or secondLandBootstrap or secondLandLatched or contestStarterTempo then
            landTarget = math.max(landTarget, 2)
        end
        if contestStarterTempo
            and secondLandLatched
            and (
                constraints.ApproachReal
                or constraints.FrontPressure >= 0.22
                or constraints.BasePressure >= 0.16
                or landRoleGap >= 10
            ) then
            landTarget = math.max(landTarget, 3)
        end
        airTarget = 0
        seaTarget = 0
    end
    if secondLandLatched and not constraints.StarterPhase and not constraints.EconBootstrap then
        landTarget = math.max(landTarget, 2)
    end
    if prioritizeProduction and secondLandLatched and not constraints.EcoCrash and not constraints.CriticalFactory and not constraints.CriticalStructure then
        landTarget = math.max(landTarget, 3)
    end
    if focusOnT1Spam and secondLandLatched and current.Factories.Land.Ready >= 2 and not constraints.EcoCrash and not constraints.CriticalFactory and not constraints.CriticalStructure then
        landTarget = math.max(landTarget, 3)
    end
    if (planner.TradeTechForTempo or planner.PunishGreed) and secondLandLatched and current.Factories.Land.Ready >= 2 then
        landTarget = math.max(landTarget, 3)
    end
    if planner.TradeMapForTech and not constraints.LandPanic and not constraints.AirPanic then
        airTarget = math.min(airTarget, math.max(1, current.Factories.Air.Total))
    end
    if planner.ForceAirAnswer and not landCrisisAirVeto and landCoreOnline and not constraints.EcoCrash and powerReady >= 2 then
        airTarget = math.max(airTarget, 1)
    end
    if tempoRecoveryWindow then
        landTarget = math.max(landTarget, 3)
    end
    if sustainedTempoWindow and current.Factories.Land.Total >= 3 then
        landTarget = math.max(landTarget, 4)
    end
    if liveCombatWindow and current.Factories.Land.Total >= 2 then
        landTarget = math.max(landTarget, 2)
    end
    if liveCombatWindow and current.Factories.Land.Ready >= 3 then
        landTarget = math.max(landTarget, 3)
    end
    if focusOnT1Spam
        and current.Factories.Land.Ready >= 3
        and not constraints.EcoCrash
        and not constraints.CriticalFactory
        and not constraints.CriticalStructure then
        landTarget = math.max(landTarget, 4)
    end
    if landEmergencyTempo then
        landTarget = math.max(landTarget, math.min(landCap, math.max(3, current.Factories.Land.Total + 1)))
        if current.Factories.Land.Ready >= 3 then
            landTarget = math.max(landTarget, math.min(landCap, 4))
        end
        if not preserveAirWindow then
            airTarget = math.min(airTarget, math.max(current.Factories.Air.Total, contestScoutAirFloor))
        end
    end
    if current.Factories.Land.Ready >= 4
        and current.Factories.Total >= 4
        and not constraints.EcoCrash
        and not constraints.QueueStarved
        and not constraints.CriticalFactory
        and not constraints.CriticalStructure then
        landTarget = math.max(landTarget, 4)
    end
    if contestMapMode
        and current.Factories.Land.Ready >= 3
        and not constraints.EcoCrash
        and not constraints.QueueStarved
        and not constraints.CriticalFactory
        and not constraints.CriticalStructure then
        landTarget = math.max(landTarget, 4)
    end
    if focusOnT1Spam
        and (eco.MassStored or 0) >= 250
        and current.Factories.Land.Ready >= 2
        and not constraints.EcoWeak
        and not constraints.EcoCrash
        and not constraints.QueueStarved
        and not constraints.CriticalFactory
        and not constraints.CriticalStructure then
        landTarget = math.max(landTarget, math.min(landCap, current.Factories.Land.Total + 1))
    end
    if focusOnT1Spam
        and (eco.MassStored or 0) >= 220
        and current.Factories.Land.Ready >= 4
        and (eco.MassTrend or 0) >= -0.15
        and not constraints.EcoCrash
        and not constraints.CriticalFactory
        and not constraints.CriticalStructure then
        landTarget = math.max(landTarget, math.min(landCap, 5))
    end
    if reclaimFundedTempo
        and secondLandLatched
        and current.Factories.Land.Ready >= 2
        and totalUnfinished <= 0
        and not constraints.CriticalFactory
        and not constraints.CriticalStructure
        and not powerBufferLow then
        landTarget = math.max(landTarget, math.min(landCap, current.Factories.Land.Total + 1))
    end
    if (secondLandEcoReady or secondLandTempoReady) and not emergencyAirFactory then
        landTarget = math.max(landTarget, 2)
    end
    if emergencyAirFactory then
        airTarget = math.max(airTarget, 1)
    end
    if watchAirFactory then
        airTarget = math.max(airTarget, 1)
    end
    if threatenedAirUnlock and not constraints.EcoWeak then
        airTarget = math.max(airTarget, 1)
    end
    if counterAirFactory then
        airTarget = math.max(airTarget, 1)
    end
    if severeAirRaidRecovery then
        airTarget = math.max(airTarget, 1)
        if current.Factories.Land.Ready >= 3
            and mexReady >= math.max(6, constraints.StarterMexFloor or 5)
            and not powerBufferLow then
            airTarget = math.max(airTarget, math.min(airCap, 2))
        end
    end
    if current.Factories.Air.Total > 0
        and current.Factories.Land.Ready < 4
        and not constraints.AirPanic
        and not emergencyAirFactory
        and not severeAirRaidRecovery
        and not constraints.BomberPanic
        and not constraints.ExposedMexAirRaid then
        airTarget = math.min(airTarget, 1)
    end
    if current.Factories.Land.Ready < 3
        and current.Factories.Air.Total <= 0
        and not contestScoutAirWindow
        and not emergencyAirFactory
        and not threatenedAirUnlock
        and not counterAirFactory then
        airTarget = 0
    end
    if current.Factories.Land.Ready < 4
        and not emergencyAirFactory
        and not severeAirRaidRecovery
        and not constraints.AirPanic
        and not constraints.BomberPanic
        and not constraints.ExposedMexAirRaid
        and not constraints.CounterAirWindow
        and not lowAirCounterWindow then
        airTarget = math.min(airTarget, math.min(1, current.Factories.Air.Total))
    end
    if suppressEarlyAir and not preserveAirWindow and not severeAirRaidRecovery then
        if current.Factories.Land.Ready < 4 and not contestScoutAirWindow then
            airTarget = 0
        else
            airTarget = math.min(airTarget, math.max(contestScoutAirFloor, math.min(current.Factories.Air.Total, 1)))
        end
    end

    if constraints.NavyLowValue then
        seaTarget = 0
    end

    local starterGrowthLock = constraints.StarterPhase
        and not contestStarterTempo
        and not secondLandTempoReady
        and not (secondLandLatched and current.Factories.Land.Total <= 1)
        and (
            current.Factories.Total <= 1
            or constraints.RadarCritical
            or constraints.CriticalFactory
            or (constraints.CriticalStructure and (
                constraints.CriticalStructureKind == 'Power'
                or constraints.CriticalStructureKind == 'Radar'
                or constraints.CriticalStructureKind == 'Mex'
            ))
        )
    local pauseGrowth = constraints.EcoCrash
        or constraints.QueueStarved
        or constraints.UnitCapPressure
        or constraints.CriticalFactory
        or structurePausesGrowth
        or chronicMassDeficit
        or tooManyUnfinishedFactoryShells
        or (genericFactoryCompletionDebt and not severeAirRaidRecovery)
    local ignoreSingleFactoryPause = landEmergencyTempo
        and totalUnfinished <= 1
        and not structurePausesGrowth
        and not landFactoryCompletionDebt
        and not unstaffedFactoryShell
    if constraints.EconBootstrap then
        pauseGrowth = true
    end
    if starterGrowthLock then
        pauseGrowth = true
    end
    if totalUnfinished >= 1 and not tempoRecoveryWindow and not staffedFactoryShell and not ignoreSingleFactoryPause then
        pauseGrowth = true
    end
    if totalUnfinished >= 2 then
        pauseGrowth = true
    end
    if landFactoryCompletionDebt and current.Factories.Land.Total >= 2 and not constraints.EcoCrash then
        pauseGrowth = false
    end
    if emergencyAirFactory and totalUnfinished <= 0 and not constraints.QueueStarved and not constraints.CriticalStructure then
        pauseGrowth = false
    end
    if threatenedAirUnlock and totalUnfinished <= 0 and not constraints.QueueStarved and not constraints.CriticalStructure then
        pauseGrowth = false
    end
    if tempoRecoveryWindow and totalUnfinished <= 0 and not constraints.CriticalStructure and not powerBufferLow then
        pauseGrowth = false
    end
    if relaxedFactoryTempo
        and secondLandLatched
        and totalUnfinished <= 0
        and not constraints.EcoCrash
        and not constraints.QueueStarved
        and not constraints.CriticalFactory
        and not constraints.CriticalStructure
        and not powerBufferLow
        and mexReady >= 5
        and powerReady >= 4 then
        pauseGrowth = false
    end
    if secondLandEcoReady
        and current.Factories.Land.Total <= 1
        and totalUnfinished <= 0
        and not constraints.EcoCrash
        and not constraints.QueueStarved
        and not constraints.CriticalFactory
        and not structurePausesGrowth then
        landTarget = math.max(landTarget, 2)
        pauseGrowth = false
    end
    if secondLandTempoReady
        and current.Factories.Land.Total <= 1
        and totalUnfinished <= 0
        and not constraints.EcoCrash
        and not constraints.CriticalFactory then
        landTarget = math.max(landTarget, 2)
        pauseGrowth = false
    end
    if contestStarterTempo
        and totalUnfinished <= 0
        and not constraints.QueueStarved
        and not structurePausesGrowth then
        pauseGrowth = false
    end
    if landEmergencyTempo
        and not constraints.QueueStarved
        and not structurePausesGrowth
        and not powerBufferLow then
        pauseGrowth = false
    end
    if genericFactoryCompletionDebt
        and not emergencyAirFactory
        and not threatenedAirUnlock
        and not counterAirFactory
        and not severeAirRaidRecovery then
        pauseGrowth = true
    end
    if deepMassStall then
        landTarget = math.min(landTarget, current.Factories.Land.Total)
        seaTarget = math.min(seaTarget, current.Factories.Navy.Total)
        if severeAirRaidRecovery then
            airTarget = math.min(airTarget, math.max(1, current.Factories.Air.Total))
        else
            airTarget = math.min(airTarget, current.Factories.Air.Total)
        end
        pauseGrowth = true
    end
    if chronicMassDeficit and not deepMassStall then
        landTarget = math.min(landTarget, current.Factories.Land.Total)
        seaTarget = math.min(seaTarget, current.Factories.Navy.Total)
        if severeAirRaidRecovery then
            airTarget = math.min(airTarget, math.max(1, current.Factories.Air.Total))
        else
            airTarget = math.min(airTarget, current.Factories.Air.Total)
        end
        pauseGrowth = true
    end
    if powerBufferLow and not emergencyAirFactory and not threatenedAirUnlock and not severeAirRaidRecovery then
        airTarget = math.min(airTarget, current.Factories.Air.Total)
        if current.Factories.Total >= 2 then
            pauseGrowth = true
        end
    end
    if liveCombatWindow and current.Factories.Air.Total > 0 and not powerBufferLow then
        airTarget = math.max(airTarget, 1)
    end
    if secondLandTempoReady
        and current.Factories.Land.Total <= 1
        and totalUnfinished <= 0
        and not constraints.EcoCrash
        and not constraints.CriticalFactory then
        landTarget = math.max(landTarget, 2)
        pauseGrowth = false
    end

    if not emergencyAirFactory and not threatenedAirUnlock and not counterAirFactory and current.Factories.Land.Ready < 2 then
        airTarget = 0
    end

    -- Prevent delayed overcorrection: only open one new factory at a time.
    local unfinishedAllowance = totalUnfinished
    if staffedFactoryShell and unfinishedAllowance > 0 then
        unfinishedAllowance = unfinishedAllowance - 1
    end
    local landUnfinishedAllowance = unfinishedAllowance
    if ignoreSingleFactoryPause and landUnfinishedAllowance > 0 then
        landUnfinishedAllowance = landUnfinishedAllowance - 1
    end
    if landTarget > current.Factories.Land.Total then
        landTarget = math.min(landTarget, current.Factories.Land.Total + math.max(0, 1 - landUnfinishedAllowance))
    end
    if airTarget > current.Factories.Air.Total then
        airTarget = math.min(airTarget, current.Factories.Air.Total + math.max(0, 1 - unfinishedAllowance))
    end
    if seaTarget > current.Factories.Navy.Total then
        seaTarget = math.min(seaTarget, current.Factories.Navy.Total + math.max(0, 1 - unfinishedAllowance))
    end

    if constraints.CriticalFactory then
        if constraints.CriticalFactoryDomain == 'Land' then
            landTarget = math.max(landTarget, current.Factories.Land.Total)
        elseif constraints.CriticalFactoryDomain == 'Air' then
            airTarget = math.max(airTarget, current.Factories.Air.Total)
        elseif constraints.CriticalFactoryDomain == 'Navy' then
            seaTarget = math.max(seaTarget, current.Factories.Navy.Total)
        end
    end
    if liveCombatWindow and current.Factories.Land.Ready >= 2 then
        landTarget = math.max(landTarget, math.min(2, current.Factories.Land.Ready))
    end
    if liveCombatWindow and current.Factories.Air.Ready >= 1 and current.Factories.Air.Total > 0 and not powerBufferLow then
        airTarget = math.max(airTarget, 1)
    end
    local completionLock = genericUnstaffedFactoryShell
        or tooManyUnfinishedFactoryShells
        or (factoryTaskDebt and (factoryTask.Domain ~= 'Land' or current.Factories.Land.Total >= 2))
        or (deepMassStall and genericFactoryCompletionDebt)
    if constraints.SurplusSpendWindow
        and current.Factories.Land.Ready >= 4
        and not constraints.CriticalFactory
        and not constraints.CriticalStructure
        and not completionLock then
        landTarget = math.max(landTarget, math.min(landCap, current.Factories.Land.Total + 1))
        if current.Factories.Land.Ready >= 6 and not powerBufferLow and not needsFirstLandHQ then
            airTarget = math.max(airTarget, math.min(airCap, current.Factories.Air.Total + 1))
        end
    end
    if preHQAirClamp then
        airTarget = math.min(airTarget, math.min(current.Factories.Air.Total, 1))
        if current.Factories.Land.Ready >= 3 and not preserveAirWindow then
            airTarget = math.min(airTarget, 1)
        end
    end
    if hqPressureEscape and not preserveAirWindow then
        airTarget = math.min(airTarget, math.min(current.Factories.Air.Total, 1))
        if current.Factories.Land.Ready >= 2 then
            local pressureFactoryCap = 4
            if (mexReady or 0) >= 8 and (now or 0) >= 900 then
                pressureFactoryCap = 5
            end
            if current.Factories.Land.Total < pressureFactoryCap then
                landTarget = math.max(landTarget, math.min(landCap, current.Factories.Land.Total + 1))
            else
                landTarget = math.min(landTarget, current.Factories.Land.Total)
            end
        end
    end
    if (outerRetentionActive or reclaimFirst)
        and not preserveAirWindow
        and not constraints.CounterAirWindow
        and not constraints.BomberWatch
        and not constraints.BomberPanic
        and not constraints.ExposedMexAirRaid
        and not constraints.AirPanic then
        if not outerControlStable or current.Factories.Land.Ready < 5 then
            airTarget = math.min(airTarget, math.max(contestScoutAirFloor, math.min(current.Factories.Air.Total, 1)))
        end
        local outerFactoryCap = ((mexReady or 0) < 8 and (now or 0) < 1200) and 4 or landCap
        if current.Factories.Land.Total < outerFactoryCap then
            landTarget = math.max(landTarget, math.min(landCap, math.max(current.Factories.Land.Total, current.Factories.Land.Ready + 1)))
        else
            landTarget = math.min(landTarget, current.Factories.Land.Total)
        end
    end
    if objectiveStarterClamp and not preserveAirWindow then
        airTarget = math.min(airTarget, contestScoutAirFloor)
    elseif objectivePreHQ and not preserveAirWindow then
        airTarget = math.min(airTarget, math.max(contestScoutAirFloor, math.min(current.Factories.Air.Total, 1)))
    end
    if prioritizeProduction and not preserveAirWindow then
        airTarget = math.min(airTarget, math.min(math.max(current.Factories.Air.Total, contestScoutAirFloor), (current.Factories.Land.Ready >= 4) and 1 or contestScoutAirFloor))
    end
    if contestScoutAirWindow and not preserveAirWindow then
        airTarget = math.max(airTarget, 1)
    end
    if focusOnT1Spam and not preserveAirWindow then
        if current.Factories.Land.Ready < 4 then
            airTarget = 0
        else
            airTarget = math.min(airTarget, math.max(contestScoutAirFloor, math.min(current.Factories.Air.Total, 1)))
        end
    end
    local lowMexAirConservation = (now or 0) < 1200
        and mexReady < 8
        and not emergencyAirFactory
        and not severeAirRaidRecovery
        and not constraints.AirPanic
        and not constraints.BomberPanic
        and not constraints.ExposedMexAirRaid
        and not constraints.CounterAirWindow
    if lowMexAirConservation then
        local lowMexAirTarget = (contestScoutAirWindow or watchAirFactory or threatenedAirUnlock) and 1 or 0
        if current.Factories.Air.Total > 0 then
            lowMexAirTarget = math.max(lowMexAirTarget, 1)
        end
        airTarget = math.min(airTarget, lowMexAirTarget)
    end
    if macroObjective == 'first_land_hq' and current.Factories.Land.Ready >= 4 and not completionLock then
        landTarget = math.min(landTarget, math.max(current.Factories.Land.Total, current.Factories.Land.Ready))
    end
    local macroFacts = ((runtime.MacroController or {}).Facts) or {}
    local preHQFactoryCap = ((macroFacts.T2LandFactories or 0) <= 0)
        and (mexReady or 0) < 8
        and (now or 0) < 1200
    if preHQFactoryCap and current.Factories.Land.Total >= 4 then
        landTarget = math.min(landTarget, current.Factories.Land.Total)
    elseif preHQFactoryCap then
        landTarget = math.min(landTarget, 4)
    end
    local ecoFactoryCap = math.max(
        4,
        2 + math.floor((mexReady or 0) * 0.72) + math.floor((eco.MassIncome or 0) * 0.22)
    )
    local phaseFactoryHardCap = 6
    if now >= 720 then
        phaseFactoryHardCap = 7
    end
    if now >= 1320 then
        phaseFactoryHardCap = 8
    end
    if now >= 2100 then
        phaseFactoryHardCap = 10
    end
    if now >= 3000 then
        phaseFactoryHardCap = 12
    end
    if severeAirRaidRecovery or constraints.CounterAirWindow then
        phaseFactoryHardCap = phaseFactoryHardCap + 1
    end
    if constraints.SurplusSpendWindow and now >= 1800 then
        phaseFactoryHardCap = phaseFactoryHardCap + 1
    end
    if reclaimFundedTempo and now >= 480 then
        phaseFactoryHardCap = phaseFactoryHardCap + 1
        ecoFactoryCap = ecoFactoryCap + 1
    end
    if constraints.StrongSurplusWindow and now >= 2400 then
        phaseFactoryHardCap = phaseFactoryHardCap + 1
    end
    if constraints.EcoWeak or chronicMassDeficit then
        phaseFactoryHardCap = phaseFactoryHardCap - 1
    end
    phaseFactoryHardCap = Clamp(phaseFactoryHardCap, 4, 13)
    if now < 1200 then
        ecoFactoryCap = math.min(ecoFactoryCap, 9)
    end
    if constraints.EcoWeak then
        ecoFactoryCap = math.max(4, ecoFactoryCap - 1)
    end
    if severeAirRaidRecovery then
        ecoFactoryCap = ecoFactoryCap + 1
    end
    if deepMassStall then
        ecoFactoryCap = math.min(ecoFactoryCap, math.max(4, totalFactories - 1))
    elseif chronicMassDeficit then
        ecoFactoryCap = math.min(ecoFactoryCap, math.max(4, totalFactories))
    end
    ecoFactoryCap = math.min(ecoFactoryCap, phaseFactoryHardCap)
    local desiredFactoryTotal = landTarget + airTarget + seaTarget
    if desiredFactoryTotal > ecoFactoryCap then
        local overflow = desiredFactoryTotal - ecoFactoryCap
        local minLand = liveCombatWindow and (constraints.EcoWeak and 1 or 2) or 1
        local minSea = (constraints.NavyLowValue and 0) or ((current.Factories.Navy.Total > 0) and 1 or 0)
        local minAir = 0
        if preserveAirWindow or severeAirRaidRecovery then
            minAir = (current.Factories.Air.Total > 0) and 1 or 0
            if severeAirRaidRecovery and current.Factories.Air.Total >= 2 and not powerBufferLow then
                minAir = 2
            end
        end

        local cutAirFirst = (now or 0) < 1500
            and (mexReady < 10 or liveCombatWindow or landRoleGap >= airRoleGap)
        local cut
        if cutAirFirst then
            cut = math.min(math.max(0, airTarget - minAir), overflow)
            airTarget = airTarget - cut
            overflow = overflow - cut

            if overflow > 0 then
                cut = math.min(math.max(0, seaTarget - minSea), overflow)
                seaTarget = seaTarget - cut
                overflow = overflow - cut
            end
            if overflow > 0 then
                cut = math.min(math.max(0, landTarget - minLand), overflow)
                landTarget = landTarget - cut
                overflow = overflow - cut
            end
        else
            cut = math.min(math.max(0, landTarget - minLand), overflow)
            landTarget = landTarget - cut
            overflow = overflow - cut

            if overflow > 0 then
                cut = math.min(math.max(0, seaTarget - minSea), overflow)
                seaTarget = seaTarget - cut
                overflow = overflow - cut
            end
            if overflow > 0 then
                cut = math.min(math.max(0, airTarget - minAir), overflow)
                airTarget = airTarget - cut
                overflow = overflow - cut
            end
        end
        if overflow > 0 then
            landTarget = math.max(1, landTarget - overflow)
        end
    end
    local landFactoryAllowed = (not pauseGrowth) and (not completionLock) and (current.Factories.Land.Total < landTarget)
    local nonLandFactoryAllowed = (not pauseGrowth) and (not completionLock or emergencyAirFactory or threatenedAirUnlock or counterAirFactory or severeAirRaidRecovery)

    return {
        AddLandFactory = landFactoryAllowed,
        AddAirFactory = nonLandFactoryAllowed and (current.Factories.Air.Total < airTarget),
        AddSeaFactory = nonLandFactoryAllowed and (current.Factories.Navy.Total < seaTarget),
        PauseFactoryGrowth = pauseGrowth,
        FactoryCompletionLock = completionLock and true or false,
        CriticalFactoryRecovery = constraints.CriticalFactory and true or false,
        CriticalFactoryDomain = constraints.CriticalFactoryDomain or 'none',
        CriticalFactoryAssigned = constraints.CriticalFactoryAssigned or 0,
        CriticalFactoryRequired = constraints.CriticalFactoryRequired or 0,
        LandTarget = landTarget,
        AirTarget = airTarget,
        SeaTarget = seaTarget,
        LandStrengthTarget = Round(landRoleLoad, 2),
        AirStrengthTarget = Round(airRoleLoad, 2),
        SeaStrengthTarget = Round(seaRoleLoad, 2),
        LandStrengthGap = Round(landRoleGap, 2),
        AirStrengthGap = Round(airRoleGap, 2),
        SeaStrengthGap = Round(seaRoleGap, 2),
        LandUnitTarget = landRoleUnits,
        AirUnitTarget = airRoleUnits,
        SeaUnitTarget = seaRoleUnits,
        DesiredTotal = landTarget + airTarget + seaTarget,
        QueueDiscipline = constraints.QueueStarved and 'tight' or ((constraints.EcoWeak or constraints.UnitCapPressure) and 'careful' or 'normal'),
        FactoryBusyRatio = Round(factoryBusyRatio, 2),
        SpendSaturation = Round(spendSaturation, 2),
        ReclaimRateShort = Round(reclaimRateShort, 2),
    }
end

local function DecideTechPlan(runtime, current, constraints, confidence, mode)
    local opp = runtime.OpponentModel or {}
    local eco = runtime.EcoState or {}
    local planner = runtime.StrategicPlanner or {}
    local policy = runtime.EcoPolicy or {}
    local prioritizeProduction = policy.PrioritizeProduction == true
    local contestMapMode = policy.ContestMapMode == true
    local focusOnT1Spam = policy.FocusOnT1Spam == true
    local preferTempoFromSurplus = policy.PreferTempoFromSurplus == true
    local readyLand = (((current.Factories or {}).Land or {}).Ready) or 0
    local frontCovered = constraints.FrontPressure <= 0.18 and constraints.BasePressure <= 0.14 and constraints.AirGuardPressure <= 0.16
    local scoutClean = constraints.StaleZones <= 2 and constraints.ScoutPressure <= 0.25 and confidence.Global >= 0.55
    local eligible = constraints.DurableSurplus and frontCovered and scoutClean and (not constraints.TechBlocked)

    local landBias = 0.2 + (((opp.RelativeLand or 1) < 0.95) and 0.12 or 0) + ((mode == 'pressure') and 0.08 or 0)
    local airBias = 0.12 + (((opp.RelativeAir or 1) < 0.92) and 0.14 or 0) + ((mode == 'air_control') and 0.1 or 0)
    local ecoBias = 0.16 + ((mode == 'tech_window') and 0.12 or 0) + (((runtime.ZoneModel and runtime.ZoneModel.MapControl) or 0) >= 0.45 and 0.08 or 0)

    local blockReason = 'none'
    if not constraints.DurableSurplus then
        blockReason = 'no_durable_surplus'
    elseif not frontCovered then
        blockReason = 'front_understrength'
    elseif not scoutClean then
        blockReason = 'scouting_debt'
    elseif constraints.UnitCapPressure then
        blockReason = 'unit_cap_pressure'
    elseif constraints.QueueStarved then
        blockReason = 'queue_starved'
    end

    if constraints.LandPanic or constraints.AirPanic then
        landBias = landBias + (constraints.LandPanic and 0.06 or 0)
        airBias = airBias + (constraints.AirPanic and 0.06 or 0)
        ecoBias = ecoBias - 0.08
    end
    if focusOnT1Spam then
        eligible = false
        landBias = landBias + 0.22
        ecoBias = ecoBias - 0.28
        airBias = airBias - 0.06
        if blockReason == 'none' then
            blockReason = 't1_spam'
        end
    end

    if planner.TradeMapForTech then
        eligible = eligible or (constraints.DurableSurplus and not constraints.VisionPanic and not constraints.QueueStarved)
        ecoBias = ecoBias + 0.18
        landBias = landBias - 0.04
        airBias = airBias - 0.02
    elseif planner.TradeTechForTempo or planner.PunishGreed then
        ecoBias = ecoBias - 0.14
        landBias = landBias + 0.08
    end
    if planner.ForceAirAnswer then
        ecoBias = ecoBias - 0.08
        airBias = airBias + 0.12
    end
    if constraints.SurplusSpendWindow then
        eligible = true
        ecoBias = ecoBias + 0.1
        landBias = landBias + 0.04
    end
    if prioritizeProduction then
        landBias = landBias + 0.16 + (policy.ProductionTempoBias or 0)
        ecoBias = ecoBias - 0.2
        airBias = airBias - 0.03
    end
    if contestMapMode then
        landBias = landBias + 0.08
        ecoBias = ecoBias - 0.08
    end
    if preferTempoFromSurplus and constraints.SurplusSpendWindow then
        landBias = landBias + 0.08
        ecoBias = ecoBias - 0.06
    end

    local overflowWindow = (eco.MassStorageRatio or 0) >= 0.78
        and (eco.MassTrend or 0) >= 0.12
        and (eco.EnergyStorageRatio or 0) >= 0.32
        and (eco.EnergyTrend or 0) >= 6
    local stableUpgradeEco = (eco.MassIncome or 0) >= 3.4
        and (eco.EnergyIncome or 0) >= 42
        and (eco.MassStorageRatio or 0) >= 0.18
        and (eco.EnergyStorageRatio or 0) >= 0.16
        and (eco.MassTrend or 0) >= -0.04
        and (eco.EnergyTrend or 0) >= 1
    local mexPeakReady = ((runtime.EngineerState or {}).PeakMexReady) or mexReady
    local mexLossCount = math.max(0, mexPeakReady - mexReady)
    local collapseRecoveryWindow = (constraints.MapControl or 1) <= 0.26
        or mexLossCount >= 2
        or mexReady <= math.max(5, (constraints.StarterMexFloor or 6) - 1)
    local extractorPriority = Clamp(
        (ecoBias * 0.82)
        + (eligible and 0.18 or 0)
        + (overflowWindow and 0.22 or 0)
        - (constraints.LandPanic and 0.14 or 0)
        - (constraints.AirPanic and 0.1 or 0)
        - (constraints.VisionPanic and 0.08 or 0)
        - (constraints.CriticalFactory and 0.18 or 0)
        - (constraints.QueueStarved and 0.14 or 0),
        0,
        1)

    local upgradeExtractors = false
    local aggressiveExtractors = false
    local extractorReason = 'macro_hold'
    if constraints.CriticalFactory then
        extractorReason = 'critical_factory'
    elseif constraints.EcoCrash then
        extractorReason = 'eco_crash'
    elseif constraints.QueueStarved and not overflowWindow then
        extractorReason = 'queue_starved'
    elseif collapseRecoveryWindow
        and readyLand >= 2
        and powerReady >= 3
        and (eco.EnergyStorageRatio or 0) >= 0.04
        and (eco.EnergyTrend or 0) >= -14
        and (eco.MassTrend or 0) >= -0.22
        and not constraints.TechBlocked then
        upgradeExtractors = true
        aggressiveExtractors = false
        extractorReason = 'collapse_recovery'
    elseif (prioritizeProduction or contestMapMode)
        and not overflowWindow
        and not constraints.StrongSurplusWindow
        and readyLand < 5 then
        upgradeExtractors = false
        aggressiveExtractors = false
        extractorReason = contestMapMode and 'contest_mode' or 'prioritize_production'
    elseif overflowWindow and (eco.EnergyStorageRatio or 0) >= 0.25 and (eco.EnergyTrend or 0) >= 0 then
        upgradeExtractors = true
        aggressiveExtractors = true
        extractorReason = 'overflow_window'
    elseif eligible and ecoBias >= 0.16 then
        upgradeExtractors = true
        aggressiveExtractors = ecoBias >= 0.28 and mode == 'tech_window'
        extractorReason = 'tech_window'
    elseif stableUpgradeEco and ecoBias >= 0.24 and not constraints.TechBlocked then
        upgradeExtractors = true
        aggressiveExtractors = extractorPriority >= 0.55 and confidence.Global >= 0.55
        extractorReason = 'eco_bias'
    elseif constraints.SurplusSpendWindow and not constraints.TechBlocked then
        upgradeExtractors = true
        aggressiveExtractors = constraints.StrongSurplusWindow == true and confidence.Global >= 0.52
        extractorReason = 'surplus_window'
    elseif stableUpgradeEco and confidence.Global >= 0.62 and (constraints.MapControl or 0) >= 0.48 and not constraints.LandPanic and not constraints.AirPanic then
        upgradeExtractors = true
        extractorReason = 'map_control'
    end

    if constraints.VisionPanic and not overflowWindow and extractorPriority < 0.68 then
        upgradeExtractors = false
        aggressiveExtractors = false
        extractorReason = 'scouting_debt'
    end
    if focusOnT1Spam and not overflowWindow and not constraints.StrongSurplusWindow then
        upgradeExtractors = false
        aggressiveExtractors = false
        extractorReason = 't1_spam'
    end
    if (planner.TradeTechForTempo or planner.PunishGreed) and not overflowWindow and not constraints.SurplusSpendWindow then
        upgradeExtractors = false
        aggressiveExtractors = false
        extractorReason = 'tempo_mode'
    elseif (planner.TradeTechForTempo or planner.PunishGreed) and constraints.SurplusSpendWindow and upgradeExtractors then
        extractorReason = 'tempo_surplus'
    end
    if preferTempoFromSurplus and upgradeExtractors and not overflowWindow and not constraints.StrongSurplusWindow then
        upgradeExtractors = false
        aggressiveExtractors = false
        extractorReason = 'surplus_to_tempo'
    end
    local extractorUpgradeCap = aggressiveExtractors and 4 or (upgradeExtractors and 2 or 0)
    if collapseRecoveryWindow and upgradeExtractors and not aggressiveExtractors then
        extractorUpgradeCap = math.min(extractorUpgradeCap, 1)
    end

    return {
        LandTechBias = Clamp(landBias, 0, 0.95),
        AirTechBias = Clamp(airBias, 0, 0.95),
        EcoTechBias = Clamp(ecoBias, 0, 0.95),
        EligibleForTech = eligible,
        BlockReason = blockReason,
        Primary = (landBias >= airBias and landBias >= ecoBias and 'land') or ((airBias >= ecoBias) and 'air' or 'eco'),
        TechWindowScore = Round(
            ((eco.MassIncome or 0) * 0.18)
            + ((eco.EnergyIncome or 0) * 0.01)
            + (confidence.Global * 4)
            - (constraints.FrontPressure * 2.8)
            - (constraints.AirGuardPressure * 1.9)
            - (constraints.ScoutPressure * 1.2),
            2),
        UpgradeExtractors = upgradeExtractors,
        AggressiveExtractorUpgrades = aggressiveExtractors,
        ExtractorUpgradePriority = Round(extractorPriority, 2),
        ExtractorUpgradeCap = extractorUpgradeCap,
        ExtractorUpgradeReason = extractorReason,
    }
end

local function DecideStructurePlan(runtime, current, constraints, confidence, mode, now)
    local opp = runtime.OpponentModel or {}
    local graph = runtime.ZoneGraph or {}
    local raid = runtime.RaidDefense or {}
    local clusterState = runtime.EnemyClusterTracker or {}
    local approachCluster = clusterState.ApproachCluster or {}
    local bigMap = TableCount(graph.Nodes or {}) >= 8
    local powerReady = (((current.Eco or {}).Power or {}).Ready) or 0
    local mexReady = (((current.Eco or {}).Mex or {}).Ready) or 0
    local severeBomberRaid = constraints.SevereBomberRaid == true
    local bomberSeverity = constraints.BomberRaidSeverity or 0
    local mexExpansionPressure = mexReady < math.max(8, (constraints.StarterMexFloor or 5) + 3)
    local macroPhase = ((runtime.MacroController or {}).Phase) or 'none'
    local firstT2PowerPending = macroPhase == 'first_t2_power'
    local acuCrisisActive = now < (runtime.ACUCrisisUntil or -999)
        or now < (runtime.ACUCrisisEscalatedUntil or -999)
    now = now or 0

    local radarDesired = 0
    if constraints.VisionPanic or (constraints.StaleZones > 0) or mode == 'expand' or current.Factories.Air.Total > 0 or current.RoleUnits.AirScout > 0 then
        radarDesired = 1
    end
    if (mode == 'pressure' or mode == 'air_control' or bigMap) and confidence.Global >= 0.48 and not constraints.EcoCrash then
        radarDesired = math.max(radarDesired, 2)
    end
    if constraints.AirPanic and radarDesired <= 0 then
        radarDesired = 1
    end
    if (constraints.BomberWatch or constraints.BomberPanic or constraints.ExposedMexAirRaid) and powerReady > 0 then
        radarDesired = math.max(radarDesired, 1)
    end
    if severeBomberRaid and powerReady > 0 then
        radarDesired = math.max(radarDesired, 2)
    end
    if (approachCluster.TotalThreat or 0) >= 6 and (approachCluster.HomeDistance or 999) < 260 and powerReady > 0 then
        radarDesired = math.max(radarDesired, 1)
    end
    if (approachCluster.TotalThreat or 0) >= 10 and (approachCluster.HomeDistance or 999) < 220 and confidence.Global >= 0.45 and powerReady > 0 then
        radarDesired = math.max(radarDesired, 2)
    end
    if (constraints.EconBootstrap or powerReady <= 0) and not constraints.AirPanic and not constraints.LandPanic then
        radarDesired = 0
    end
    if constraints.StarterPhase then
        radarDesired = (constraints.StarterRadarRequired and powerReady > 0) and 1 or 0
    end
    if mexExpansionPressure
        and not constraints.AirPanic
        and not constraints.BomberPanic
        and not constraints.ExposedMexAirRaid
        and not raid.UnderAirHarass
        and not raid.UnderLandHarass
        and not constraints.VisionPanic then
        radarDesired = math.min(radarDesired, 1)
    end
    radarDesired = Clamp(radarDesired, 0, 3)
    local radarCritical = radarDesired > (current.Structures.Radar or 0)
        and (current.Structures.Radar or 0) <= 0
        and powerReady > 0
        and not constraints.EconBootstrap

    local sonarDesired = (constraints.NavalActive and not constraints.NavyLowValue and ((opp.Navy or 0) > 0 or current.Factories.Navy.Total > 0)) and 1 or 0
    local baseAADesired = 0
    if constraints.OpenerThreatLock or constraints.EconBootstrap or constraints.StarterPhase or powerReady <= 0 or radarCritical then
        baseAADesired = 0
    elseif constraints.AirPanic or raid.UnderAirHarass then
        baseAADesired = 2 + math.min(2, constraints.AirThreatZones)
        if severeBomberRaid then
            baseAADesired = baseAADesired + 1 + math.min(1, math.floor(bomberSeverity / 4))
        end
    elseif constraints.AirThreatZones > 0 or (((opp.Air or 0) > 0) and confidence.Air >= 0.5 and now >= 300) then
        baseAADesired = 1
        if (mode == 'air_control' or now >= 600) and ((opp.Air or 0) >= 3 or constraints.AirThreatZones >= 2) then
            baseAADesired = 2
        end
    end
    if severeBomberRaid and powerReady > 0 and not constraints.StarterPhase and not constraints.EconBootstrap then
        baseAADesired = math.max(baseAADesired, 3)
    end

    local pdDesired = 0
    if constraints.OpenerThreatLock or constraints.EconBootstrap or constraints.StarterPhase or powerReady <= 0 or radarCritical then
        pdDesired = 0
    elseif constraints.LandPanic or raid.UnderLandHarass then
        pdDesired = 2 + (((constraints.ContestedZones >= 2) and 1) or 0)
    elseif now >= 300 and constraints.ContestedZones >= 2 and constraints.BasePressure >= 0.2 then
        pdDesired = 1
    end

    baseAADesired = Clamp(baseAADesired, 0, 5)
    pdDesired = Clamp(pdDesired, 0, 4)
    local exposedMexAADesired = 0
    if powerReady > 0 and (constraints.BomberPanic or constraints.ExposedMexAirRaid or raid.UnderAirHarass) then
        exposedMexAADesired = math.max(1, ((raid.LastBomberEnemyCount or 0) >= 2 or constraints.ExposedMexAirRaid) and 2 or 1)
        if severeBomberRaid then
            exposedMexAADesired = math.max(exposedMexAADesired, 2 + math.min(1, math.floor(bomberSeverity / 4)))
        end
    end
    local navalDefenseDesired = (sonarDesired > 0 and (opp.Navy or 0) > 0 and confidence.Navy >= 0.45) and 1 or 0
    local approachThreat = approachCluster.TotalThreat or 0
    local approachDistance = approachCluster.HomeDistance or 999
    local homeCrisisLockdown = acuCrisisActive
        or constraints.LandPanic
        or constraints.AirPanic
        or severeBomberRaid
        or raid.UnderLandHarass
        or raid.UnderAirHarass
        or (approachThreat >= 8 and approachDistance < 220)
    local shieldDesired = 0
    local tmdDesired = 0
    local shieldTechWindow = powerReady >= 4
        and not constraints.EconBootstrap
        and not constraints.StarterPhase
        and not firstT2PowerPending
        and not constraints.EcoCrash

    if shieldTechWindow and current.Factories.Land.Total > 0 then
        if homeCrisisLockdown then
            shieldDesired = 1
        elseif now >= 620
            and confidence.Global >= 0.46
            and current.Factories.Land.Total >= 2
            and (constraints.EnemyT2Push or constraints.EnemyIndirectHeavy or current.Factories.Air.Total > 0) then
            shieldDesired = 1
        end
    end
    if shieldDesired > 0
        and powerReady >= 5
        and confidence.Global >= 0.42
        and (
            homeCrisisLockdown
            or constraints.EnemyIndirectHeavy
            or constraints.EnemyT2Push
            or current.Factories.Land.Total >= 3
            or now >= 840
        ) then
        tmdDesired = 1
    end

    if constraints.EcoWeak and not constraints.AirPanic and not severeBomberRaid then
        baseAADesired = math.min(baseAADesired, 2)
        pdDesired = math.min(pdDesired, 2)
        exposedMexAADesired = math.min(exposedMexAADesired, 1)
        if not homeCrisisLockdown then
            shieldDesired = 0
            tmdDesired = 0
        end
    end
    if mexExpansionPressure
        and not constraints.LandPanic
        and not constraints.AirPanic
        and not raid.UnderLandHarass
        and not raid.UnderAirHarass then
        baseAADesired = math.min(baseAADesired, 1)
        pdDesired = math.min(pdDesired, 1)
        if not homeCrisisLockdown then
            shieldDesired = 0
            tmdDesired = 0
        end
    end
    if firstT2PowerPending then
        radarDesired = math.min(radarDesired, 1)
        baseAADesired = math.min(baseAADesired, (constraints.AirPanic or constraints.BomberPanic or raid.UnderAirHarass) and 1 or 0)
        pdDesired = math.min(pdDesired, (constraints.LandPanic or raid.UnderLandHarass) and 1 or 0)
        exposedMexAADesired = math.min(exposedMexAADesired, 1)
        shieldDesired = homeCrisisLockdown and 1 or 0
        tmdDesired = 0
    end

    return {
        Radar = radarDesired,
        RadarCritical = radarCritical and true or false,
        Sonar = sonarDesired,
        BaseAA = baseAADesired,
        PD = pdDesired,
        Shield = shieldDesired,
        TMD = tmdDesired,
        HomeCrisisLockdown = homeCrisisLockdown and true or false,
        ExposedMexAA = exposedMexAADesired,
        NavalDefense = navalDefenseDesired,
    }
end

local function GetMacroObjectiveState(runtime, fallback)
    local macro = runtime and runtime.MacroController or false
    if type(macro) == 'table' and macro.Phase then
        return {
            Name = macro.Phase,
            Reason = macro.Reason or 'macro_controller',
        }
    end
    return fallback
end

local function DecideMacroObjective(aiBrain, runtime, current, constraints, techPlan, mode, now)
    local eco = runtime.EcoState or {}
    local factories = current.Factories or {}
    local landFactories = factories.Land or {}
    local readyLand = landFactories.Ready or 0
    local totalLand = landFactories.Total or 0
    local powerReady = (((current.Eco or {}).Power or {}).Ready) or 0
    local mexReady = (((current.Eco or {}).Mex or {}).Ready) or 0
    local t2LandFactories = CountCategory(aiBrain, TechLandFactoryCategory)
    local techEngineers = CountCategory(aiBrain, TechEngineerCategory)
    local techPower = CountCategory(aiBrain, TechPowerCategory)
    local factoryTask = current.FactoryTask or {}
    local landFactoryDebt = factoryTask.Active
        and factoryTask.Domain == 'Land'
        and ((factoryTask.AssignedBuilders or 0) < math.max(1, factoryTask.RequiredBuilders or 0)
            or (factoryTask.ReadyFactories or 0) < 2
            or (factoryTask.StallTime or 0) >= 8)
    local earlyMassBudget = (eco.MassIncome or 0)
        + math.max(0, (eco.MassTrend or 0) * 8)
        + math.max(0, ((eco.MassStorageRatio or 0) - 0.06) * 10)
    local starterMexTarget = math.max(6, (constraints.StarterMexFloor or 5) + 1)
    local starterMexNeed = readyLand >= 1
        and powerReady >= 1
        and mexReady < starterMexTarget
        and now < 600
        and not constraints.CriticalFactory
        and not constraints.CriticalStructure

    if starterMexNeed then
        return {
            Name = 'starter_mex_claim',
            Reason = 'starter_mex_gap',
        }
    end

    if landFactoryDebt then
        return {
            Name = 'land_factory_floor',
            Reason = 'critical_land_factory',
        }
    end

    if t2LandFactories <= 0 then
        local canStartFirstHQ = readyLand >= 3
            and totalLand >= 3
            and mexReady >= 4
            and powerReady >= 3
            and not constraints.CriticalStructure
            and not constraints.EcoCrash

        if readyLand >= 4
            or totalLand >= 5
            or mode == 'tech_window'
            or constraints.SurplusSpendWindow
            or (canStartFirstHQ and earlyMassBudget >= 8.5 and not techPlan.UpgradeExtractors) then
            return {
                Name = 'first_land_hq',
                Reason = readyLand >= 4 and 'land_floor_online'
                    or constraints.SurplusSpendWindow and 'surplus_transition'
                    or 'mandatory_transition',
            }
        end

        if readyLand >= 2
            and mexReady >= 4
            and powerReady >= 3
            and not constraints.EcoCrash
            and not constraints.LandPanic
            and not constraints.AirPanic
            and (techPlan.UpgradeExtractors or earlyMassBudget >= 7.5 or constraints.SurplusSpendWindow) then
            return {
                Name = 'mass_consolidation',
                Reason = techPlan.UpgradeExtractors and (techPlan.ExtractorUpgradeReason or 'upgrade_window')
                    or earlyMassBudget >= 7.5 and 'budget_window'
                    or 'surplus_window',
            }
        end

        return {
            Name = 'land_factory_floor',
            Reason = 'pre_hq_floor',
        }
    end

    if techEngineers <= 0 then
        return {
            Name = 'first_t2_engineer',
            Reason = 'missing_t2_engineer',
        }
    end

    if techPower <= 0 then
        return {
            Name = 'first_t2_power',
            Reason = 'missing_t2_power',
        }
    end

    return {
        Name = 'surplus_scale',
        Reason = 'post_t2_scale',
    }
end

function Module.Update(aiBrain, now)
    local runtime = aiBrain.OvermindRuntime
    if not runtime then
        return
    end

    if now - (runtime.LastProductionDirectorUpdateTime or -999) < 3 then
        return
    end
    runtime.LastProductionDirectorUpdateTime = now

    local state = runtime.ProductionDirector or {
        Mode = 'stabilize',
        LastModeSwitch = -999,
        LastLogTime = -999,
        TimeHorizon = {
            Emergency = 30,
            Operational = 90,
            Strategic = 240,
        },
    }
    runtime.ProductionDirector = state

    local current = BuildCurrent(aiBrain, runtime)
    local navalActive = ((runtime.ZoneModel and runtime.ZoneModel.NavMarkerCount) or 0) >= 3
        or current.Factories.Navy.Total > 0
        or ((runtime.OpponentModel and runtime.OpponentModel.Navy) or 0) > 0

    local confidence, scoutingDebt = ComputeConfidence(runtime, current, navalActive)
    local trends = ComputeOpponentTrends(state, runtime.OpponentModel or {}, now)
    local constraints = BuildConstraints(runtime, current, confidence, scoutingDebt, navalActive, now)
    local scores = ScoreModes(now, runtime, current, constraints, trends, confidence)
    local mode, bestScore, previousMode, previousScore = PickMode(state, scores, now)
    local macroObjective = GetMacroObjectiveState(runtime, false)
    if not macroObjective then
        local provisionalTechPlan = DecideTechPlan(runtime, current, constraints, confidence, mode)
        macroObjective = DecideMacroObjective(aiBrain, runtime, current, constraints, provisionalTechPlan, mode, now)
    end
    local techPlan = DecideTechPlan(runtime, current, constraints, confidence, mode)
    local structurePlan = DecideStructurePlan(runtime, current, constraints, confidence, mode, now)
    local demand = BuildDemandLedger(runtime, current, constraints, trends, confidence, mode)
    local budget = DecideDomainBudget(runtime, mode, constraints, demand, confidence, macroObjective.Name)
    state.Time = now
    local rolePlan = DecideRolePlan(runtime, current, constraints, demand, budget, confidence, mode, trends, now)
    state.MacroObjective = macroObjective.Name
    state.MacroObjectiveReason = macroObjective.Reason
    local capacityPlan = DecideCapacityPlan(runtime, current, constraints, rolePlan)

    state.ModeScores = scores
    state.Mode = mode
    state.Current = current
    state.DomainBudget = budget
    state.RolePlan = rolePlan
    state.CapacityPlan = capacityPlan
    state.TechPlan = techPlan
    state.StructurePlan = structurePlan
    state.MacroTransitionLocked = ((runtime.MacroController or {}).TransitionLocked) == true
    state.EmergencyOverrides = {
        AirPanic = constraints.AirPanic,
        BomberWatch = constraints.BomberWatch,
        BomberPanic = constraints.BomberPanic,
        ExposedMexAirRaid = constraints.ExposedMexAirRaid,
        EnemyIndirectHeavy = constraints.EnemyIndirectHeavy,
        EnemyT2Push = constraints.EnemyT2Push,
        EnemyLowAirThreat = constraints.EnemyLowAirThreat,
        CounterAirWindow = constraints.CounterAirWindow,
        LandPanic = constraints.LandPanic,
        QueueStarved = constraints.QueueStarved,
        UnitCapPressure = constraints.UnitCapPressure,
        VisionPanic = constraints.VisionPanic,
        EcoCrash = constraints.EcoCrash,
        FrontCollapse = constraints.FrontCollapse,
    }
    state.Confidence = confidence
    state.ConstraintState = constraints
    state.DemandLedger = demand
    state.OpponentTrend = trends
    state.NavalActive = navalActive
    state.ScoutingDebt = scoutingDebt
    state.LastUpdate = now

    if mode ~= previousMode then
        LOG(string.format('*OVERMIND PRODDIR MODE A%d t=%.1f mode=%s score=%.2f prev=%s prevScore=%.2f',
            aiBrain:GetArmyIndex(),
            now,
            mode,
            bestScore,
            previousMode or 'none',
            previousScore or 0))
    end

    if now - (state.LastLogTime or -999) >= 34 then
        state.LastLogTime = now
        LOG(string.format('*OVERMIND PRODDIR A%d t=%.1f mode=%s obj=%s/%s conf=%.2f debt=%.2f fac=%d/%d/%d->%d/%d/%d bud=%.2f/%.2f/%.2f/%.2f/%.2f/%.2f/%.2f str=%.1f/%.1f/%.1f->%.1f/%.1f/%.1f gap=%.1f/%.1f/%.1f eng=%.1f/%.1f(%d/%d) eco=%d:%d/%d:%d/%d mex=%d:%d ft=%d:%s:%d/%d upg=%d:%s:%.2f struct=R%d S%d AA%d PD%d SH%d TMD%d home=%d tech=%d:%s emerg=%d%d%d',
            aiBrain:GetArmyIndex(),
            now,
            mode,
            macroObjective.Name or 'none',
            macroObjective.Reason or 'none',
            confidence.Global or 0,
            scoutingDebt or 0,
            current.Factories.Land.Total or 0,
            current.Factories.Air.Total or 0,
            current.Factories.Navy.Total or 0,
            capacityPlan.LandTarget or 0,
            capacityPlan.AirTarget or 0,
            capacityPlan.SeaTarget or 0,
            budget.Land or 0,
            budget.Air or 0,
            budget.Navy or 0,
            budget.Intel or 0,
            budget.Defense or 0,
            budget.Eco or 0,
            budget.Tech or 0,
            current.DomainStrength.Land or 0,
            current.DomainStrength.Air or 0,
            current.DomainStrength.Navy or 0,
            capacityPlan.LandStrengthTarget or 0,
            capacityPlan.AirStrengthTarget or 0,
            capacityPlan.SeaStrengthTarget or 0,
            capacityPlan.LandStrengthGap or 0,
            capacityPlan.AirStrengthGap or 0,
            capacityPlan.SeaStrengthGap or 0,
            (rolePlan.Engineer and rolePlan.Engineer.CurrentStrength) or 0,
            (rolePlan.Engineer and rolePlan.Engineer.DesiredStrength) or 0,
            (rolePlan.Engineer and rolePlan.Engineer.CurrentUnits) or 0,
            (rolePlan.Engineer and rolePlan.Engineer.DesiredUnits) or 0,
            constraints.EconBootstrap and 1 or 0,
            (((current.Eco or {}).Mex or {}).Ready) or 0,
            (((current.Eco or {}).Mex or {}).Total) or 0,
            (((current.Eco or {}).Power or {}).Ready) or 0,
            (((current.Eco or {}).Power or {}).Total) or 0,
            (((current.Eco or {}).Mex or {}).Ready) or 0,
            (((current.Eco or {}).Mex or {}).Total) or 0,
            current.FactoryTask.Active and 1 or 0,
            current.FactoryTask.Domain or 'none',
            current.FactoryTask.AssignedBuilders or 0,
            current.FactoryTask.RequiredBuilders or 0,
            techPlan.UpgradeExtractors and 1 or 0,
            techPlan.ExtractorUpgradeReason or 'none',
            techPlan.ExtractorUpgradePriority or 0,
            structurePlan.Radar or 0,
            structurePlan.Sonar or 0,
            structurePlan.BaseAA or 0,
            structurePlan.PD or 0,
            structurePlan.Shield or 0,
            structurePlan.TMD or 0,
            structurePlan.HomeCrisisLockdown and 1 or 0,
            techPlan.EligibleForTech and 1 or 0,
            techPlan.BlockReason or 'none',
            capacityPlan.PauseFactoryGrowth and 1 or 0,
            constraints.AirPanic and 1 or 0,
            constraints.LandPanic and 1 or 0))
    end
end

function Update(aiBrain, now)
    return Module.Update(aiBrain, now)
end

return Module
