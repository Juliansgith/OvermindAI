local Module = {}
local OvermindRoleWeights = import('/mods/OvermindAI/lua/AI/Overmind/RoleWeights.lua')

local LandDirectCategory = categories.MOBILE * categories.LAND * categories.DIRECTFIRE
    - categories.ENGINEER - categories.SCOUT - categories.ANTIAIR - categories.COMMAND
local LandAACategory = categories.MOBILE * categories.LAND * categories.ANTIAIR
    - categories.ENGINEER - categories.SCOUT - categories.COMMAND
local LandIndirectCategory = categories.MOBILE * categories.LAND * categories.INDIRECTFIRE
    - categories.ENGINEER - categories.SCOUT - categories.COMMAND
local LandScoutCategory = categories.MOBILE * categories.LAND * categories.SCOUT - categories.ENGINEER
local EngineerCategory = categories.ENGINEER * categories.MOBILE

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

local function ShouldUpgradeFactory(aiBrain, factory, runtime, eco, qLen)
    if qLen > 0 or not factory or factory.Dead then
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
    local current = plan.Current or {}
    local constraints = plan.ConstraintState or {}
    local techPlan = plan.TechPlan or {}
    local planner = runtime.StrategicPlanner or {}
    local ecoCounts = current.Eco or {}
    local landFactories = current.Factories and current.Factories.Land or {}
    local readyLand = landFactories.Ready or 0
    local totalLand = landFactories.Total or 0
    local factoryTask = current.FactoryTask or {}
    local completionDebt = factoryTask.Active
        and factoryTask.Domain == 'Land'
        and ((factoryTask.AssignedBuilders or 0) < math.max(1, factoryTask.RequiredBuilders or 0))

    if directedFactory.Managed == true then
        local factoryId = tostring(factory.GetEntityId and factory:GetEntityId() or factory.UnitId or factory)
        if directedFactory.Enabled ~= true or directedFactory.TargetId ~= factoryId then
            return false, false
        end
        if directedFactory.UpgradeBp and factory:CanBuild(directedFactory.UpgradeBp) then
            return true, directedFactory.UpgradeBp
        end
        return false, false
    end

    if readyLand < 3 or totalLand < 4 then
        return false, false
    end
    if CountActiveFactoryUpgrades(aiBrain, 'land') > 0 then
        return false, false
    end
    if constraints.EcoCrash or constraints.QueueStarved or constraints.PowerBufferLow or constraints.CriticalFactory or constraints.CriticalStructure then
        return false, false
    end
    if completionDebt then
        return false, false
    end
    local surplusSpendWindow = constraints.SurplusSpendWindow == true
    local strongSurplusWindow = constraints.StrongSurplusWindow == true

    if not surplusSpendWindow and ((eco.MassIncome or 0) < 3.2 or (eco.EnergyIncome or 0) < 60) then
        return false, false
    end
    if not surplusSpendWindow and ((eco.MassStorageRatio or 0) < 0.06 or (eco.EnergyStorageRatio or 0) < 0.12) then
        return false, false
    end
    if (((ecoCounts.Power or {}).Ready) or 0) < 4 or (((ecoCounts.Mex or {}).Ready) or 0) < 4 then
        return false, false
    end
    if not strongSurplusWindow and ((eco.MassTrend or 0) < -0.12 or (eco.EnergyTrend or 0) < -2) then
        return false, false
    end

    local strategicTechWindow = techPlan.EligibleForTech
        or surplusSpendWindow
        or planner.TradeMapForTech
        or planner.ForceAirAnswer
        or ((plan.Mode == 'pressure' or plan.Mode == 'expand' or plan.Mode == 'air_control') and readyLand >= 4 and (eco.MassTrend or 0) >= -0.05)
    if not strategicTechWindow then
        return false, false
    end

    return true, upgradeBp
end

local function TryIssuePlannedBuild(aiBrain, factory, runtime, now, state, queueLen, forceTopoff)
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
    local shouldUpgrade, upgradeBp = ShouldUpgradeFactory(aiBrain, factory, runtime, eco, qLen)
    if shouldUpgrade and upgradeBp and IssueUpgrade then
        IssueUpgrade({ factory }, upgradeBp)
        state.LastIssuedTime = now
        state.LastRole = 'FactoryUpgrade'
        state.LastUtility = 999
        state.LastBlueprint = upgradeBp
        state.NextIssueTime = now + 1.0
        return true, 'FactoryUpgrade'
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
        return
    end

    local readyFactories = 0
    local emptyFactories = 0
    local idleFactories = 0
    local issued = 0
    local topped = 0
    local eco = GetEcon(runtime)
    local queueDepthTarget = DesiredQueueDepth(runtime, eco)

    for _, factory in allFactories do
        if factory and not factory.Dead then
            local id = tostring(factory.GetEntityId and factory:GetEntityId() or factory.UnitId or 'fac')
            local state = ctrl.PerFactory[id] or {}
            ctrl.PerFactory[id] = state

            if IsFactoryReady(factory) then
                readyFactories = readyFactories + 1
                local q = factory.GetCommandQueue and factory:GetCommandQueue() or false
                local qLen = q and table.getn(q) or 0
                if qLen <= 0 then
                    emptyFactories = emptyFactories + 1
                end
                if qLen < queueDepthTarget then
                    if qLen <= 0 and not factory:IsUnitState('Building') then
                        idleFactories = idleFactories + 1
                    end
                    local ok = TryIssuePlannedBuild(aiBrain, factory, runtime, now, state, qLen, qLen > 0)
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
