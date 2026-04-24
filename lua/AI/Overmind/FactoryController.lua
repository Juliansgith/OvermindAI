local Module = {}
local OvermindRoleWeights = import('/mods/OvermindAI/lua/AI/Overmind/RoleWeights.lua')
local OvermindEconomyLedger = import('/mods/OvermindAI/lua/AI/Overmind/EconomyLedger.lua')

local LandDirectCategory = categories.MOBILE * categories.LAND * categories.DIRECTFIRE
    - categories.ENGINEER - categories.SCOUT - categories.ANTIAIR - categories.COMMAND
local LandAACategory = categories.MOBILE * categories.LAND * categories.ANTIAIR
    - categories.ENGINEER - categories.SCOUT - categories.COMMAND
local LandIndirectCategory = categories.MOBILE * categories.LAND * categories.INDIRECTFIRE
    - categories.ENGINEER - categories.SCOUT - categories.COMMAND
local LandScoutCategory = categories.MOBILE * categories.LAND * categories.SCOUT - categories.ENGINEER
local EngineerCategory = categories.ENGINEER * categories.MOBILE
local TechEngineerCategory = categories.ENGINEER * categories.MOBILE * (categories.TECH2 + categories.TECH3)

local AirFighterCategory = categories.MOBILE * categories.AIR * categories.ANTIAIR
    - categories.SCOUT - categories.TRANSPORTATION - categories.COMMAND
local AirBomberCategory = categories.MOBILE * categories.AIR * categories.BOMBER
    - categories.SCOUT - categories.TRANSPORTATION - categories.COMMAND
local AirScoutCategory = categories.MOBILE * categories.AIR * categories.SCOUT

local SeaSurfaceCategory = categories.MOBILE * categories.NAVAL
    - categories.SUBMERSIBLE - categories.ANTIAIR - categories.SCOUT - categories.ENGINEER - categories.COMMAND
local SeaSubCategory = categories.MOBILE * categories.NAVAL * categories.SUBMERSIBLE
local SeaAACategory = categories.MOBILE * categories.NAVAL * categories.ANTIAIR

local function Clamp(v, minV, maxV)
    if v < minV then
        return minV
    end
    if v > maxV then
        return maxV
    end
    return v
end

local function GetBlueprintCost(bpId)
    if not bpId or not __blueprints or not __blueprints[bpId] or not __blueprints[bpId].Economy then
        return 0, 0
    end
    local eco = __blueprints[bpId].Economy
    return eco.BuildCostMass or 0, eco.BuildCostEnergy or 0
end

local function GetBlueprint(bpId)
    if not bpId or not __blueprints then
        return false
    end
    return __blueprints[bpId] or false
end

local function BlueprintHasCategory(bp, categoryName)
    if not bp or not bp.Categories or not categoryName then
        return false
    end
    for _, name in bp.Categories do
        if name == categoryName then
            return true
        end
    end
    return false
end

local function GetBlueprintTechTier(bp)
    if BlueprintHasCategory(bp, 'TECH3') then
        return 3
    elseif BlueprintHasCategory(bp, 'TECH2') then
        return 2
    end
    return 1
end

local function PickBuildBlueprint(factory, category, roleName, preferCheap, techBias, needBias)
    if not factory or not category then
        return false
    end
    local options = EntityCategoryGetUnitList(category)
    if not options or table.getn(options) <= 0 then
        return false
    end

    local best = false
    local bestScore = -999999
    local bias = techBias or 0
    local gapBias = needBias or 0
    for _, bpId in options do
        if bpId and factory:CanBuild(bpId) then
            local bp = GetBlueprint(bpId)
            local mass, energy = GetBlueprintCost(bpId)
            local massEquivalent = mass + (energy * 0.012)
            local roleWeight = OvermindRoleWeights.GetBlueprintRoleWeight(roleName, bp)
            local buildTime = ((bp and bp.Economy and bp.Economy.BuildTime) or math.max(1, massEquivalent))
            local valuePerMass = roleWeight / math.max(1, massEquivalent)
            local valuePerTime = roleWeight / math.max(1, buildTime / 100)
            local tier = GetBlueprintTechTier(bp)
            local score = (valuePerTime * (42 + (bias * 18)))
                + (valuePerMass * (preferCheap and 78 or 34))
                + (roleWeight * (8 + (gapBias * 4)))
                + (tier * (preferCheap and 2 or (5 + (bias * 6))))
            if preferCheap then
                score = score - (massEquivalent * 0.018)
                score = score - (buildTime * 0.0008)
                score = score - (tier * math.max(0, 1.2 - (bias * 0.4)))
            else
                score = score + (massEquivalent * (0.004 + (bias * 0.0035)))
                score = score - (buildTime * 0.00045)
            end
            if score > bestScore then
                bestScore = score
                best = bpId
            end
        end
    end
    return best
end

local function ClassifyFactory(factory)
    if not factory then
        return 'other'
    end
    if EntityCategoryContains(categories.FACTORY * categories.LAND, factory) then
        return 'land'
    elseif EntityCategoryContains(categories.FACTORY * categories.AIR, factory) then
        return 'air'
    elseif EntityCategoryContains(categories.FACTORY * categories.NAVAL, factory) then
        return 'sea'
    end
    return 'other'
end

local function IsFactoryReady(factory)
    if not factory or factory.Dead then
        return false
    end
    if factory:IsUnitState('BeingBuilt') or factory:IsUnitState('Upgrading') or factory:IsPaused() then
        return false
    end
    if factory.GetFractionComplete and factory:GetFractionComplete() < 0.95 then
        return false
    end
    return true
end

local function IsNearUnitCap(aiBrain)
    local used = aiBrain:GetCurrentUnits(categories.ALLUNITS) or 0
    local cap = GetArmyUnitCap and (GetArmyUnitCap(aiBrain:GetArmyIndex()) or 1000) or 1000
    return cap > 0 and (used / cap) >= 0.985
end

local function GetDiscipline(runtime)
    local prod = (runtime and runtime.ProductionDirector) or {}
    local cap = prod.CapacityPlan or {}
    local emerg = prod.EmergencyOverrides or {}
    return cap.QueueDiscipline or (emerg.QueueStarved and 'tight' or 'normal')
end

local function DesiredQueueDepth(runtime, eco)
    local discipline = GetDiscipline(runtime)
    if discipline == 'tight' then
        return 1
    end
    if discipline == 'careful' then
        return 2
    end
    if (eco.MassStorageRatio or 0) >= 0.35 and (eco.EnergyStorageRatio or 0) >= 0.35 and (eco.MassTrend or 0) >= 0 and (eco.EnergyTrend or 0) >= 6 then
        return 4
    end
    return 3
end

local function GetEcon(runtime)
    local eco = (runtime and runtime.EcoState) or {}
    return {
        MassStorageRatio = eco.MassStorageRatio or 0,
        EnergyStorageRatio = eco.EnergyStorageRatio or 0,
        MassTrend = eco.MassTrend or 0,
        EnergyTrend = eco.EnergyTrend or 0,
        MassIncome = eco.MassIncome or 0,
        EnergyIncome = eco.EnergyIncome or 0,
    }
end
local function GetRoleCategory(roleName)
    if roleName == 'Engineer' then
        return EngineerCategory
    elseif roleName == 'LandDirect' then
        return LandDirectCategory
    elseif roleName == 'LandAA' then
        return LandAACategory
    elseif roleName == 'LandIndirect' then
        return LandIndirectCategory
    elseif roleName == 'LandScout' then
        return LandScoutCategory
    elseif roleName == 'AirFighter' then
        return AirFighterCategory
    elseif roleName == 'AirBomber' then
        return AirBomberCategory
    elseif roleName == 'AirScout' then
        return AirScoutCategory
    elseif roleName == 'SeaSurface' then
        return SeaSurfaceCategory
    elseif roleName == 'SeaSub' then
        return SeaSubCategory
    elseif roleName == 'SeaAA' then
        return SeaAACategory
    end
    return false
end

local function GetFactoryRoleNames(kind)
    if kind == 'land' then
        return { 'Engineer', 'LandDirect', 'LandAA', 'LandIndirect', 'LandScout' }
    elseif kind == 'air' then
        return { 'AirFighter', 'AirBomber', 'AirScout' }
    elseif kind == 'sea' then
        return { 'SeaSurface', 'SeaSub', 'SeaAA' }
    end
    return {}
end

local function FallbackRole(kind, plan, eco)
    local emerg = plan.EmergencyOverrides or {}
    local rolePlan = plan.RolePlan or {}
    local engineer = rolePlan.Engineer or {}
    if kind == 'land' then
        if (engineer.UnitGap or 0) >= 2 or (engineer.CurrentUnits or 0) <= 1 then
            return 'Engineer'
        end
        if emerg.EcoCrash or (eco.MassStorageRatio or 0) < 0.06 then
            return 'Engineer'
        end
        if emerg.BomberPanic or emerg.ExposedMexAirRaid or emerg.BomberWatch or emerg.AirPanic then
            return 'LandAA'
        end
        local indirect = rolePlan.LandIndirect or {}
        if (emerg.EnemyIndirectHeavy or emerg.EnemyT2Push) and ((indirect.UnitGap or 0) > 0 or (indirect.CurrentUnits or 0) < math.min(3, indirect.DesiredUnits or 0)) then
            return 'LandIndirect'
        end
        return 'LandDirect'
    elseif kind == 'air' then
        if emerg.VisionPanic then
            return 'AirScout'
        end
        local current = plan.Current or {}
        local currentFactories = current.Factories or {}
        local readyAirFactories = (((currentFactories.Air or {}).Ready) or 0)
        local bomberCounterWindow = emerg.CounterAirWindow or (emerg.EnemyLowAirThreat and (emerg.EnemyIndirectHeavy or emerg.EnemyT2Push))
        if bomberCounterWindow and not (emerg.AirPanic or emerg.BomberPanic or emerg.ExposedMexAirRaid) then
            local fighter = rolePlan.AirFighter or {}
            local bomber = rolePlan.AirBomber or {}
            if (emerg.EnemyIndirectHeavy or emerg.EnemyT2Push)
                and readyAirFactories >= 1
                and (fighter.CurrentUnits or 0) >= 1
                and ((bomber.UnitGap or 0) > 0 or (bomber.CurrentUnits or 0) < math.max(2, math.min(4, bomber.DesiredUnits or 0))) then
                return 'AirBomber'
            end
            if (fighter.UnitGap or 0) > 0 or (fighter.CurrentUnits or 0) < math.max(2, math.min(4, bomber.DesiredUnits or 0)) then
                return 'AirFighter'
            end
            return 'AirBomber'
        end
        return (emerg.BomberPanic or emerg.ExposedMexAirRaid or emerg.BomberWatch or emerg.AirPanic) and 'AirFighter' or 'AirScout'
    elseif kind == 'sea' then
        return emerg.AirPanic and 'SeaAA' or 'SeaSurface'
    end
    return false
end

local function CountLandScreenUnits(rolePlan)
    return (((rolePlan.LandDirect or {}).CurrentUnits) or 0)
        + (((rolePlan.LandAA or {}).CurrentUnits) or 0)
        + (((rolePlan.LandIndirect or {}).CurrentUnits) or 0)
end

local function GetOutstandingEngineerDemand(runtime, now)
    local demand = runtime and runtime.EngineerDemand or {}
    if not demand.LastUpdate or now - (demand.LastUpdate or -999) > 18 then
        return 0, demand
    end
    return math.max(0, (demand.TotalWanted or 0) - (demand.PendingFactoryOrders or 0)), demand
end

local function SelectEarlyLandScreenRole(kind, plan, rolePlan)
    if kind ~= 'land' then
        return false, 0
    end

    local current = plan.Current or {}
    local factories = current.Factories or {}
    local landFactories = factories.Land or {}
    if (landFactories.Ready or 0) <= 0 then
        return false, 0
    end

    local emerg = plan.EmergencyOverrides or {}
    local constraints = plan.ConstraintState or {}
    local engineer = rolePlan.Engineer or {}
    local engineerUnits = engineer.CurrentUnits or 0
    if engineerUnits <= 1 or emerg.EcoCrash then
        return false, 0
    end

    local now = plan.Time or GetGameTimeSeconds()
    local desiredEngineers = engineer.DesiredUnits or 0
    local engineerFloor = math.max(6, math.min(18, desiredEngineers))
    local landScreenUnits = CountLandScreenUnits(rolePlan)
    local scoutUnits = ((rolePlan.LandScout or {}).CurrentUnits) or 0
    local landAA = rolePlan.LandAA or {}
    local severeLandCrisis = emerg.LandPanic
        or emerg.FrontCollapse
        or ((constraints.BasePressure or 0) >= 0.35)
        or ((constraints.FrontPressure or 0) >= 0.32)
    local bomberDefenseFloor = 0
    if emerg.BomberPanic or emerg.ExposedMexAirRaid or emerg.AirPanic then
        bomberDefenseFloor = 4
    elseif emerg.BomberWatch or (constraints.AirThreatZones or 0) > 0 then
        bomberDefenseFloor = 2
    elseif now >= 390 and landScreenUnits >= 8 then
        bomberDefenseFloor = 2
    end
    if bomberDefenseFloor > 0
        and engineerUnits >= 4
        and (landAA.CurrentUnits or 0) < bomberDefenseFloor
        and (landAA.UnitGap or 0) >= 0 then
        return 'LandAA', (bomberDefenseFloor >= 4) and 1230 or 1015
    end
    if now < 720
        and not severeLandCrisis
        and engineerUnits < engineerFloor
        and (engineer.UnitGap or 0) > 0 then
        return 'Engineer', 990
    end
    if now < 900
        and severeLandCrisis
        and engineerUnits < math.max(8, math.min(16, desiredEngineers))
        and landScreenUnits >= (now < 420 and 5 or 7)
        and (engineer.UnitGap or 0) > 0 then
        return 'Engineer', 985
    end

    local screenFloor = 0
    if now < 240 then
        screenFloor = 3
    elseif now < 420 then
        screenFloor = 7
    elseif now < 660 then
        screenFloor = 12
    elseif now < 900 then
        screenFloor = 14
    end
    if severeLandCrisis then
        if now < 420 then
            screenFloor = math.max(screenFloor, 12)
        elseif now < 660 then
            screenFloor = math.max(screenFloor, 22)
        elseif now < 900 then
            screenFloor = math.max(screenFloor, 28)
        else
            screenFloor = math.max(screenFloor, 24)
        end
    elseif constraints.ApproachReal or (constraints.BasePressure or 0) >= 0.14 or (constraints.FrontPressure or 0) >= 0.22 then
        screenFloor = math.max(screenFloor, now < 660 and 18 or 20)
    end

    if screenFloor > 0 and engineerUnits >= 3 and landScreenUnits < screenFloor then
        return 'LandDirect', 965
    end
    if now >= 150 and now < 660 and engineerUnits >= 4 and scoutUnits < 1 and landScreenUnits >= 2 then
        return 'LandScout', 930
    end
    if (emerg.LandPanic or emerg.FrontCollapse or constraints.ApproachReal or (constraints.BasePressure or 0) >= 0.14)
        and engineerUnits >= 2
        and landScreenUnits < 14 then
        return 'LandDirect', 975
    end

    return false, 0
end

local function SelectLiveAirDefenseRole(kind, runtime, rolePlan)
    local now = GetGameTimeSeconds()
    local raid = runtime.RaidDefense or {}
    local activeAirRaid = raid.UnderAirHarass == true
        or now < (raid.AirHarassUntil or -999)
        or now < (raid.BomberPanicUntil or -999)
        or ((raid.LastConfirmedBomberRaidTime or -999) >= (now - 45))
    if not activeAirRaid then
        return false, 0
    end

    local airThreat = math.max(raid.LastAirEnemyCount or 0, 0)
    local bombers = math.max(raid.LastBomberEnemyCount or 0, 0)
    local label = raid.LastThreatLabel or raid.LastAirHarassTargetLabel or 'none'
    local baseOrAcuThreat = label == 'acu' or label == 'main' or label == 'asset'

    if kind == 'land' and rolePlan.LandAA then
        local entry = rolePlan.LandAA
        local floor = 2
        if baseOrAcuThreat then
            floor = floor + 1
        end
        if bombers >= 1 then
            floor = floor + 2
        end
        if airThreat >= 6 then
            floor = floor + 1
        end
        floor = Clamp(floor, 2, 8)
        if (entry.CurrentUnits or 0) < floor then
            return 'LandAA', 1320 + (floor * 16), entry
        end
    elseif kind == 'air' and rolePlan.AirFighter then
        local entry = rolePlan.AirFighter
        local floor = Clamp(2 + math.floor(airThreat / 3) + math.min(2, bombers), 2, 10)
        if (entry.CurrentUnits or 0) < floor then
            return 'AirFighter', 1300 + (floor * 14), entry
        end
    end

    return false, 0
end

local function ComputeRoleUtility(roleName, entry, plan, eco, kind)
    local deficitStrength = (entry.DesiredStrength or entry.Desired or 0) - (entry.CurrentStrength or entry.Current or 0)
    local deficitUnits = (entry.DesiredUnits or 0) - (entry.CurrentUnits or 0)
    local utility = (entry.Priority or 0) * 100 + (deficitStrength * 16) + (deficitUnits * 5)
    local emerg = plan.EmergencyOverrides or {}
    local confidence = plan.Confidence or {}
    local rolePlan = plan.RolePlan or {}
    local currentFactories = (plan.Current and plan.Current.Factories) or {}
    local readyAirFactories = (((currentFactories.Air or {}).Ready) or 0)

    if roleName == 'Engineer' then
        if deficitStrength > 0 or deficitUnits > 0 then
            utility = utility + 14
        end
        if (entry.CurrentUnits or 0) <= 1 then
            utility = utility + 28
        elseif (entry.UnitGap or 0) >= 2 then
            utility = utility + 16
        end
        if deficitStrength <= 0 and deficitUnits <= -2 then
            utility = utility - 34
        end
        if (entry.CurrentUnits or 0) >= ((entry.DesiredUnits or 0) + 4) then
            utility = utility - 90
        elseif (entry.CurrentUnits or 0) >= ((entry.DesiredUnits or 0) + 2) then
            utility = utility - 42
        end
        if emerg.EcoCrash or (eco.MassStorageRatio or 0) < 0.05 then
            utility = utility + 18
        end
        if emerg.BomberPanic or emerg.ExposedMexAirRaid then
            utility = utility + 14
        end
    elseif roleName == 'LandDirect' then
        utility = utility + ((emerg.LandPanic or emerg.FrontCollapse) and 14 or 0)
    elseif roleName == 'LandAA' then
        utility = utility + ((emerg.BomberPanic or emerg.ExposedMexAirRaid) and 18 or 0)
        utility = utility + (emerg.BomberWatch and 8 or 0)
        utility = utility + (emerg.AirPanic and 20 or 0)
    elseif roleName == 'LandIndirect' then
        utility = utility - ((emerg.LandPanic and deficitStrength <= 0) and 14 or 0)
        utility = utility + (emerg.EnemyIndirectHeavy and 18 or 0)
        utility = utility + (emerg.EnemyT2Push and 12 or 0)
        utility = utility + (emerg.CounterAirWindow and 6 or 0)
    elseif roleName == 'AirFighter' then
        utility = utility + ((emerg.BomberPanic or emerg.ExposedMexAirRaid) and 16 or 0)
        utility = utility + (emerg.BomberWatch and 7 or 0)
        utility = utility + (emerg.AirPanic and 18 or 0)
        utility = utility + (emerg.CounterAirWindow and 10 or 0)
        utility = utility + (((emerg.EnemyLowAirThreat and (emerg.EnemyIndirectHeavy or emerg.EnemyT2Push)) and not emerg.CounterAirWindow) and 6 or 0)
        if (emerg.CounterAirWindow or (emerg.EnemyLowAirThreat and (emerg.EnemyIndirectHeavy or emerg.EnemyT2Push))) and (entry.CurrentUnits or 0) < 2 then
            utility = utility + 12
        end
    elseif roleName == 'AirBomber' then
        local fighterEntry = rolePlan.AirFighter or {}
        local bomberCounterWindow = emerg.CounterAirWindow or (emerg.EnemyLowAirThreat and (emerg.EnemyIndirectHeavy or emerg.EnemyT2Push))
        utility = utility - (emerg.AirPanic and 30 or 0)
        utility = utility - ((emerg.BomberPanic or emerg.ExposedMexAirRaid) and 24 or 0)
        utility = utility - (emerg.VisionPanic and 18 or 0)
        utility = utility - (((confidence.Global or 0) < 0.5) and 10 or 0)
        utility = utility + (bomberCounterWindow and 28 or 0)
        utility = utility + (emerg.EnemyIndirectHeavy and 16 or 0)
        utility = utility + (emerg.EnemyT2Push and 16 or 0)
        utility = utility + (((readyAirFactories >= 1) and bomberCounterWindow) and 16 or 0)
        if bomberCounterWindow and (fighterEntry.CurrentUnits or 0) < math.max(1, math.min(3, entry.DesiredUnits or 0)) then
            utility = utility - 4
        end
    elseif roleName == 'AirScout' then
        utility = utility + (emerg.VisionPanic and 16 or 0)
        utility = utility - (emerg.CounterAirWindow and 10 or 0)
        utility = utility - (((emerg.EnemyLowAirThreat and (emerg.EnemyIndirectHeavy or emerg.EnemyT2Push)) and not emerg.CounterAirWindow) and 10 or 0)
    elseif roleName == 'SeaAA' then
        utility = utility + (emerg.AirPanic and 8 or 0)
    end

    if deficitStrength <= 0 and deficitUnits <= 0 then
        utility = utility - 18 + math.min(8, deficitStrength * 2)
    end
    if kind == 'air' and roleName == 'AirBomber' and ((plan.TechPlan or {}).BlockReason == 'scouting_debt') then
        utility = utility - 18
    end
    return utility
end

local function PickPlannedRole(factory, runtime, eco)
    local kind = ClassifyFactory(factory)
    local plan = runtime.ProductionDirector or {}
    local rolePlan = plan.RolePlan or {}
    local roleNames = GetFactoryRoleNames(kind)
    local bestRole = false
    local bestUtility = -999999

    local liveRole, liveUtility, liveEntry = SelectLiveAirDefenseRole(kind, runtime, rolePlan)
    if liveRole and liveEntry then
        return liveRole, liveUtility, liveEntry
    end

    local forcedRole, forcedUtility = SelectEarlyLandScreenRole(kind, plan, rolePlan)
    if forcedRole and rolePlan[forcedRole] then
        return forcedRole, forcedUtility, rolePlan[forcedRole]
    end

    local now = plan.Time or GetGameTimeSeconds()
    local engineerDemand, demand = GetOutstandingEngineerDemand(runtime, now)
    if kind == 'land' and engineerDemand > 0 and rolePlan.Engineer then
        local emerg = plan.EmergencyOverrides or {}
        local constraints = plan.ConstraintState or {}
        local severeLandCrisis = emerg.LandPanic
            or emerg.FrontCollapse
            or ((constraints.BasePressure or 0) >= 0.36)
        local immediateEcoDemand = (demand.InitialMexBuildersWanted or 0) > 0
            or (demand.FactoryFinishWanted or 0) > 0
            or (demand.StructureFinishWanted or 0) > 0
            or (demand.BaseWanted or 0) > 0
            or (demand.PowerWanted or 0) > 0
        if immediateEcoDemand or not severeLandCrisis or CountLandScreenUnits(rolePlan) >= (now < 420 and 4 or 7) then
            return 'Engineer', 1040 + (engineerDemand * 18), rolePlan.Engineer
        end
    end

    for _, roleName in roleNames do
        local entry = rolePlan[roleName]
        if entry then
            local utility = ComputeRoleUtility(roleName, entry, plan, eco, kind)
            if utility > bestUtility then
                bestUtility = utility
                bestRole = roleName
            end
        end
    end

    if not bestRole then
        bestRole = FallbackRole(kind, plan, eco)
    end
    return bestRole, bestUtility, (bestRole and rolePlan[bestRole]) or false
end

local function PickBlueprintForRole(factory, roleName, entry, runtime, eco)
    local plan = runtime.ProductionDirector or {}
    local emerg = plan.EmergencyOverrides or {}
    local techPlan = plan.TechPlan or {}
    local preferCheap = emerg.EcoCrash or emerg.QueueStarved or (eco.MassStorageRatio or 0) < 0.08 or (eco.EnergyStorageRatio or 0) < 0.08
    local techBias = 0.2
    if roleName == 'LandDirect' or roleName == 'LandAA' or roleName == 'LandIndirect' or roleName == 'LandScout' or roleName == 'Engineer' then
        techBias = techPlan.LandTechBias or 0.2
    elseif roleName == 'AirFighter' or roleName == 'AirBomber' or roleName == 'AirScout' then
        techBias = techPlan.AirTechBias or 0.15
    else
        techBias = math.max(techPlan.LandTechBias or 0.15, techPlan.AirTechBias or 0.15) * 0.5
    end
    local needBias = Clamp((entry and (entry.StrengthGap or 0) or 0) * 0.12, 0, 2.2)
    return PickBuildBlueprint(factory, GetRoleCategory(roleName), roleName, preferCheap, techBias, needBias)
end

local function GetFactoryUpgradeBlueprintId(factory)
    if not factory or factory.Dead or not factory.GetBlueprint then
        return false
    end
    local bp = factory:GetBlueprint()
    if not bp or not bp.General then
        return false
    end
    local upgradeBp = bp.General.UpgradesTo
    if type(upgradeBp) ~= 'string' or upgradeBp == '' then
        return false
    end
    return upgradeBp
end

local function CountActiveFactoryUpgrades(aiBrain, kind)
    local factories = aiBrain:GetListOfUnits(categories.FACTORY * categories.STRUCTURE, false, true) or {}
    local count = 0
    for _, fac in factories do
        if fac and not fac.Dead and fac:IsUnitState('Upgrading') then
            if not kind or ClassifyFactory(fac) == kind then
                count = count + 1
            end
        end
    end
    return count
end

local function CountTechEngineers(aiBrain)
    return aiBrain:GetCurrentUnits(TechEngineerCategory) or 0
end

local function GetMacroObjective(runtime)
    local macro = (runtime and runtime.MacroController) or false
    if type(macro) == 'table' and macro.Phase then
        return macro.Phase
    end
    local prod = (runtime and runtime.ProductionDirector) or {}
    return prod.MacroObjective or 'land_factory_floor'
end

local function NeedsFirstLandHQ(runtime)
    local macroObjective = GetMacroObjective(runtime)
    local now = GetGameTimeSeconds()
    local macro = (runtime and runtime.MacroController) or {}
    if now < ((runtime or {}).FirstHQAbortUntil or -999) or macro.HQPressureEscape == true then
        return false
    end
    if macroObjective == 'first_land_hq' or macroObjective == 'first_t2_engineer' or macroObjective == 'first_t2_power' then
        return true
    end
    local factoryUpgrade = (((runtime or {}).UpgradeDirector or {}).Factory) or {}
    if factoryUpgrade.Reason == 'pressure_escape'
        or factoryUpgrade.Reason == 't1_combat_hold'
        or factoryUpgrade.Reason == 'first_hq_abort_hold'
        or factoryUpgrade.Reason == 'aborted_first_hq_under_pressure' then
        return false
    end
    return factoryUpgrade.NeedsFirstLandHQ == true and factoryUpgrade.Enabled ~= true
end

local function ShouldForceFirstTechEngineer(aiBrain, factory, runtime, eco, now)
    if not factory or factory.Dead then
        return false
    end
    if ClassifyFactory(factory) ~= 'land' then
        return false
    end
    if not EntityCategoryContains(categories.TECH2 + categories.TECH3, factory) then
        return false
    end
    if CountTechEngineers(aiBrain) >= 1 then
        return false
    end
    if now and now < ((runtime.FirstTechEngineerQueuedUntil or -999)) then
        return false
    end

    local plan = runtime.ProductionDirector or {}
    local current = plan.Current or {}
    local constraints = plan.ConstraintState or {}
    local macroObjective = GetMacroObjective(runtime)
    local landFactories = current.Factories and current.Factories.Land or {}
    local readyLand = landFactories.Ready or 0
    local mexReady = (((current.Eco or {}).Mex or {}).Ready) or 0
    local powerReady = (((current.Eco or {}).Power or {}).Ready) or 0

    local objectiveDriven = macroObjective == 'first_t2_engineer' or macroObjective == 'first_t2_power' or macroObjective == 'surplus_scale'
    if not objectiveDriven and (readyLand < 1 or mexReady < 3 or powerReady < 3) then
        return false
    end
    if constraints.EcoCrash or constraints.QueueStarved or constraints.LandPanic or constraints.AirPanic then
        return false
    end
    if not objectiveDriven and ((eco.MassIncome or 0) < 2.0 or (eco.EnergyIncome or 0) < 36) then
        return false
    end
    if not objectiveDriven and ((eco.MassTrend or 0) < -0.30 or (eco.EnergyTrend or 0) < -14) then
        return false
    end
    if not objectiveDriven and ((eco.MassStorageRatio or 0) < 0.01 or (eco.EnergyStorageRatio or 0) < 0.03) then
        return false
    end

    return true
end

local function ShouldUpgradeFactory(aiBrain, factory, runtime, eco, qLen)
    if not factory or factory.Dead then
        return false, false
    end
    if ClassifyFactory(factory) ~= 'land' then
        return false, false
    end

    local upgradeBp = GetFactoryUpgradeBlueprintId(factory)
    if not upgradeBp or not factory:CanBuild(upgradeBp) then
        return false, false
    end

    local plan = runtime.ProductionDirector or {}
    local upgradeDirector = runtime.UpgradeDirector or {}
    local directedFactory = upgradeDirector.Factory or {}
    local factoryId = tostring(factory.GetEntityId and factory:GetEntityId() or factory.UnitId or factory)
    local directedUpgradeTarget = directedFactory.Managed == true
        and directedFactory.Enabled == true
        and directedFactory.TargetId == factoryId
    if qLen > 0 and not directedUpgradeTarget then
        return false, false
    end
    local current = plan.Current or {}
    local constraints = plan.ConstraintState or {}
    local techPlan = plan.TechPlan or {}
    local planner = runtime.StrategicPlanner or {}
    local macroObjective = GetMacroObjective(runtime)
    local objectiveLandTech = macroObjective == 'first_land_hq'
        or macroObjective == 'first_t2_engineer'
        or macroObjective == 'first_t2_power'
    local ecoCounts = current.Eco or {}
    local landFactories = current.Factories and current.Factories.Land or {}
    local readyLand = landFactories.Ready or 0
    local totalLand = landFactories.Total or 0
    local mexReady = (((current.Eco or {}).Mex or {}).Ready) or 0
    local mapControl = ((runtime.ZoneModel or {}).MapControl) or ((runtime.IntelModel or {}).MapControl) or 0
    local mexPeakReady = ((runtime.EngineerState or {}).PeakMexReady) or mexReady
    local mexLossCount = math.max(0, mexPeakReady - mexReady)
    local collapseRecovery = mapControl <= 0.28 or mexLossCount >= 1 or mexReady <= 5
    local factoryTask = current.FactoryTask or {}
    local completionDebt = factoryTask.Active
        and factoryTask.Domain == 'Land'
        and ((factoryTask.AssignedBuilders or 0) < math.max(1, factoryTask.RequiredBuilders or 0))

    if directedFactory.Managed == true then
        if directedFactory.Enabled ~= true or directedFactory.TargetId ~= factoryId then
            return false, false
        end
        if directedFactory.UpgradeBp and factory:CanBuild(directedFactory.UpgradeBp) then
            return true, directedFactory.UpgradeBp
        end
        return false, false
    end

    if (not objectiveLandTech) and (readyLand < (collapseRecovery and 2 or 3) or totalLand < (collapseRecovery and 3 or 4)) then
        return false, false
    end
    if CountActiveFactoryUpgrades(aiBrain, 'land') > 0 then
        return false, false
    end
    if constraints.EcoCrash or constraints.QueueStarved or constraints.CriticalStructure then
        return false, false
    end
    if (constraints.PowerBufferLow or constraints.CriticalFactory) and not objectiveLandTech then
        return false, false
    end
    if completionDebt then
        return false, false
    end
    local surplusSpendWindow = constraints.SurplusSpendWindow == true
    local strongSurplusWindow = constraints.StrongSurplusWindow == true

    if (not objectiveLandTech) and not surplusSpendWindow and ((eco.MassIncome or 0) < (collapseRecovery and 2.4 or 3.2) or (eco.EnergyIncome or 0) < (collapseRecovery and 42 or 60)) then
        return false, false
    end
    if (not objectiveLandTech) and not surplusSpendWindow and ((eco.MassStorageRatio or 0) < (collapseRecovery and 0.02 or 0.06) or (eco.EnergyStorageRatio or 0) < (collapseRecovery and 0.04 or 0.12)) then
        return false, false
    end
    if (((ecoCounts.Power or {}).Ready) or 0) < 4 or (((ecoCounts.Mex or {}).Ready) or 0) < 4 then
        return false, false
    end
    if (not objectiveLandTech) and not strongSurplusWindow and ((eco.MassTrend or 0) < (collapseRecovery and -0.28 or -0.12) or (eco.EnergyTrend or 0) < (collapseRecovery and -10 or -2)) then
        return false, false
    end

    local strategicTechWindow = techPlan.EligibleForTech
        or surplusSpendWindow
        or planner.TradeMapForTech
        or planner.ForceAirAnswer
        or ((plan.Mode == 'pressure' or plan.Mode == 'expand' or plan.Mode == 'air_control') and readyLand >= 4 and (eco.MassTrend or 0) >= -0.05)
        or (readyLand >= 5 and (eco.EnergyStorageRatio or 0) >= 0.16 and (eco.MassTrend or 0) >= -0.08)
    if not strategicTechWindow and not objectiveLandTech and not collapseRecovery then
        return false, false
    end

    return true, upgradeBp
end

local function TryIssuePlannedBuild(aiBrain, factory, runtime, now, state, queueLen, forceTopoff, forceFirstTechEngineer)
    if not IsFactoryReady(factory) then
        return false, 'not-ready'
    end

    local qLen = queueLen or 0
    if qLen <= 0 then
        local q = factory.GetCommandQueue and factory:GetCommandQueue() or false
        qLen = q and table.getn(q) or 0
    end
    if qLen > 0 and not forceTopoff then
        return false, 'has-queue'
    end
    if factory:IsUnitState('Building') and not forceTopoff then
        return false, 'building'
    end
    if IsNearUnitCap(aiBrain) then
        return false, 'unit-cap'
    end

    local eco = GetEcon(runtime)
    if forceFirstTechEngineer or ShouldForceFirstTechEngineer(aiBrain, factory, runtime, eco, now) then
        local bp = PickBuildBlueprint(factory, TechEngineerCategory, 'Engineer', true, 2.0, 2.0)
        if bp and IssueBuildFactory then
            if (qLen > 0 or factory:IsUnitState('Building')) and IssueClearCommands then
                IssueClearCommands({ factory })
            end
            IssueBuildFactory({ factory }, bp, 1)
            runtime.FirstTechEngineerQueuedUntil = now + 90
            runtime.FirstTechEngineerQueuedBlueprint = bp
            state.LastIssuedTime = now
            state.LastRole = 'FirstTechEngineer'
            state.LastUtility = 995
            state.LastBlueprint = bp
            state.NextIssueTime = now + 0.6
            return true, 'FirstTechEngineer'
        end
    end

    local shouldUpgrade, upgradeBp = ShouldUpgradeFactory(aiBrain, factory, runtime, eco, qLen)
    if shouldUpgrade and upgradeBp and IssueUpgrade then
        if qLen > 0 and IssueClearCommands then
            IssueClearCommands({ factory })
        end
        IssueUpgrade({ factory }, upgradeBp)
        state.LastIssuedTime = now
        state.LastRole = 'FactoryUpgrade'
        state.LastUtility = 999
        state.LastBlueprint = upgradeBp
        state.NextIssueTime = now + 1.0
        return true, 'FactoryUpgrade'
    end
    if NeedsFirstLandHQ(runtime) and ClassifyFactory(factory) == 'land' then
        state.LastRole = 'FactoryUpgradeReserve'
        state.NextIssueTime = now + 1.0
        return false, 'reserved-hq-upgrade'
    end
    local roleName, utility, entry = PickPlannedRole(factory, runtime, eco)
    if not roleName then
        return false, 'no-role'
    end

    local bp = PickBlueprintForRole(factory, roleName, entry, runtime, eco)
    if not bp then
        return false, 'no-blueprint'
    end

    if IssueBuildFactory then
        IssueBuildFactory({ factory }, bp, 1)
        if roleName == 'Engineer' and runtime.EngineerDemand then
            runtime.EngineerDemand.PendingFactoryOrders = (runtime.EngineerDemand.PendingFactoryOrders or 0) + 1
        end
        state.LastIssuedTime = now
        state.LastRole = roleName
        state.LastUtility = utility
        state.LastBlueprint = bp
        state.NextIssueTime = now + (forceTopoff and 0.15 or 0.55)
        return true, roleName
    end
    return false, 'no-issue-build'
end
function Module.Update(aiBrain, now)
    local runtime = aiBrain.OvermindRuntime or {}
    aiBrain.OvermindRuntime = runtime
    local ctrl = runtime.FactoryController or {
        PerFactory = {},
        LastLogTime = -999,
    }
    runtime.FactoryController = ctrl
    ctrl.PerFactory = ctrl.PerFactory or {}
    ctrl.LastUpdate = now

    local allFactories = aiBrain:GetListOfUnits(categories.FACTORY * categories.STRUCTURE, false, true)
    if not allFactories or table.getn(allFactories) <= 0 then
        OvermindEconomyLedger.PublishFactoryActivity(aiBrain, runtime, now, {
            TotalCount = 0,
            ReadyCount = 0,
            EmptyCount = 0,
            IdleCount = 0,
            IssuedCount = 0,
            ToppedCount = 0,
            QueueDepthTarget = 0,
            DomainReady = { Land = 0, Air = 0, Navy = 0, Other = 0 },
            DomainIdle = { Land = 0, Air = 0, Navy = 0, Other = 0 },
            BlockedReason = 'no_factories',
        })
        return
    end

    local readyFactories = 0
    local emptyFactories = 0
    local idleFactories = 0
    local issued = 0
    local topped = 0
    local domainReady = { Land = 0, Air = 0, Navy = 0, Other = 0 }
    local domainIdle = { Land = 0, Air = 0, Navy = 0, Other = 0 }
    local eco = GetEcon(runtime)
    local queueDepthTarget = DesiredQueueDepth(runtime, eco)
    local firstHQReserve = NeedsFirstLandHQ(runtime)
    if firstHQReserve then
        queueDepthTarget = math.min(queueDepthTarget, 1)
    end

    for _, factory in allFactories do
        if factory and not factory.Dead then
            local id = tostring(factory.GetEntityId and factory:GetEntityId() or factory.UnitId or 'fac')
            local state = ctrl.PerFactory[id] or {}
            ctrl.PerFactory[id] = state

            if IsFactoryReady(factory) then
                readyFactories = readyFactories + 1
                local kind = ClassifyFactory(factory)
                local domain = kind == 'land' and 'Land' or kind == 'air' and 'Air' or kind == 'sea' and 'Navy' or 'Other'
                domainReady[domain] = (domainReady[domain] or 0) + 1
                local q = factory.GetCommandQueue and factory:GetCommandQueue() or false
                local qLen = q and table.getn(q) or 0
                if qLen <= 0 then
                    emptyFactories = emptyFactories + 1
                    domainIdle[domain] = (domainIdle[domain] or 0) + 1
                end
                local forceFirstTechEngineer = ShouldForceFirstTechEngineer(aiBrain, factory, runtime, eco, now)
                if forceFirstTechEngineer or qLen < queueDepthTarget or (firstHQReserve and kind == 'land' and qLen <= 0) then
                    if qLen <= 0 and not factory:IsUnitState('Building') then
                        idleFactories = idleFactories + 1
                    end
                    local ok = TryIssuePlannedBuild(aiBrain, factory, runtime, now, state, qLen, qLen > 0, forceFirstTechEngineer)
                    if ok then
                        issued = issued + 1
                        if qLen > 0 then
                            topped = topped + 1
                        end
                    end
                end
            end
        end
    end

    local recovery = runtime.Recovery or {}
    runtime.Recovery = recovery
    recovery.FactoryQueueInvariantBroken = emptyFactories > 0
    recovery.LastFactoryQueueInvariantHealthyTime = (emptyFactories <= 0 and readyFactories > 0) and now or (recovery.LastFactoryQueueInvariantHealthyTime or now)

    ctrl.LastIdleCount = idleFactories
    ctrl.LastReadyCount = readyFactories
    ctrl.LastEmptyCount = emptyFactories
    ctrl.LastIssued = issued
    ctrl.LastTopped = topped
    ctrl.DomainReady = domainReady
    ctrl.DomainIdle = domainIdle

    OvermindEconomyLedger.PublishFactoryActivity(aiBrain, runtime, now, {
        TotalCount = table.getn(allFactories),
        ReadyCount = readyFactories,
        EmptyCount = emptyFactories,
        IdleCount = idleFactories,
        IssuedCount = issued,
        ToppedCount = topped,
        QueueDepthTarget = queueDepthTarget,
        DomainReady = domainReady,
        DomainIdle = domainIdle,
        BlockedReason = emptyFactories > 0 and issued <= 0 and 'no_issue' or 'none',
    })

    if issued > 0 or now - (ctrl.LastLogTime or -999) >= 28 then
        ctrl.LastLogTime = now
        local plan = runtime.ProductionDirector or {}
        local cap = plan.CapacityPlan or {}
        LOG(string.format('*OVERMIND FACTCTRL A%d t=%.1f mode=%s fac=%d ready=%d empty=%d qtarget=%d idle=%d issued=%d topped=%d growth=%d tgt=%d/%d/%d',
            aiBrain:GetArmyIndex(),
            now,
            plan.Mode or 'none',
            table.getn(allFactories),
            readyFactories,
            emptyFactories,
            queueDepthTarget,
            idleFactories,
            issued,
            topped,
            cap.PauseFactoryGrowth and 0 or 1,
            cap.LandTarget or 0,
            cap.AirTarget or 0,
            cap.SeaTarget or 0))
    end
end

function Update(aiBrain, now)
    return Module.Update(aiBrain, now)
end

return Module
