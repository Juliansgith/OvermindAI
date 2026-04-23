local AIUtils = import('/lua/ai/aiutilities.lua')
local EBC = import('/lua/editor/EconomyBuildConditions.lua')
local OvermindMemory = import('/mods/OvermindAI/lua/AI/Overmind/Memory.lua')
local OvermindAutoTune = import('/mods/OvermindAI/lua/AI/Overmind/AutoTune.lua')

local GetCompletedUnitCount
local GetMainPos
local CountSafeRemoteExtractorUpgradeCandidates
local Distance2D
local GetZoneMapControl

local function GetEcon(aiBrain)
    return AIUtils.AIGetEconomyNumbers(aiBrain)
end

local function GetPolicy(aiBrain)
    if aiBrain and aiBrain.OvermindRuntime and aiBrain.OvermindRuntime.EcoPolicy then
        return aiBrain.OvermindRuntime.EcoPolicy
    end
    return false
end

local function GetAutoTune(aiBrain)
    return OvermindAutoTune.GetConfig(aiBrain)
end

local function GetRecovery(aiBrain)
    if aiBrain and aiBrain.OvermindRuntime and aiBrain.OvermindRuntime.Recovery then
        return aiBrain.OvermindRuntime.Recovery
    end
    return false
end

local function GetProductionDirector(aiBrain)
    if aiBrain and aiBrain.OvermindRuntime and aiBrain.OvermindRuntime.ProductionDirector then
        return aiBrain.OvermindRuntime.ProductionDirector
    end
    return false
end

local function GetUpgradeDirector(aiBrain)
    if aiBrain and aiBrain.OvermindRuntime and aiBrain.OvermindRuntime.UpgradeDirector then
        return aiBrain.OvermindRuntime.UpgradeDirector
    end
    return false
end

local function GetEngineerState(aiBrain)
    if aiBrain and aiBrain.OvermindRuntime and aiBrain.OvermindRuntime.EngineerState then
        return aiBrain.OvermindRuntime.EngineerState
    end
    return false
end

local function HasCriticalFactoryTask(aiBrain, domain)
    local state = GetEngineerState(aiBrain)
    local task = state and state.UnfinishedFactoryTask or false
    if not task or task.Active ~= true then
        return false
    end
    if not domain then
        return true
    end
    local normalized = string.lower(domain or '')
    if normalized == 'sea' then
        normalized = 'navy'
    elseif normalized == 'naval' then
        normalized = 'navy'
    end
    return string.lower(task.Domain or '') == normalized
end

local function HasCriticalStructureTask(aiBrain)
    local state = GetEngineerState(aiBrain)
    local task = state and state.UnfinishedStructureTask or false
    if not task or task.Active ~= true then
        return false
    end
    if (task.AssignedBuilders or 0) >= (task.RequiredBuilders or 0) then
        return false
    end
    local kind = string.lower(task.Kind or 'none')
    return kind == 'mex' or kind == 'power' or kind == 'radar'
end

local function HasPendingExpansionWork(aiBrain)
    local runtime = aiBrain and aiBrain.OvermindRuntime or false
    local state = GetEngineerState(aiBrain)
    local now = GetGameTimeSeconds()
    if runtime and ((runtime.LastExpansionDispatchTime or -999) + 24) > now then
        return true
    end
    if state and state.UnfinishedStructureTask and state.UnfinishedStructureTask.Active == true then
        local kind = string.lower(state.UnfinishedStructureTask.Kind or 'none')
        if kind == 'mex' then
            return true
        end
    end
    local reservations = state and state.ExpansionReservations or false
    if not reservations then
        return false
    end
    for _, data in pairs(reservations) do
        if data and (data.ExpiresAt or -999) > now then
            return true
        end
    end
    return false
end

local function HasRecoveryFlag(aiBrain, flagName)
    local recovery = GetRecovery(aiBrain)
    if not recovery or not flagName then
        return false
    end
    return recovery[flagName] == true
end

local function GetRolePlanMetrics(entry)
    if not entry then
        return 0, 0, 0, 0
    end
    local currentStrength = entry.CurrentStrength or entry.Current or 0
    local desiredStrength = entry.DesiredStrength or entry.Desired or 0
    local currentUnits = entry.CurrentUnits or 0
    local desiredUnits = entry.DesiredUnits or 0
    return currentStrength, desiredStrength, currentUnits, desiredUnits
end

local function RolePlanNeedsMore(entry, minDesiredUnits)
    if not entry then
        return false
    end
    local currentStrength, desiredStrength, currentUnits, desiredUnits = GetRolePlanMetrics(entry)
    desiredUnits = math.max(desiredUnits, minDesiredUnits or 0)
    if desiredStrength > 0 and (currentStrength + 0.05) < desiredStrength then
        return true
    end
    return currentUnits < desiredUnits
end

local function GetRolePlanEntry(aiBrain, roleName)
    local director = GetProductionDirector(aiBrain)
    local rolePlan = director and director.RolePlan or false
    if not rolePlan or not roleName then
        return false
    end
    return rolePlan[roleName] or false
end

local function IsEconomyBootstrapState(aiBrain)
    local director = GetProductionDirector(aiBrain)
    local constraints = director and director.ConstraintState or false
    return constraints and constraints.EconBootstrap == true
end

local function IsStarterPhaseState(aiBrain)
    local director = GetProductionDirector(aiBrain)
    local constraints = director and director.ConstraintState or false
    return constraints and constraints.StarterPhase == true
end

local function NeedsBootstrapPowerState(aiBrain)
    local director = GetProductionDirector(aiBrain)
    local constraints = director and director.ConstraintState or false
    if not constraints or (constraints.EconBootstrap ~= true and constraints.StarterPhase ~= true) then
        return false
    end
    local required = constraints.StarterPowerFloor or constraints.BootstrapPowerFloor or 1
    local ready = GetCompletedUnitCount(aiBrain, categories.ENERGYPRODUCTION * categories.STRUCTURE)
    return ready < required
end

function IsEconomyBootstrap(aiBrain)
    if not IsOvermindBrain(aiBrain) then
        return false
    end
    return IsEconomyBootstrapState(aiBrain)
end

function IsStarterPhase(aiBrain)
    if not IsOvermindBrain(aiBrain) then
        return false
    end
    return IsStarterPhaseState(aiBrain)
end

function NeedsBootstrapPower(aiBrain)
    if not IsOvermindBrain(aiBrain) then
        return false
    end
    return NeedsBootstrapPowerState(aiBrain)
end

function HasBootstrapPowerFloor(aiBrain)
    if not IsOvermindBrain(aiBrain) then
        return false
    end
    return not NeedsBootstrapPowerState(aiBrain)
end

function NeedOpeningMexFloor(aiBrain, minReady, maxTime)
    if not IsOvermindBrain(aiBrain) then
        return false
    end

    local now = GetGameTimeSeconds()
    local target = minReady or 4
    local deadline = maxTime or 360
    local readyMex = GetCompletedUnitCount(aiBrain, categories.MASSEXTRACTION * categories.STRUCTURE)
    if readyMex >= target then
        return false
    end

    return now <= deadline or readyMex < math.max(2, target - 1)
end

local function GetUnitCount(aiBrain, category)
    if not aiBrain or not category then
        return 0
    end

    return aiBrain:GetCurrentUnits(category) or 0
end

local function GetExistingUnitCount(aiBrain, category, aroundPos, radius)
    if not aiBrain or not category then
        return 0
    end

    local units = false
    if aroundPos and radius and radius > 0 then
        units = aiBrain:GetUnitsAroundPoint(category, aroundPos, radius, 'Ally')
    else
        units = aiBrain:GetListOfUnits(category, false, true)
    end
    if not units then
        return 0
    end

    local count = 0
    for _, unit in units do
        if unit and not unit.Dead then
            count = count + 1
        end
    end
    return count
end

GetCompletedUnitCount = function(aiBrain, category, aroundPos, radius)
    if not aiBrain or not category then
        return 0
    end

    local units = false
    if aroundPos and radius and radius > 0 then
        units = aiBrain:GetUnitsAroundPoint(category, aroundPos, radius, 'Ally')
    else
        units = aiBrain:GetListOfUnits(category, false, true)
    end
    if not units then
        return 0
    end

    local count = 0
    for _, unit in units do
        if unit and not unit.Dead then
            local complete = true
            if unit.GetFractionComplete then
                local ok, fraction = pcall(function()
                    return unit:GetFractionComplete()
                end)
                if ok and type(fraction) == 'number' then
                    complete = fraction >= 0.95
                end
            end
            if complete then
                count = count + 1
            end
        end
    end
    return count
end

local function GetUnfinishedUnitCount(aiBrain, category, aroundPos, radius)
    local existing = GetExistingUnitCount(aiBrain, category, aroundPos, radius)
    if existing <= 0 then
        return 0
    end
    local complete = GetCompletedUnitCount(aiBrain, category, aroundPos, radius)
    return math.max(0, existing - complete)
end

local function IsFirstHQPriorityState(aiBrain, minReadyLand)
    if not aiBrain then
        return false
    end

    local hasLandHQ = GetCompletedUnitCount(aiBrain, categories.FACTORY * categories.LAND * categories.STRUCTURE * (categories.TECH2 + categories.TECH3)) > 0
    if hasLandHQ then
        return false
    end

    local runtime = aiBrain.OvermindRuntime or {}
    local production = runtime.ProductionDirector or {}
    local current = production.Current or {}
    local factories = current.Factories or {}
    local ecoCounts = current.Eco or {}
    local macro = runtime.MacroController or {}
    local macroPhase = macro.Phase or production.MacroObjective or 'none'
    local factoryDirective = ((runtime.UpgradeDirector or {}).Factory) or {}
    local readyLand = ((factories.Land or {}).Ready) or GetCompletedUnitCount(aiBrain, categories.FACTORY * categories.LAND * categories.STRUCTURE)
    local mexReady = (((ecoCounts.Mex or {}).Ready) or GetCompletedUnitCount(aiBrain, categories.MASSEXTRACTION * categories.STRUCTURE))
    local powerReady = (((ecoCounts.Power or {}).Ready) or GetCompletedUnitCount(aiBrain, categories.ENERGYPRODUCTION * categories.STRUCTURE))
    local hasFloor = readyLand >= (minReadyLand or 3)
        and mexReady >= 5
        and powerReady >= 5
    if not hasFloor then
        return false
    end

    return macro.HQPressureEscape == true
        or factoryDirective.NeedsFirstLandHQ == true
        or macroPhase == 'mass_consolidation'
        or macroPhase == 'first_land_hq'
        or macroPhase == 'first_t2_engineer'
        or macroPhase == 'first_t2_power'
end

local function IsLowTechDefenseCapped(aiBrain, bomberPanic)
    if not aiBrain then
        return false
    end

    local runtime = aiBrain.OvermindRuntime or {}
    local production = runtime.ProductionDirector or {}
    local current = production.Current or {}
    local ecoCounts = current.Eco or {}
    local macro = runtime.MacroController or {}
    local macroPhase = macro.Phase or production.MacroObjective or 'none'
    local mexReady = (((ecoCounts.Mex or {}).Ready) or GetCompletedUnitCount(aiBrain, categories.MASSEXTRACTION * categories.STRUCTURE))
    local t2PowerReady = GetCompletedUnitCount(aiBrain, categories.ENERGYPRODUCTION * categories.STRUCTURE * (categories.TECH2 + categories.TECH3))
    local t2MexReady = GetCompletedUnitCount(aiBrain, categories.MASSEXTRACTION * categories.STRUCTURE * (categories.TECH2 + categories.TECH3))
    local defenseCount = GetExistingUnitCount(aiBrain, categories.STRUCTURE * categories.DEFENSE * categories.TECH1)
    local cap = bomberPanic and 4 or 3
    local techTransition = macroPhase == 'first_t2_power'
        or macroPhase == 'first_t2_engineer'
        or (t2PowerReady <= 0 and t2MexReady <= 0)
    return techTransition
        and mexReady <= 8
        and defenseCount >= cap
end

local function GetExtractorUpgradePlan(aiBrain)
    local upgradeDirector = GetUpgradeDirector(aiBrain)
    local directedExtractor = upgradeDirector and upgradeDirector.Extractor or false
    if directedExtractor and directedExtractor.Managed == true then
        local cap = math.max(0, math.floor((directedExtractor.Cap or 0) + 0.5))
        local inFlight = math.max(0, directedExtractor.InFlight or 0)
        return {
            UpgradeExtractors = directedExtractor.Enabled == true,
            AggressiveExtractorUpgrades = directedExtractor.Aggressive == true,
            ExtractorUpgradeReason = directedExtractor.Reason or 'directed',
        }, cap, inFlight
    end

    local director = GetProductionDirector(aiBrain)
    local techPlan = director and director.TechPlan or false
    if not techPlan then
        return false, 0, 0
    end

    local cap = math.max(0, math.floor((techPlan.ExtractorUpgradeCap or 0) + 0.5))
    local t2Upgrades = GetUnfinishedUnitCount(aiBrain, categories.MASSEXTRACTION * categories.TECH2)
    local t3Upgrades = GetUnfinishedUnitCount(aiBrain, categories.MASSEXTRACTION * categories.TECH3)
    return techPlan, cap, t2Upgrades + t3Upgrades
end

local function IsReadyStructure(unit)
    if not unit or unit.Dead or unit:IsUnitState('Upgrading') then
        return false
    end
    if unit.GetFractionComplete then
        local ok, fraction = pcall(function()
            return unit:GetFractionComplete()
        end)
        if ok and type(fraction) == 'number' then
            return fraction >= 0.95
        end
    end
    return true
end

local function GetExtractorUpgradeCandidateCategory(targetTech)
    if targetTech == 'tech3' or targetTech == 3 then
        return categories.MASSEXTRACTION * categories.TECH2
    end
    return categories.MASSEXTRACTION * categories.TECH1
end

local function HasLocalExtractorUpgradeCandidate(aiBrain, targetTech, radius)
    local mainPos = GetMainPos(aiBrain, 'MAIN')
    if not mainPos then
        return false
    end
    local candidateCategory = GetExtractorUpgradeCandidateCategory(targetTech)
    return GetCompletedUnitCount(aiBrain, candidateCategory, mainPos, radius or 240) > 0
end

local function CountLocalExtractorUpgradeCandidates(aiBrain, targetTech, radius)
    local mainPos = GetMainPos(aiBrain, 'MAIN')
    if not mainPos then
        return 0
    end
    local candidateCategory = GetExtractorUpgradeCandidateCategory(targetTech)
    return GetCompletedUnitCount(aiBrain, candidateCategory, mainPos, radius or 240)
end

local function CountLocalUpgradedExtractors(aiBrain, targetTech, radius)
    local mainPos = GetMainPos(aiBrain, 'MAIN')
    if not mainPos then
        return 0
    end
    local upgradedCategory = categories.MASSEXTRACTION * (((targetTech == 'tech3') or (targetTech == 3)) and categories.TECH3 or categories.TECH2)
    return GetCompletedUnitCount(aiBrain, upgradedCategory, mainPos, radius or 320)
end

local function CountLocalUnfinishedUpgradedExtractors(aiBrain, targetTech, radius)
    local mainPos = GetMainPos(aiBrain, 'MAIN')
    if not mainPos then
        return 0
    end
    local upgradedCategory = categories.MASSEXTRACTION * (((targetTech == 'tech3') or (targetTech == 3)) and categories.TECH3 or categories.TECH2)
    return GetUnfinishedUnitCount(aiBrain, upgradedCategory, mainPos, radius or 320)
end

local function HasRemainingLocalTech2UpgradeWork(aiBrain, radius)
    local localRadius = radius or 360
    return CountLocalExtractorUpgradeCandidates(aiBrain, 'tech2', localRadius) > 0
        or CountLocalUnfinishedUpgradedExtractors(aiBrain, 'tech2', localRadius + 40) > 0
end

local function CanConsolidateLocalTech2Extractors(aiBrain, radius)
    if not IsOvermindBrain(aiBrain) then
        return false
    end

    local localRadius = radius or 320
    if CountLocalExtractorUpgradeCandidates(aiBrain, 'tech2', localRadius) <= 0 then
        return false
    end

    if HasCriticalFactoryTask(aiBrain) or HasCriticalStructureTask(aiBrain) then
        return false
    end
    if IsUnderLandHarass(aiBrain, 1) or IsUnderAirHarass(aiBrain, 1) or IsBomberPanic(aiBrain) or IsExposedMexAirRaid(aiBrain) then
        return false
    end

    local director = GetProductionDirector(aiBrain)
    local runtime = aiBrain.OvermindRuntime or {}
    local current = director and director.Current or {}
    local factories = current.Factories or {}
    local eco = current.Eco or {}
    local structures = current.Structures or {}
    local confidence = director and director.Confidence or {}
    local techPlan = director and director.TechPlan or {}
    local liveEcon = GetEcon(aiBrain)
    local recovery = GetRecovery(aiBrain) or {}
    local raid = runtime.RaidDefense or {}
    local mainPos = GetMainPos(aiBrain, 'MAIN')
    local localRisk = (mainPos and OvermindMemory.GetExpansionRisk(aiBrain, mainPos, 90)) or 0
    local remoteSafeTech2 = CountSafeRemoteExtractorUpgradeCandidates(aiBrain, 'tech2', math.max(localRadius + 40, 380))
    local mapControl = GetZoneMapControl(aiBrain)
    local localT2 = CountLocalUpgradedExtractors(aiBrain, 'tech2', localRadius + 20)
    local unfinishedLocalT2 = CountLocalUnfinishedUpgradedExtractors(aiBrain, 'tech2', localRadius + 40)
    local tempoConsolidation = techPlan.ExtractorUpgradeReason == 'tempo_mode'
    local earlyFactoryFloorMet = ((factories.Land or {}).Ready or 0) >= 1
        and (((eco.Power or {}).Ready) or 0) >= 3
    local safeEconomy = (liveEcon.MassIncome or 0) >= (tempoConsolidation and 1.8 or 2.3)
        and (liveEcon.EnergyIncome or 0) >= (tempoConsolidation and 24 or 28)
        and (liveEcon.EnergyStorageRatio or 0) >= (tempoConsolidation and 0.06 or 0.1)
        and (liveEcon.EnergyTrend or 0) >= (tempoConsolidation and -8 or -4)
        and (liveEcon.MassTrend or 0) >= (tempoConsolidation and -0.32 or -0.2)
    local expansionStalled = remoteSafeTech2 <= 0
        or mapControl < 0.4
        or tempoConsolidation
        or (techPlan.ExtractorUpgradeReason == 'scouting_debt')
        or (confidence.Global or 0) < 0.58
    local localZoneSecure = localRisk <= (tempoConsolidation and 3.1 or 2.6)
        and (raid.LastThreatMexPos == nil or (mainPos and Distance2D(mainPos, raid.LastThreatMexPos) > localRadius + 30))

    if not earlyFactoryFloorMet or not safeEconomy then
        return false
    end
    if recovery.ForceFactoryRecovery or recovery.FactoryQueueExpansionBlocked then
        return false
    end
    if unfinishedLocalT2 >= 1 then
        return true
    end
    if tempoConsolidation and localZoneSecure then
        return true
    end
    if localT2 >= 1 and not expansionStalled then
        return false
    end

    return expansionStalled and localZoneSecure
end

local function CanUpgradeToTech3Extractors(aiBrain, radius)
    if not IsOvermindBrain(aiBrain) then
        return false
    end

    if HasCriticalFactoryTask(aiBrain) or HasCriticalStructureTask(aiBrain) then
        return false
    end
    if IsUnderLandHarass(aiBrain, 1) or IsUnderAirHarass(aiBrain, 1) or IsBomberWatch(aiBrain) or IsBomberPanic(aiBrain) or IsExposedMexAirRaid(aiBrain) then
        return false
    end

    local liveEcon = GetEcon(aiBrain)
    local director = GetProductionDirector(aiBrain)
    local current = director and director.Current or {}
    local factories = current.Factories or {}
    local structures = current.Structures or {}
    local confidence = director and director.Confidence or {}
    local recovery = GetRecovery(aiBrain) or {}
    local localRadius = radius or 360

    if recovery.ForceFactoryRecovery or recovery.FactoryQueueExpansionBlocked then
        return false
    end
    if HasRemainingLocalTech2UpgradeWork(aiBrain, localRadius) then
        return false
    end
    if (structures.Radar or 0) <= 0 then
        return false
    end
    if ((factories.Land or {}).Ready or 0) < 3 then
        return false
    end
    if (((current.Eco or {}).Power or {}).Ready or 0) < 4 then
        return false
    end
    if (confidence.Global or 0) < 0.56 then
        return false
    end
    if (liveEcon.MassStorageRatio or 0) < 0.28 or (liveEcon.EnergyStorageRatio or 0) < 0.36 then
        return false
    end
    if (liveEcon.MassTrend or 0) < 0.01 or (liveEcon.EnergyTrend or 0) < 4 then
        return false
    end
    if (liveEcon.MassIncome or 0) < 5.5 or (liveEcon.EnergyIncome or 0) < 55 then
        return false
    end

    return true
end

CountSafeRemoteExtractorUpgradeCandidates = function(aiBrain, targetTech, minRadius)
    local mainPos = GetMainPos(aiBrain, 'MAIN')
    if not mainPos then
        return 0
    end

    local candidateCategory = GetExtractorUpgradeCandidateCategory(targetTech)
    local raid = (aiBrain.OvermindRuntime and aiBrain.OvermindRuntime.RaidDefense) or {}
    local units = aiBrain:GetListOfUnits(candidateCategory, false, true) or {}
    local count = 0
    local minDist = minRadius or 240

    for _, unit in units do
        if IsReadyStructure(unit) then
            local pos = unit.GetPosition and unit:GetPosition() or false
            if pos and Distance2D(pos, mainPos) > minDist then
                local threat = aiBrain:GetThreatAtPosition(pos, 1, true, 'AntiSurface') or 0
                local enemyRaiders = aiBrain:GetNumUnitsAroundPoint(
                    categories.MOBILE * categories.LAND - categories.ENGINEER - categories.SCOUT - categories.COMMAND,
                    pos,
                    30,
                    'Enemy') or 0
                local expansionRisk = OvermindMemory.GetExpansionRisk(aiBrain, pos, 56)
                local engineerLossRisk = OvermindMemory.GetEngineerLossRisk(aiBrain, pos, 42)
                local threatened = raid.LastThreatMexPos and Distance2D(pos, raid.LastThreatMexPos) < 70
                if threat <= 1.6 and enemyRaiders <= 0 and expansionRisk <= 2.1 and engineerLossRisk <= 2.1 and not threatened then
                    count = count + 1
                end
            end
        end
    end

    return count
end

local function GetACU(aiBrain)
    if not aiBrain then
        return false
    end
    local acu = aiBrain:GetListOfUnits(categories.COMMAND, false, true)
    if acu and table.getn(acu) > 0 and acu[1] and not acu[1].Dead then
        return acu[1]
    end
    return false
end

local function GetACUHealthRatio(aiBrain)
    local acu = GetACU(aiBrain)
    if not acu or not acu.GetHealth or not acu.GetMaxHealth then
        return 1
    end
    local maxHealth = math.max(1, acu:GetMaxHealth() or 1)
    return (acu:GetHealth() or maxHealth) / maxHealth
end

local function GetMapSizeArea()
    if GetMapSize then
        local x, z = GetMapSize()
        if x and z then
            return x * z
        end
    end
    return 262144
end

local function GetDesiredRadarCount(aiBrain)
    local runtime = aiBrain and aiBrain.OvermindRuntime or {}
    local policy = GetPolicy(aiBrain)
    local phase = policy and policy.MacroPhase or 'consolidate'
    local now = GetGameTimeSeconds()
    local area = GetMapSizeArea()
    local desired = (policy and policy.RadarDesiredCap) or 1

    if area >= 524288 and phase ~= 'bootstrap' then
        desired = desired + 1
    end
    if phase == 'pressure' and now >= math.max(600, ((policy and policy.RadarMinTime) or 300) + 180) then
        desired = desired + 1
    end
    if phase == 'tech' and now >= 900 then
        desired = desired + 1
    end
    if runtime and runtime.LastEnemyContactTime and (now - runtime.LastEnemyContactTime) > 150 then
        desired = desired + 1
    end
    if runtime and runtime.ZoneModel and (runtime.ZoneModel.MapControl or 0) >= 0.45 and now >= 600 then
        desired = desired + 1
    end

    return math.max(1, math.min(6, desired))
end

local function IsRadarBuildLocked(aiBrain, now)
    local runtime = aiBrain and aiBrain.OvermindRuntime
    local t = now or GetGameTimeSeconds()
    if not runtime then
        return false
    end
    return (runtime.RadarBuildLockUntil or -999) > t
end

local function IsRadarBuildClaimed(aiBrain, now)
    local runtime = aiBrain and aiBrain.OvermindRuntime
    local t = now or GetGameTimeSeconds()
    if not runtime then
        return false
    end
    return (runtime.RadarBuildClaimUntil or -999) > t
end

local function ClaimRadarBuild(aiBrain, seconds, now)
    local runtime = aiBrain and aiBrain.OvermindRuntime
    local t = now or GetGameTimeSeconds()
    if not runtime then
        return
    end
    runtime.RadarBuildClaimUntil = math.max(runtime.RadarBuildClaimUntil or -999, t + (seconds or 8))
end

local function NormalizeStructureRole(role)
    local normalized = string.lower(role or '')
    if normalized == 'ground' or normalized == 'pd' then
        return 'pd'
    end
    if normalized == 'antiair' or normalized == 'aa' then
        return 'aa'
    end
    if normalized == 'defense' or normalized == 'structure' then
        return 'defense'
    end
    return normalized
end

local function IsStructureBuildClaimed(aiBrain, role, now)
    local runtime = aiBrain and aiBrain.OvermindRuntime
    local t = now or GetGameTimeSeconds()
    if not runtime then
        return false
    end
    local claims = runtime.StructureBuildClaims or {}
    local key = NormalizeStructureRole(role)
    return (claims[key] or -999) > t or ((key == 'pd' or key == 'aa') and (claims.defense or -999) > t)
end

local function ClaimStructureBuild(aiBrain, role, seconds, now)
    local runtime = aiBrain and aiBrain.OvermindRuntime
    local t = now or GetGameTimeSeconds()
    if not runtime then
        return
    end
    runtime.StructureBuildClaims = runtime.StructureBuildClaims or {}
    local key = NormalizeStructureRole(role)
    local untilTime = t + (seconds or 24)
    runtime.StructureBuildClaims[key] = math.max(runtime.StructureBuildClaims[key] or -999, untilTime)
    if key == 'pd' or key == 'aa' or key == 'defense' then
        runtime.StructureBuildClaims.defense = math.max(runtime.StructureBuildClaims.defense or -999, untilTime)
    end
end

local function HasUnfinishedDefenseBuild(aiBrain, role)
    local key = NormalizeStructureRole(role)
    local category = categories.STRUCTURE * categories.DEFENSE * categories.TECH1
    if key == 'pd' then
        category = category * categories.DIRECTFIRE - categories.ANTIAIR
    elseif key == 'aa' then
        category = category * categories.ANTIAIR
    end
    return GetUnfinishedUnitCount(aiBrain, category) > 0
end

local function IsStructureMassBlocked(aiBrain)
    local econ = GetEcon(aiBrain)
    return (econ.MassTrend or 0) <= -0.18 and (econ.MassStorageRatio or 0) <= 0.24
end

local function NormalizeFactoryDomain(domain)
    local normalized = string.lower(domain or '')
    if normalized == 'sea' or normalized == 'naval' then
        return 'navy'
    end
    if normalized == 'land' or normalized == 'air' or normalized == 'navy' then
        return normalized
    end
    return 'unknown'
end

local function IsFactoryBuildClaimed(aiBrain, domain, now)
    local runtime = aiBrain and aiBrain.OvermindRuntime
    local t = now or GetGameTimeSeconds()
    if not runtime then
        return false
    end
    local claims = runtime.FactoryBuildClaims or {}
    return (claims[NormalizeFactoryDomain(domain)] or -999) > t
end

local function ClaimFactoryBuild(aiBrain, domain, seconds, now)
    local runtime = aiBrain and aiBrain.OvermindRuntime
    local t = now or GetGameTimeSeconds()
    if not runtime then
        return
    end
    runtime.FactoryBuildClaims = runtime.FactoryBuildClaims or {}
    local key = NormalizeFactoryDomain(domain)
    runtime.FactoryBuildClaims[key] = math.max(runtime.FactoryBuildClaims[key] or -999, t + (seconds or 12))
end

local function ShouldBypassGenericFirstRadar(aiBrain)
    local director = GetProductionDirector(aiBrain)
    local structurePlan = director and director.StructurePlan or {}
    local current = director and director.Current or {}
    local structures = current and current.Structures or {}
    local constraints = director and director.ConstraintState or {}
    local completeRadar = GetCompletedUnitCount(aiBrain, categories.STRUCTURE * categories.RADAR * categories.TECH1)
    if completeRadar > 0 then
        return false
    end
    return constraints.StarterRadarRequired == true
        or ((structurePlan.Radar or 0) > (structures.Radar or 0))
        or (structurePlan.RadarCritical == true and (structurePlan.Radar or 0) > 0)
end

Distance2D = function(a, b)
    local dx = (a[1] or 0) - (b[1] or 0)
    local dz = (a[3] or 0) - (b[3] or 0)
    return math.sqrt((dx * dx) + (dz * dz))
end

GetMainPos = function(aiBrain, locationType)
    if not aiBrain then
        return false
    end

    local locType = locationType or 'MAIN'
    if aiBrain.BuilderManagers
        and aiBrain.BuilderManagers[locType]
        and aiBrain.BuilderManagers[locType].FactoryManager
        and aiBrain.BuilderManagers[locType].FactoryManager.GetLocationCoords then
        local pos = aiBrain.BuilderManagers[locType].FactoryManager:GetLocationCoords()
        if pos then
            return pos
        end
    end

    if aiBrain.BuilderManagers and aiBrain.BuilderManagers.MAIN and aiBrain.BuilderManagers.MAIN.Position then
        return aiBrain.BuilderManagers.MAIN.Position
    end

    if aiBrain.OvermindRuntime and aiBrain.OvermindRuntime.ZoneModel and aiBrain.OvermindRuntime.ZoneModel.OwnMainPos then
        return aiBrain.OvermindRuntime.ZoneModel.OwnMainPos
    end

    local sx, sz = aiBrain:GetArmyStartPos()
    return { sx, 0, sz }
end

local function IsPrimaryLocation(aiBrain, locationType, maxDist)
    if not locationType then
        return true
    end

    local loc = string.upper(tostring(locationType))
    if loc == 'MAIN' then
        return true
    end

    local mainPos = GetMainPos(aiBrain, 'MAIN')
    local otherPos = GetMainPos(aiBrain, locationType)
    if not mainPos or not otherPos then
        return false
    end

    local distance = Distance2D(mainPos, otherPos)
    return distance <= (maxDist or 42)
end

function HasNoUnfinishedFactoriesAtLocation(aiBrain, locationType, radius, maxAllowed)
    if not IsOvermindBrain(aiBrain) then
        return true
    end

    local pos = GetMainPos(aiBrain, locationType or 'MAIN')
    local checkRadius = radius or 180
    local allowed = maxAllowed or 0
    local unfinished = GetUnfinishedUnitCount(aiBrain, categories.FACTORY * categories.STRUCTURE, pos, checkRadius)
    return unfinished <= allowed
end

local function GetPrimaryEnemyPos(aiBrain)
    if not aiBrain or not aiBrain.OvermindRuntime then
        return false
    end

    local runtime = aiBrain.OvermindRuntime
    if runtime.PrimaryEnemyPos then
        return runtime.PrimaryEnemyPos
    end
    if runtime.ZoneModel and runtime.ZoneModel.BestRaidPos then
        return runtime.ZoneModel.BestRaidPos
    end

    return false
end

GetZoneMapControl = function(aiBrain)
    if aiBrain and aiBrain.OvermindRuntime and aiBrain.OvermindRuntime.ZoneModel then
        return aiBrain.OvermindRuntime.ZoneModel.MapControl or 0
    end

    return 0
end

local function GetRelativePower(aiBrain)
    if aiBrain and aiBrain.OvermindRuntime and aiBrain.OvermindRuntime.OpponentModel then
        return aiBrain.OvermindRuntime.OpponentModel.RelativePower or 1
    end

    return 1
end

local function GetPosture(aiBrain)
    if aiBrain and aiBrain.OvermindRuntime and aiBrain.OvermindRuntime.OpponentModel then
        return aiBrain.OvermindRuntime.OpponentModel.Posture or 'balanced'
    end

    return 'balanced'
end

local function GetFactoryCounts(aiBrain)
    local land = GetExistingUnitCount(aiBrain, categories.FACTORY * categories.LAND * categories.STRUCTURE)
    local air = GetExistingUnitCount(aiBrain, categories.FACTORY * categories.AIR * categories.STRUCTURE)
    return land, air
end

local function HasAuthoritativeCapacityPlan(director)
    local capacity = director and director.CapacityPlan or false
    if type(capacity) ~= 'table' then
        return false
    end

    return capacity.AddLandFactory ~= nil
        or capacity.AddAirFactory ~= nil
        or capacity.AddSeaFactory ~= nil
        or capacity.PauseFactoryGrowth ~= nil
        or capacity.LandTarget ~= nil
        or capacity.AirTarget ~= nil
        or capacity.SeaTarget ~= nil
        or capacity.QueueDiscipline ~= nil
end

local function GetAuthoritativeCapacityPlan(aiBrain)
    local director = GetProductionDirector(aiBrain)
    if HasAuthoritativeCapacityPlan(director) then
        return director.CapacityPlan
    end
    return false
end

local function IsFactoryControllerHealthy(aiBrain)
    if not IsOvermindBrain(aiBrain) then
        return false
    end

    local director = GetProductionDirector(aiBrain)
    if not HasAuthoritativeCapacityPlan(director) then
        return false
    end

    local runtime = aiBrain.OvermindRuntime or {}
    local ctrl = runtime.FactoryController or {}
    local recovery = GetRecovery(aiBrain) or {}
    local now = GetGameTimeSeconds()

    if (ctrl.LastUpdate or -999) < (now - 18) then
        return false
    end
    if recovery.FactoryQueueInvariantBroken or recovery.ForceFactoryDeadlock then
        return false
    end

    return true
end

function ShouldUseLegacyFactoryProduction(aiBrain, mode)
    if not IsOvermindBrain(aiBrain) then
        return false
    end

    local recovery = GetRecovery(aiBrain) or {}
    if not IsFactoryControllerHealthy(aiBrain) then
        return true
    end

    local lowerMode = string.lower(mode or 'production')
    if lowerMode == 'deadlock' then
        return recovery.ForceFactoryDeadlock
            or (((recovery.FactoryAnyQueueStarvationTime or 0) >= 25) and ((recovery.FactoryQueueDeficit or 0) >= 1))
    elseif lowerMode == 'recovery' then
        return recovery.ForceFactoryRecovery
            or recovery.ForceScoutRecovery
            or recovery.FactoryQueueInvariantBroken
            or (((recovery.FactoryQueueDeficitRatio or 0) >= 0.25) and ((recovery.FactoryQueueStarvationTime or 0) >= 12))
    elseif lowerMode == 'emergency' then
        return recovery.ForceFactoryRecovery
            or recovery.ForceFactoryLand
            or recovery.ForceFactoryAir
            or recovery.ForceFactoryDeadlock
            or recovery.FactoryQueueInvariantBroken
    end

    return false
end

local function IsFactoryExpansionEcoBlocked(aiBrain, landFactories, airFactories, seaFactories)
    local econ = GetEcon(aiBrain)
    local recovery = GetRecovery(aiBrain) or {}
    local total = (landFactories or 0) + (airFactories or 0) + (seaFactories or 0)
    if total <= 2 then
        return false
    end

    if (econ.MassStorageRatio or 0) <= 0.06 and (econ.MassTrend or 0) <= -0.08 then
        return true
    end

    if total >= 4
        and (econ.MassStorageRatio or 0) <= 0.12
        and (econ.MassIncome or 0) <= 3.6
        and (econ.MassTrend or 0) <= -0.02 then
        return true
    end

    if (recovery.StagnationTime or 0) >= 100 and total >= 3 then
        return true
    end

    return false
end

local function HasSecondLandFactoryBootstrapDebt(aiBrain, capacity, domain)
    local normalized = string.lower(domain or '')
    if normalized ~= 'land' then
        return false
    end

    local now = GetGameTimeSeconds()
    if now > 600 then
        return false
    end

    local landFactories = GetExistingUnitCount(aiBrain, categories.FACTORY * categories.LAND * categories.STRUCTURE)
    local readyLandFactories = GetCompletedUnitCount(aiBrain, categories.FACTORY * categories.LAND * categories.STRUCTURE)
    if readyLandFactories < 1 or landFactories >= 2 then
        return false
    end

    local activeCapacity = capacity or GetAuthoritativeCapacityPlan(aiBrain)
    if activeCapacity and type(activeCapacity) == 'table' then
        local target = activeCapacity.LandTarget or 0
        if target < 2 and activeCapacity.AddLandFactory ~= true then
            return false
        end
    end

    local readyMex = GetCompletedUnitCount(aiBrain, categories.MASSEXTRACTION * categories.STRUCTURE)
    local readyPower = GetCompletedUnitCount(aiBrain, categories.ENERGYPRODUCTION * categories.STRUCTURE)
    if readyMex < 4 or readyPower < 2 then
        return false
    end

    local econ = GetEcon(aiBrain)
    local severeEnergyCrash = (econ.EnergyStorageRatio or 0) <= 0.01 and (econ.EnergyTrend or 0) <= -30
    return not severeEnergyCrash
end

local function IsFactoryGrowthHardBlocked(aiBrain, capacity, domain)
    if HasCriticalFactoryTask(aiBrain, domain) then
        return true
    end

    local activeCapacity = capacity or GetAuthoritativeCapacityPlan(aiBrain)
    local secondLandBootstrapDebt = HasSecondLandFactoryBootstrapDebt(aiBrain, activeCapacity, domain)
    if activeCapacity then
        if activeCapacity.PauseFactoryGrowth == true or activeCapacity.FactoryCompletionLock == true then
            if not secondLandBootstrapDebt then
                return true
            end
        end
    end

    local recovery = GetRecovery(aiBrain) or {}
    if recovery.FactoryQueueExpansionBlocked or recovery.ForceFactoryDeadlock then
        return true
    end

    local landFactories = GetExistingUnitCount(aiBrain, categories.FACTORY * categories.LAND * categories.STRUCTURE)
    local airFactories = GetExistingUnitCount(aiBrain, categories.FACTORY * categories.AIR * categories.STRUCTURE)
    local seaFactories = GetExistingUnitCount(aiBrain, categories.FACTORY * categories.NAVAL * categories.STRUCTURE)
    local totalFactories = landFactories + airFactories + seaFactories
    local unfinishedFactories = GetUnfinishedUnitCount(aiBrain, categories.FACTORY * categories.STRUCTURE)
    if IsFirstHQPriorityState(aiBrain, 3) and totalFactories >= 3 then
        return true
    end

    local readyMex = GetCompletedUnitCount(aiBrain, categories.MASSEXTRACTION * categories.STRUCTURE)
    local readyT2Mex = GetCompletedUnitCount(aiBrain, categories.MASSEXTRACTION * categories.STRUCTURE * (categories.TECH2 + categories.TECH3))
    local supportedFactoryCap = math.max(3, math.floor((readyMex or 0) * 0.75) + ((readyT2Mex > 0) and 1 or 0))
    supportedFactoryCap = math.min(8, supportedFactoryCap)
    if totalFactories >= supportedFactoryCap and not MassOverflowRisk(aiBrain, 0.92, 0.28) then
        return true
    end

    local unfinishedCap = recovery.ForceFactoryRecovery and 1 or 0
    if unfinishedFactories > unfinishedCap then
        return true
    end

    if IsFactoryExpansionEcoBlocked(aiBrain, landFactories, airFactories, seaFactories) then
        return true
    end

    local now = GetGameTimeSeconds()
    local phaseFactoryCap = 6
    if now >= 720 then
        phaseFactoryCap = 7
    end
    if now >= 1320 then
        phaseFactoryCap = 8
    end
    if now >= 2100 then
        phaseFactoryCap = 10
    end
    if now >= 3000 then
        phaseFactoryCap = 12
    end
    if recovery.ForceFactoryRecovery then
        phaseFactoryCap = phaseFactoryCap + 1
    end
    if totalFactories >= phaseFactoryCap and not MassOverflowRisk(aiBrain, 0.96, 0.45) then
        return true
    end

    local econ = GetEcon(aiBrain)
    local massStorageRatio = econ.MassStorageRatio or 0
    local massTrend = econ.MassTrend or 0
    local massIncome = econ.MassIncome or 0
    local severeMassDeficit = totalFactories >= 4
        and massStorageRatio <= 0.24
        and massTrend <= -0.08
        and massIncome <= math.max(4.8, totalFactories * 0.9)
    local deepMassDeficit = totalFactories >= 3
        and (
            (massStorageRatio <= 0.12 and massTrend <= -0.12)
            or (massTrend <= -0.24)
        )

    return severeMassDeficit or deepMassDeficit
end

local function IsFactoryCapacityOvershoot(capacity, domain, landFactories, airFactories, seaFactories)
    if type(capacity) ~= 'table' then
        return false
    end

    local land = landFactories or 0
    local air = airFactories or 0
    local sea = seaFactories or 0
    local total = land + air + sea

    local desiredTotal = capacity.DesiredTotal
    local hasExplicitTargets = capacity.LandTarget ~= nil or capacity.AirTarget ~= nil or capacity.SeaTarget ~= nil
    if desiredTotal == nil and hasExplicitTargets then
        desiredTotal = (capacity.LandTarget or land) + (capacity.AirTarget or air) + (capacity.SeaTarget or sea)
    end
    if desiredTotal ~= nil and total >= desiredTotal then
        return true
    end

    if not domain then
        return false
    end

    local normalized = string.lower(domain or '')
    if normalized == 'sea' or normalized == 'naval' then
        normalized = 'navy'
    end

    if normalized == 'land' then
        return capacity.LandTarget ~= nil and land >= (capacity.LandTarget or 0)
    elseif normalized == 'air' then
        return capacity.AirTarget ~= nil and air >= (capacity.AirTarget or 0)
    elseif normalized == 'navy' then
        return capacity.SeaTarget ~= nil and sea >= (capacity.SeaTarget or 0)
    end

    return false
end

local function ApproveFactoryBuildRequest(aiBrain, domain)
    local runtime = aiBrain and aiBrain.OvermindRuntime or false
    if not runtime then
        return true
    end

    local now = GetGameTimeSeconds()
    if IsFactoryBuildClaimed(aiBrain, domain, now) then
        return false
    end

    local capacity = GetAuthoritativeCapacityPlan(aiBrain)
    local hasLandHQ = GetCompletedUnitCount(aiBrain, categories.FACTORY * categories.LAND * categories.STRUCTURE * (categories.TECH2 + categories.TECH3)) > 0
    local firstHQPriority = IsFirstHQPriorityState(aiBrain, 3)
    local recovery = GetRecovery(aiBrain) or {}
    if capacity and not HasCriticalFactoryTask(aiBrain, domain) then
        local landFactories = GetExistingUnitCount(aiBrain, categories.FACTORY * categories.LAND * categories.STRUCTURE)
        local airFactories = GetExistingUnitCount(aiBrain, categories.FACTORY * categories.AIR * categories.STRUCTURE)
        local seaFactories = GetExistingUnitCount(aiBrain, categories.FACTORY * categories.NAVAL * categories.STRUCTURE)
        if IsFactoryCapacityOvershoot(capacity, domain, landFactories, airFactories, seaFactories) then
            return false
        end
        local totalFactories = landFactories + airFactories + seaFactories
        if firstHQPriority and totalFactories >= 3 then
            return false
        end
        local preHQCap = recovery.ForceFactoryRecovery and 5 or 4
        if not hasLandHQ and totalFactories >= preHQCap then
            return false
        end
    end

    local gate = runtime.FactoryBuildGate or {}
    runtime.FactoryBuildGate = gate
    local totalFactories = GetExistingUnitCount(aiBrain, categories.FACTORY * categories.STRUCTURE)
    if firstHQPriority and totalFactories >= 3 and not HasCriticalFactoryTask(aiBrain, domain) then
        return false
    end
    local strictCap = hasLandHQ and 5 or 4
    if now >= 720 then
        strictCap = hasLandHQ and 7 or 5
    end
    if now >= 1320 then
        strictCap = 8
    end
    if now >= 2100 then
        strictCap = 10
    end
    if now >= 3000 then
        strictCap = 12
    end
    if totalFactories >= strictCap and not HasCriticalFactoryTask(aiBrain, domain) then
        return false
    end

    if (gate.LockUntil or -999) > now then
        return false
    end

    local cooldown = 18
    if now < 420 then
        cooldown = 6
    elseif now < 1200 then
        cooldown = 14
    end
    if now < 420 then
        cooldown = 34
    elseif now < 720 then
        cooldown = 28
    elseif now < 1200 then
        cooldown = 22
    end
    if HasRecoveryFlag(aiBrain, 'ForceFactoryRecovery') or HasCriticalFactoryTask(aiBrain, domain) then
        cooldown = math.min(cooldown, now < 420 and 24 or 14)
    end

    gate.LockUntil = now + cooldown
    gate.LastIssueTime = now
    gate.LastDomain = domain or 'any'
    ClaimFactoryBuild(aiBrain, domain, cooldown + 4, now)

    return true
end

local function IsSecondaryExpansionReady(aiBrain, recovery, now, econ, factoryCount)
    local activeRecovery = recovery or GetRecovery(aiBrain) or {}
    local activeEcon = econ or GetEcon(aiBrain)
    local facCount = factoryCount or GetExistingUnitCount(aiBrain, categories.FACTORY * categories.STRUCTURE)

    local queueDeficitRatio = activeRecovery.FactoryQueueDeficitRatio or 1
    local queueStarvation = activeRecovery.FactoryQueueStarvationTime or 999
    local queueBlocked = activeRecovery.FactoryQueueExpansionBlocked
        or (queueDeficitRatio >= 0.34 and queueStarvation >= 10)
    local queueUptime = activeRecovery.FactoryQueueUptime or (1 - math.min(1, queueDeficitRatio))

    local runtime = aiBrain.OvermindRuntime or {}
    local ctrl = runtime.FactoryController or {}
    local idleFactories = ctrl.LastIdleCount or 0

    return (now or GetGameTimeSeconds()) >= 1080
        and facCount >= 6
        and (activeEcon.MassIncome or 0) >= 9
        and (activeEcon.EnergyIncome or 0) >= 260
        and (activeEcon.MassStorageRatio or 0) >= 0.38
        and (activeEcon.EnergyStorageRatio or 0) >= 0.42
        and (activeEcon.MassTrend or 0) >= 0.24
        and (activeEcon.EnergyTrend or 0) >= 18
        and GetZoneMapControl(aiBrain) >= 0.42
        and GetRelativePower(aiBrain) >= 1.02
        and not queueBlocked
        and queueDeficitRatio <= 0.14
        and queueStarvation <= 5
        and queueUptime >= 0.82
        and idleFactories <= 2
end

local function IsOvermindPersonality(personality)
    if not personality then
        return false
    end

    return string.find(string.lower(personality), 'overmind') ~= nil
end

function IsOvermindBrain(aiBrain)
    if not aiBrain then
        return false
    end

    if aiBrain.OvermindAI then
        return true
    end

    if aiBrain.Personality and IsOvermindPersonality(aiBrain.Personality) then
        return true
    end

    if aiBrain.Name and ScenarioInfo and ScenarioInfo.ArmySetup and ScenarioInfo.ArmySetup[aiBrain.Name] then
        return IsOvermindPersonality(ScenarioInfo.ArmySetup[aiBrain.Name].AIPersonality)
    end

    return false
end

function InOpeningPhase(aiBrain, untilTime)
    if not IsOvermindBrain(aiBrain) then
        return false
    end

    local policy = GetPolicy(aiBrain)
    local endTime = untilTime or (policy and policy.OpeningLockTime) or 420
    return GetGameTimeSeconds() <= endTime
end

function HasEngineerReserve(aiBrain, locationType, minEngineers)
    if not IsOvermindBrain(aiBrain) then
        return false
    end

    if not aiBrain.BuilderManagers or not aiBrain.BuilderManagers[locationType] or not aiBrain.BuilderManagers[locationType].EngineerManager then
        return false
    end

    local policy = GetPolicy(aiBrain)
    local required = minEngineers or (policy and policy.EngineerReserveMin) or 4
    local engineerCount = aiBrain.BuilderManagers[locationType].EngineerManager:GetNumCategoryUnits('Engineers', categories.ENGINEER) or 0
    return engineerCount >= required
end

function HasBaseEngineerCoverage(aiBrain, locationType, minBaseEngineers, radius)
    if not IsOvermindBrain(aiBrain) then
        return false
    end

    local policy = GetPolicy(aiBrain)
    local tune = GetAutoTune(aiBrain)
    local required = minBaseEngineers or (policy and policy.BaseEngineerFloor) or 3
    required = math.max(required, (tune and tune.BaseEngineerFloorMin) or 3)
    local now = GetGameTimeSeconds()
    if now < 300 then
        required = math.max(1, required - 1)
    end
    local checkRadius = radius or 80
    local basePos = GetMainPos(aiBrain, locationType)
    if not basePos then
        return false
    end

    local totalEngineers = GetUnitCount(aiBrain, categories.ENGINEER * categories.MOBILE)
    if totalEngineers <= (required + 1) then
        return true
    end

    if HasRecoveryFlag(aiBrain, 'ForceBaseEngineerRecovery') and totalEngineers >= required then
        return false
    end

    local baseEngineers = aiBrain:GetNumUnitsAroundPoint(categories.ENGINEER * categories.MOBILE, basePos, checkRadius, 'Ally') or 0
    return baseEngineers >= required
end

function HasMilitaryAdvantage(aiBrain, minRelativePower, minMobile)
    if not IsOvermindBrain(aiBrain) then
        return false
    end

    local relativePower = GetRelativePower(aiBrain)
    local mobile = aiBrain:GetCurrentUnits(categories.MOBILE * (categories.LAND + categories.AIR) - categories.ENGINEER - categories.SCOUT - categories.COMMAND) or 0
    local needPower = minRelativePower or 0.98
    local needMobile = minMobile or 24
    return relativePower >= needPower and mobile >= needMobile
end

function ShouldDoFarExpansion(aiBrain, locationType, minGameTime, minControl, minRelativePower, minMobile, minBaseEngineers)
    if not IsOvermindBrain(aiBrain) then
        return false
    end

    local policy = GetPolicy(aiBrain)
    local now = GetGameTimeSeconds()
    local needTime = minGameTime or (policy and policy.FarExpandMinTime) or 420
    local needControl = minControl or (policy and policy.FarExpandMinControl) or 0.3
    local needPower = minRelativePower or (policy and policy.FarExpandMinRelativePower) or 0.95
    local needMobile = minMobile or (policy and policy.FarExpandMinArmy) or 26
    local needBaseEngineers = minBaseEngineers or (policy and policy.BaseEngineerFloor) or 3
    local recovery = GetRecovery(aiBrain)

    if now < needTime then
        return false
    end

    if (recovery and recovery.ForceBaseEngineerRecovery) or IsProductionStagnating(aiBrain, 85) then
        return false
    end

    if GetZoneMapControl(aiBrain) < needControl then
        return false
    end

    if not HasMilitaryAdvantage(aiBrain, needPower, needMobile) then
        return false
    end

    if not HasBaseEngineerCoverage(aiBrain, locationType, needBaseEngineers, 80) then
        return false
    end

    return true
end

function CanReclaimSafely(aiBrain, locationType, maxThreat, minRelativePower, maxHotspotRisk)
    if not IsOvermindBrain(aiBrain) then
        return false
    end

    local policy = GetPolicy(aiBrain)
    local threatCap = maxThreat or (policy and policy.SafeExpandThreatCap) or 1.0
    local needPower = minRelativePower or 0.95
    local riskCap = maxHotspotRisk or (policy and policy.SafeExpandHotspotCap) or 8
    local basePos = GetMainPos(aiBrain, locationType)
    if not basePos then
        return false
    end

    local localThreat = aiBrain:GetThreatAtPosition(basePos, 2, true, 'AntiSurface') or 0
    local localRisk = OvermindMemory.GetExpansionRisk(aiBrain, basePos, 90)
    local relativePower = GetRelativePower(aiBrain)

    if localThreat > (threatCap * 2.1) and relativePower < (needPower + 0.06) then
        return false
    end

    if localRisk > (riskCap * 1.2) and relativePower < (needPower + 0.08) then
        return false
    end

    return true
end

local function HasUnclaimedNearbyMassMarker(aiBrain, locationType, maxDistance, maxThreat)
    local basePos = GetMainPos(aiBrain, locationType)
    if not basePos then
        return false
    end

    local markerTable = AIUtils.AIGetMarkerLocations(aiBrain, 'Mass')
    if not markerTable or table.getn(markerTable) <= 0 then
        return false
    end

    local distanceCap = maxDistance or 300
    local threatCap = maxThreat or 1.2
    local mexCategory = categories.STRUCTURE * categories.MASSEXTRACTION

    for _, marker in markerTable do
        local markerPos = marker and marker.Position
        if markerPos and Distance2D(basePos, markerPos) <= distanceCap then
            local allyMex = aiBrain:GetNumUnitsAroundPoint(mexCategory, markerPos, 2.0, 'Ally') or 0
            local enemyMex = aiBrain:GetNumUnitsAroundPoint(mexCategory, markerPos, 2.0, 'Enemy') or 0
            if allyMex <= 0 and enemyMex <= 0 then
                local threat = aiBrain:GetThreatAtPosition(markerPos, 1, true, 'AntiSurface') or 0
                if threat <= threatCap then
                    return true
                end
            end
        end
    end

    return false
end

function ShouldRunReclaimPressure(aiBrain, locationType, minGameTime, massMarkerRadius)
    if not IsOvermindBrain(aiBrain) then
        return false
    end

    local now = GetGameTimeSeconds()
    if now < math.max(minGameTime or 300, 900) then
        return false
    end

    local econ = GetEcon(aiBrain)
    local recovery = GetRecovery(aiBrain) or {}
    local director = GetProductionDirector(aiBrain) or {}
    local constraints = director.ConstraintState or {}
    local queueBlocked = recovery.FactoryQueueExpansionBlocked
        or (((recovery.FactoryQueueDeficitRatio or 0) >= 0.26) and ((recovery.FactoryQueueStarvationTime or 0) >= 8))

    -- During factory queue starvation we want engineers spending on build power / mex, not trees.
    if queueBlocked then
        return false
    end

    if HasCriticalFactoryTask(aiBrain) or HasCriticalStructureTask(aiBrain) then
        return false
    end

    if HasPendingExpansionWork(aiBrain) then
        return false
    end

    if constraints.EconBootstrap == true or constraints.StarterPhase == true then
        return false
    end

    if ShouldBypassGenericFirstRadar(aiBrain) then
        return false
    end

    if IsBomberWatch(aiBrain) or IsBomberPanic(aiBrain) or IsExposedMexAirRaid(aiBrain) then
        return false
    end

    -- In dual-crash states reclaim pressure often causes walk-time churn; stabilize first.
    if (econ.MassTrend or 0) <= -0.16 and (econ.EnergyTrend or 0) <= -12 then
        return false
    end

    if (econ.EnergyStorageRatio or 0) < 0.22 or (econ.EnergyTrend or 0) < 2 then
        return false
    end

    if (econ.MassStorageRatio or 0) < 0.18 or (econ.MassTrend or 0) < -0.02 then
        return false
    end

    local readyFactories = GetCompletedUnitCount(aiBrain, categories.FACTORY * categories.STRUCTURE)
    if readyFactories < 2 then
        return false
    end

    if not HasEngineerReserve(aiBrain, locationType, 7) or not HasBaseEngineerCoverage(aiBrain, locationType, 4, 90) then
        return false
    end

    local searchRadius = massMarkerRadius or 320
    if HasUnclaimedNearbyMassMarker(aiBrain, locationType, math.max(searchRadius, 420), 1.6) then
        return false
    end

    return true
end

function CanSafelyExpand(aiBrain, locationType, maxDistance, maxThreat, enemyBuffer, hotspotRiskCap)
    if not IsOvermindBrain(aiBrain) then
        return false
    end

    local policy = GetPolicy(aiBrain)
    local tune = GetAutoTune(aiBrain)
    local searchDistance = maxDistance or (policy and policy.SafeExpandDistance) or 560
    local threatCap = maxThreat or (policy and policy.SafeExpandThreatCap) or 0.8
    local enemyBias = enemyBuffer or (policy and policy.SafeExpandEnemyBuffer) or 80
    local maxRisk = hotspotRiskCap or (policy and policy.SafeExpandHotspotCap) or 7
    maxRisk = maxRisk + ((tune and tune.SafeExpandHotspotCapBias) or 0)

    local basePos = GetMainPos(aiBrain, locationType)
    if not basePos then
        return false
    end

    local enemyPos = GetPrimaryEnemyPos(aiBrain)
    local runtime = aiBrain.OvermindRuntime or {}
    local raid = runtime.RaidDefense or {}
    local relativePower = GetRelativePower(aiBrain)
    local escortReserve = aiBrain:GetNumUnitsAroundPoint(
        categories.MOBILE * (categories.LAND + categories.AIR) - categories.ENGINEER - categories.SCOUT - categories.COMMAND,
        basePos,
        95,
        'Ally') or 0
    local escortAvailable = escortReserve >= 7 and relativePower >= 0.92 and not (raid.UnderLandHarass or raid.UnderAirHarass)
    local markerTable = AIUtils.AIGetSortedMassLocations(aiBrain, 12, -500, threatCap, 1, 'AntiSurface', basePos)
    if not markerTable or table.getn(markerTable) == 0 then
        return false
    end

    local bestScore = -9999
    local bestPos = false
    local bestRisk = 0
    local bestRouteRisk = 0

    for _, markerPos in markerTable do
        local distBase = Distance2D(basePos, markerPos)
        if distBase <= searchDistance then
            local enemySafe = true
            if enemyPos then
                local distEnemy = Distance2D(enemyPos, markerPos)
                if distEnemy + enemyBias < distBase then
                    enemySafe = false
                elseif distEnemy < distBase and not escortAvailable then
                    enemySafe = false
                end
            end

            if enemySafe then
                local risk = OvermindMemory.GetExpansionRisk(aiBrain, markerPos, 60)
                local routeRisk = OvermindMemory.GetRouteRisk(aiBrain, basePos, markerPos, 5, 56)
                local blacklisted = OvermindMemory.IsRouteBlacklisted(aiBrain, markerPos, 64, maxRisk * 0.9)
                local threat = aiBrain:GetThreatAtPosition(markerPos, 1, true, 'AntiSurface') or 0
                local distScore = (searchDistance - distBase) / math.max(1, searchDistance)
                local score = (distScore * 6) - (threat * 1.2) - (risk * 0.7) - (routeRisk * 0.8)

                if blacklisted and distBase > (searchDistance * 0.45) then
                    score = score - 2.5
                end

                if distBase > (searchDistance * 0.65) and routeRisk > (maxRisk * 0.95) then
                    score = score - 2
                end

                if risk <= (maxRisk * 1.15) and score > bestScore then
                    bestScore = score
                    bestPos = markerPos
                    bestRisk = risk
                    bestRouteRisk = routeRisk
                end
            end
        end
    end

    if aiBrain and aiBrain.OvermindRuntime then
        aiBrain.OvermindRuntime.LastExpansionCandidatePos = bestPos
        aiBrain.OvermindRuntime.LastExpansionCandidateScore = bestScore
        aiBrain.OvermindRuntime.LastExpansionCandidateRisk = bestRisk
        aiBrain.OvermindRuntime.LastExpansionRouteRisk = bestRouteRisk
    end

    return bestPos ~= false and bestScore > -0.8 and bestRisk <= (maxRisk * 1.2)
end

function NeedsEnergyNow(aiBrain, maxEnergyRatio, maxEnergyTrend)
    if not IsOvermindBrain(aiBrain) then
        return false
    end

    local econ = GetEcon(aiBrain)
    local policy = GetPolicy(aiBrain)
    local ratio = maxEnergyRatio or (policy and policy.EnergyNeedRatio) or 0.4
    local trend = maxEnergyTrend or (policy and policy.EnergyNeedTrend) or -2

    return econ.EnergyStorageRatio <= ratio or econ.EnergyTrend <= trend
end

function IsMassStarved(aiBrain, maxMassRatio, maxMassTrend, maxMassIncome)
    if not IsOvermindBrain(aiBrain) then
        return false
    end

    local econ = GetEcon(aiBrain)
    local ratio = maxMassRatio or 0.35
    local trend = maxMassTrend or -0.02
    local income = maxMassIncome or 2.5

    local ratioBad = econ.MassStorageRatio <= ratio
    local trendBad = econ.MassTrend <= trend
    local incomeBad = econ.MassIncome <= income

    -- Avoid over-triggering reclaim behavior on a single noisy signal.
    if ratioBad and (trendBad or incomeBad) then
        return true
    end

    if trendBad and incomeBad then
        return true
    end

    return false
end

function ShouldBuildPower(aiBrain, maxEnergyRatio, maxEnergyTrend, maxMassRatioForExtraPower)
    if not IsOvermindBrain(aiBrain) then
        return false
    end

    local econ = GetEcon(aiBrain)
    local policy = GetPolicy(aiBrain)
    local ratio = maxEnergyRatio or (policy and policy.EnergyNeedRatio) or 0.42
    local trend = maxEnergyTrend or (policy and policy.EnergyNeedTrend) or -3
    local massRatio = maxMassRatioForExtraPower or 0.6
    local mexCount = GetUnitCount(aiBrain, categories.MASSEXTRACTION * categories.STRUCTURE)
    local mexReady = GetCompletedUnitCount(aiBrain, categories.MASSEXTRACTION * categories.STRUCTURE)
    local pgenCount = GetUnitCount(aiBrain, categories.ENERGYPRODUCTION * categories.STRUCTURE)
    local pgenReady = GetCompletedUnitCount(aiBrain, categories.ENERGYPRODUCTION * categories.STRUCTURE)
    local pendingPgens = math.max(0, pgenCount - pgenReady)
    local factoryCount = GetExistingUnitCount(aiBrain, categories.FACTORY * categories.STRUCTURE)
    local now = GetGameTimeSeconds()
    local maxPgenPerMex = (policy and policy.PgenPerMexCap) or 1.85
    local hardStopEnergyRatio = (policy and policy.PowerHardStopEnergyRatio) or 0.58
    local hardStopEnergyTrend = (policy and policy.PowerHardStopEnergyTrend) or 18
    local hardStopMassRatio = (policy and policy.PowerHardStopMassRatio) or 0.78
    local maxEnergyRatioCap = (policy and policy.PowerMaxEnergyRatio) or 0.85
    local maxEnergyTrendCap = (policy and policy.PowerMaxEnergyTrend) or 35
    local forceFactoryRecovery = HasRecoveryFlag(aiBrain, 'ForceFactoryRecovery')
    local recovery = GetRecovery(aiBrain) or {}

    if mexCount < 1 then
        mexCount = 1
    end

    local director = GetProductionDirector(aiBrain)
    local constraints = director and director.ConstraintState or {}
    local severeEnergyCrisis = (econ.EnergyStorageRatio or 0) <= 0.08 or (econ.EnergyTrend or 0) <= -28
    local bootstrapLike = IsEconomyBootstrapState(aiBrain) or IsStarterPhaseState(aiBrain)

    if now < 420 and not severeEnergyCrisis then
        local earlyCap = 4
        if now < 180 then
            earlyCap = math.max(2, math.min(3, mexReady + 1))
        elseif now < 300 then
            earlyCap = math.max(3, math.min(4, mexReady))
        else
            earlyCap = math.max(4, math.min(6, mexReady + 1))
        end
        if factoryCount >= 3 then
            earlyCap = earlyCap + 1
        end
        if pgenCount >= earlyCap
            and (econ.EnergyStorageRatio or 0) >= 0.035
            and (econ.EnergyTrend or 0) >= -18 then
            return false
        end
        if now < 300
            and pendingPgens >= 1
            and pgenReady >= 2
            and (econ.EnergyStorageRatio or 0) >= 0.025
            and (econ.EnergyTrend or 0) >= -24 then
            return false
        end
    end

    if constraints.PowerBufferLow == true then
        if now < 520 and not severeEnergyCrisis then
            local bufferCap = mexReady + 2
            if factoryCount <= 1 then
                bufferCap = math.max(2, mexReady + 1)
            end
            bufferCap = math.max(3, math.min(7, bufferCap))
            if pgenCount >= bufferCap
                and (econ.EnergyStorageRatio or 0) >= 0.03
                and (econ.EnergyTrend or 0) >= -20 then
                return false
            end
        end
        return true
    end
    if IsEconomyBootstrapState(aiBrain) or IsStarterPhaseState(aiBrain) then
        local bootstrapPowerFloor = constraints.StarterPowerFloor or constraints.BootstrapPowerFloor or ((factoryCount <= 1) and 1 or 2)
        if pgenReady < bootstrapPowerFloor then
            return true
        end
        if pgenCount < bootstrapPowerFloor and ((econ.EnergyIncome or 0) < 70 or (econ.EnergyTrend or 0) < 6) then
            return true
        end
        if now < 260
            and mexReady < 4
            and pgenReady >= math.max(2, bootstrapPowerFloor)
            and (econ.EnergyTrend or 0) >= -24
            and (econ.EnergyStorageRatio or 0) >= 0.025 then
            return false
        end
    end

    if not severeEnergyCrisis then
        local pendingCap = bootstrapLike and 2 or 3
        if pendingPgens >= pendingCap then
            return false
        end
        if pendingPgens >= 2
            and mexCount <= math.max(2, pgenReady + 1)
            and econ.EnergyStorageRatio >= 0.08
            and econ.EnergyTrend >= -14 then
            return false
        end
    end
    if now < 780 and not severeEnergyCrisis then
        local extraAllowance = 3
        if factoryCount >= 3 then
            extraAllowance = 4
        end
        local softCap = mexCount + extraAllowance
        if pgenCount >= softCap
            and econ.EnergyStorageRatio >= 0.18
            and econ.EnergyTrend >= -8
            and econ.MassStorageRatio <= 0.9 then
            return false
        end
    end

    if now < 960 and factoryCount >= 1 and mexCount >= 5 then
        local desiredReady = (constraints.PowerDesiredReady or math.max(2, math.min(6, math.ceil(mexCount / 2.5))))
        if pgenReady < desiredReady then
            return true
        end
        if (econ.EnergyStorageRatio or 0) < 0.2 or (econ.EnergyTrend or 0) < 4 then
            return true
        end
    end

    if factoryCount >= 1
        and mexCount >= 4
        and pgenCount < (mexCount + 3)
        and (econ.MassStorageRatio or 0) >= 0.42
        and (econ.MassTrend or 0) >= 0.02
        and (econ.EnergyStorageRatio or 0) < 0.62
        and (econ.EnergyTrend or 0) < 14
        and not forceFactoryRecovery then
        return true
    end

    if pgenCount > math.max(10, mexCount * maxPgenPerMex) then
        if econ.EnergyStorageRatio >= hardStopEnergyRatio and econ.EnergyTrend >= hardStopEnergyTrend and econ.MassStorageRatio <= hardStopMassRatio then
            return false
        end
    end

    if econ.EnergyStorageRatio >= maxEnergyRatioCap and econ.EnergyTrend >= maxEnergyTrendCap then
        return false
    end

    if forceFactoryRecovery and econ.MassStorageRatio < 0.45 and econ.EnergyStorageRatio > 0.3 and econ.EnergyTrend > -6 then
        return false
    end

    local queueBlocked = recovery.FactoryQueueExpansionBlocked
        or (((recovery.FactoryQueueDeficitRatio or 0) >= 0.34) and ((recovery.FactoryQueueStarvationTime or 0) >= 12))
    if queueBlocked and econ.MassTrend <= -0.05 and econ.EnergyStorageRatio >= 0.18 and econ.EnergyTrend >= -10 then
        return false
    end

    if econ.MassTrend <= -0.08 and econ.EnergyStorageRatio >= 0.22 and econ.EnergyTrend >= -6 then
        return false
    end

    -- Build power when we are actually stalling or close to stall.
    if econ.EnergyStorageRatio <= ratio or econ.EnergyTrend <= trend then
        return true
    end

    -- If mass is floating heavily, allow some extra power to unlock spending.
    if econ.MassStorageRatio >= 0.85 and econ.EnergyStorageRatio < 0.7 and econ.EnergyTrend < 8 and econ.MassStorageRatio > massRatio then
        return true
    end

    return false
end

function ShouldPrioritizeFirstTech2Power(aiBrain)
    if not IsOvermindBrain(aiBrain) then
        return false
    end

    local econ = GetEcon(aiBrain)
    local director = GetProductionDirector(aiBrain)
    local current = director and director.Current or false
    local constraints = director and director.ConstraintState or {}
    local power = current and current.Eco and current.Eco.Power or {}
    local land = current and current.Factories and current.Factories.Land or {}
    local t2plusEngineers = GetUnitCount(aiBrain, categories.ENGINEER * categories.MOBILE * (categories.TECH2 + categories.TECH3))
    local t2plusPower = GetExistingUnitCount(aiBrain, categories.ENERGYPRODUCTION * (categories.TECH2 + categories.TECH3))
    local unfinishedT2plusPower = GetUnfinishedUnitCount(aiBrain, categories.ENERGYPRODUCTION * (categories.TECH2 + categories.TECH3))
    local t1PowerReady = GetExistingUnitCount(aiBrain, categories.ENERGYPRODUCTION * categories.TECH1)
    local t2LandReady = GetExistingUnitCount(aiBrain, categories.FACTORY * categories.LAND * categories.TECH2)

    if t2LandReady < 1 or t2plusEngineers < 1 then
        return false
    end
    if t2plusPower > 0 or unfinishedT2plusPower > 0 then
        return false
    end
    if land.Ready < 1 or (power.Ready or 0) < 4 or t1PowerReady < 5 then
        return false
    end
    if constraints.EcoCrash or constraints.CriticalFactory or constraints.CriticalStructure then
        return false
    end
    if (econ.EnergyStorageRatio or 0) >= 0.82 and (econ.EnergyTrend or 0) >= 16 then
        return false
    end
    if (econ.MassIncome or 0) < 2.3 or (econ.EnergyIncome or 0) < 42 then
        return false
    end
    if (econ.MassTrend or 0) < -0.24 or (econ.EnergyTrend or 0) < -14 then
        return false
    end

    return true
end

function HasSafeEnergy(aiBrain, minEnergyRatio, minEnergyTrend)
    if not IsOvermindBrain(aiBrain) then
        return false
    end

    local econ = GetEcon(aiBrain)
    local policy = GetPolicy(aiBrain)
    local ratio = minEnergyRatio or (policy and policy.SafeEnergyRatio) or 0.3
    local trend = minEnergyTrend or (policy and policy.SafeEnergyTrend) or 2

    return econ.EnergyStorageRatio >= ratio and econ.EnergyTrend >= trend
end

function CanRunFactoryProduction(aiBrain, domain)
    if not IsOvermindBrain(aiBrain) then
        return false
    end
    if not ShouldUseLegacyFactoryProduction(aiBrain, 'production') then
        return false
    end

    local econ = GetEcon(aiBrain)
    local recovery = GetRecovery(aiBrain) or {}
    local kind = string.lower(domain or 'land')
    local policy = GetPolicy(aiBrain)
    local phase = (policy and policy.MacroPhase) or 'consolidate'

    local energyRatio = econ.EnergyStorageRatio or 0
    local energyTrend = econ.EnergyTrend or 0
    local massRatio = econ.MassStorageRatio or 0
    local massTrend = econ.MassTrend or 0
    local massIncome = econ.MassIncome or 0

    -- Allow factories to keep queuing in almost all scenarios; only block in hard dual-resource crashes.
    local dualCritical = energyRatio <= 0.001
        and massRatio <= 0.001
        and energyTrend <= -55
        and massTrend <= -1.2
    if dualCritical then
        return false
    end

    if recovery.ForceFactoryRecovery then
        return true
    end

    if kind == 'air' then
        if IsEconomyBootstrapState(aiBrain) and not IsUnderAirHarass(aiBrain, 1) and not IsUnderBomberHarass(aiBrain, 1) then
            return false
        end
        if phase == 'bootstrap' and not IsUnderAirHarass(aiBrain, 1) and not IsUnderBomberHarass(aiBrain, 1) then
            return false
        end
        if energyRatio <= 0.002 and energyTrend <= -42 and massIncome < 0.8 then
            return false
        end
        return true
    end

    if kind == 'sea' then
        if (phase == 'bootstrap' or phase == 'recover') and not HasRecoveryFlag(aiBrain, 'ForceFactoryRecovery') then
            return false
        end
        if massRatio <= 0.002 and massTrend <= -1 and energyRatio <= 0.01 and energyTrend <= -35 then
            return false
        end
        return true
    end

    if massRatio <= 0.001 and massTrend <= -1.1 and energyRatio <= 0.01 and energyTrend <= -38 then
        return false
    end

    return true
end

function MassOverflowRisk(aiBrain, minMassRatio, minMassTrend)
    if not IsOvermindBrain(aiBrain) then
        return false
    end

    local econ = GetEcon(aiBrain)
    local ratio = minMassRatio or 0.7
    local trend = minMassTrend or 0

    return econ.MassStorageRatio >= ratio and econ.MassTrend >= trend
end

function ShouldUpgradeExtractors(aiBrain, minMassIncome, minEnergyIncome, minMassRatio, minEnergyRatio)
    if not IsOvermindBrain(aiBrain) then
        return false
    end

    local runtime = aiBrain.OvermindRuntime or {}
    local production = runtime.ProductionDirector or {}
    local current = production.Current or {}
    local factories = current.Factories or {}
    local ecoCounts = current.Eco or {}
    local macro = runtime.MacroController or {}
    local macroPhase = macro.Phase or production.MacroObjective or 'none'
    local factoryDirective = ((runtime.UpgradeDirector or {}).Factory) or {}
    local readyLand = ((factories.Land or {}).Ready) or 0
    local mexReady = (((ecoCounts.Mex or {}).Ready) or 0)
    local hasLandHQ = GetCompletedUnitCount(aiBrain, categories.FACTORY * categories.LAND * categories.STRUCTURE * (categories.TECH2 + categories.TECH3)) > 0
    local reserveForFirstHQ = not hasLandHQ
        and readyLand >= 2
        and mexReady <= 8
        and (
            macro.HQPressureEscape == true
            or factoryDirective.NeedsFirstLandHQ == true
            or macroPhase == 'starter_mex_claim'
            or macroPhase == 'mass_consolidation'
            or macroPhase == 'first_land_hq'
            or macroPhase == 'first_t2_engineer'
            or macroPhase == 'first_t2_power'
        )
    if reserveForFirstHQ then
        return false
    end

    local upgradeDirector = GetUpgradeDirector(aiBrain)
    local directedExtractor = upgradeDirector and upgradeDirector.Extractor or false
    if directedExtractor and directedExtractor.Managed == true then
        return directedExtractor.Enabled == true
    end

    local econ = GetEcon(aiBrain)
    local policy = GetPolicy(aiBrain)
    local director = GetProductionDirector(aiBrain)
    local techPlan = director and director.TechPlan or false
    local massIncome = minMassIncome or (policy and policy.UpgradeMassIncome) or 4
    local energyIncome = minEnergyIncome or (policy and policy.UpgradeEnergyIncome) or 20
    local massRatio = minMassRatio or 0.25
    local energyRatio = minEnergyRatio or 0.2
    local now = GetGameTimeSeconds()
    local minTime = (policy and policy.T2MexMinTime) or 210
    local minFactories = (policy and policy.T2MexMinFactories) or 2
    local factoryCount = GetUnitCount(aiBrain, categories.FACTORY * categories.STRUCTURE)

    if techPlan and techPlan.ExtractorUpgradeReason then
        if techPlan.UpgradeExtractors == true then
            return true
        end
        if CanConsolidateLocalTech2Extractors(aiBrain, 320) then
            return true
        end
        return false
    end

    if now < minTime and factoryCount < minFactories then
        return false
    end

    if IsMassStarved(aiBrain, 0.4, -0.06, 2.8) and not MassOverflowRisk(aiBrain, 0.72, 0.15) then
        return false
    end

    if techPlan then
        local ecoBias = techPlan.EcoTechBias or 0
        if not techPlan.EligibleForTech then
            if ecoBias < 0.24 then
                return false
            end
            if not MassOverflowRisk(aiBrain, 0.82, 0.16) then
                return false
            end
            if not HasSafeEnergy(aiBrain, 0.38, 8) then
                return false
            end
        elseif ecoBias < 0.18 and not MassOverflowRisk(aiBrain, 0.78, 0.16) then
            return false
        end
    end

    if econ.MassIncome >= massIncome and econ.EnergyIncome >= energyIncome and econ.MassStorageRatio >= massRatio and econ.EnergyStorageRatio >= energyRatio then
        return true
    end

    if MassOverflowRisk(aiBrain, 0.75, 0.2) and HasSafeEnergy(aiBrain, 0.35, 8) then
        return true
    end

    return false
end

function ShouldUpgradeExtractorsAggressive(aiBrain)
    if not IsOvermindBrain(aiBrain) then
        return false
    end
    local upgradeDirector = GetUpgradeDirector(aiBrain)
    local directedExtractor = upgradeDirector and upgradeDirector.Extractor or false
    if directedExtractor and directedExtractor.Managed == true then
        return directedExtractor.Enabled == true and directedExtractor.Aggressive == true
    end
    local director = GetProductionDirector(aiBrain)
    local techPlan = director and director.TechPlan or false
    if techPlan and techPlan.ExtractorUpgradeReason then
        return techPlan.UpgradeExtractors == true and techPlan.AggressiveExtractorUpgrades == true
    end
    return false
end

function ShouldUpgradeLocalExtractors(aiBrain, targetTech, radius)
    if not IsOvermindBrain(aiBrain) then
        return false
    end
    local upgradeDirector = GetUpgradeDirector(aiBrain)
    local directedExtractor = upgradeDirector and upgradeDirector.Extractor or false
    if directedExtractor and directedExtractor.Managed == true then
        return directedExtractor.Enabled == true
            and directedExtractor.TargetTech == ((targetTech == 'tech3' or targetTech == 3) and 'tech3' or 'tech2')
            and directedExtractor.Scope == 'local'
            and directedExtractor.TargetId ~= false
    end
    if (targetTech == 'tech3') or (targetTech == 3) then
        if not CanUpgradeToTech3Extractors(aiBrain, math.max(radius or 240, 360)) then
            return false
        end
    elseif not ShouldUpgradeExtractors(aiBrain) and not CanConsolidateLocalTech2Extractors(aiBrain, math.max(radius or 240, 320)) then
        return false
    end
    return HasLocalExtractorUpgradeCandidate(aiBrain, targetTech, radius or 240)
end

function ShouldUpgradeRemoteExtractors(aiBrain, targetTech, minRadius)
    if not IsOvermindBrain(aiBrain) then
        return false
    end
    local upgradeDirector = GetUpgradeDirector(aiBrain)
    local directedExtractor = upgradeDirector and upgradeDirector.Extractor or false
    if directedExtractor and directedExtractor.Managed == true then
        return directedExtractor.Enabled == true
            and directedExtractor.TargetTech == ((targetTech == 'tech3' or targetTech == 3) and 'tech3' or 'tech2')
            and directedExtractor.Scope == 'remote'
            and directedExtractor.TargetId ~= false
    end

    if HasCriticalFactoryTask(aiBrain) or HasCriticalStructureTask(aiBrain) then
        return false
    end
    if IsUnderLandHarass(aiBrain, 1) or IsUnderAirHarass(aiBrain, 1) or IsBomberWatch(aiBrain) or IsBomberPanic(aiBrain) or IsExposedMexAirRaid(aiBrain) then
        return false
    end

    local director = GetProductionDirector(aiBrain)
    local current = director and director.Current or {}
    local factories = current.Factories or {}
    local eco = current.Eco or {}
    local structures = current.Structures or {}
    local confidence = director and director.Confidence or {}
    local mapControl = (aiBrain.OvermindRuntime and aiBrain.OvermindRuntime.ZoneModel and aiBrain.OvermindRuntime.ZoneModel.MapControl) or 0
    local liveEcon = GetEcon(aiBrain)
    local localRadius = math.max(minRadius or 240, ((targetTech == 'tech3') or (targetTech == 3)) and 340 or 320)

    if (targetTech == 'tech3') or (targetTech == 3) then
        if not CanUpgradeToTech3Extractors(aiBrain, localRadius) then
            return false
        end
    elseif CountLocalExtractorUpgradeCandidates(aiBrain, 'tech2', math.max(320, localRadius - 40)) > 0 then
        return false
    end

    local upgradedLocal = CountLocalUpgradedExtractors(aiBrain, targetTech, localRadius + 60)
    local requiredLocalUpgrades = (((targetTech == 'tech3') or (targetTech == 3)) and 1 or 2)

    if CountLocalExtractorUpgradeCandidates(aiBrain, targetTech, localRadius) > 0 then
        return false
    end
    if upgradedLocal < requiredLocalUpgrades then
        return false
    end
    if (structures.Radar or 0) <= 0 then
        return false
    end
    if ((factories.Land or {}).Ready or 0) < 3 then
        return false
    end
    if (((eco.Power or {}).Ready) or 0) < 4 then
        return false
    end
    if (confidence.Global or 0) < 0.52 or mapControl < 0.32 then
        return false
    end
    if (liveEcon.MassStorageRatio or 0) < 0.22 or (liveEcon.EnergyStorageRatio or 0) < 0.32 then
        return false
    end
    if (liveEcon.MassTrend or 0) < 0.02 or (liveEcon.EnergyTrend or 0) < 6 then
        return false
    end

    return CountSafeRemoteExtractorUpgradeCandidates(aiBrain, targetTech, localRadius) > 0
end

function UnderExtractorUpgradeCap(aiBrain, targetTech)
    if not IsOvermindBrain(aiBrain) then
        return false
    end

    local upgradeDirector = GetUpgradeDirector(aiBrain)
    local directedExtractor = upgradeDirector and upgradeDirector.Extractor or false
    if directedExtractor and directedExtractor.Managed == true then
        if directedExtractor.Enabled ~= true then
            return false
        end
        local normalizedTarget = ((targetTech == 'tech3') or (targetTech == 3)) and 'tech3' or 'tech2'
        if directedExtractor.TargetTech ~= normalizedTarget then
            return false
        end
        local cap = math.max(0, math.floor((directedExtractor.Cap or 0) + 0.5))
        local inFlight = math.max(0, directedExtractor.InFlight or 0)
        return cap > 0 and inFlight < cap
    end

    local techPlan, cap, inFlight = GetExtractorUpgradePlan(aiBrain)
    if targetTech == 'tech2' or targetTech == 2 then
        local consolidationOverride = CanConsolidateLocalTech2Extractors(aiBrain, 320)
        if (not techPlan or techPlan.UpgradeExtractors ~= true or cap <= 0) and not consolidationOverride then
            return false
        end
        local effectiveCap = consolidationOverride and math.max(1, math.min((cap > 0 and cap or 1), 1)) or cap
        return GetUnfinishedUnitCount(aiBrain, categories.MASSEXTRACTION * categories.TECH2) < effectiveCap and inFlight < effectiveCap
    end

    if not techPlan or techPlan.UpgradeExtractors ~= true or cap <= 0 then
        return false
    end

    if targetTech == 'tech3' or targetTech == 3 then
        return GetUnfinishedUnitCount(aiBrain, categories.MASSEXTRACTION * categories.TECH3) < cap and inFlight < cap
    end

    return inFlight < cap
end

function ShouldBuildMassFab(aiBrain, minMassRatio, minEnergyRatio, minEnergyIncome)
    if not IsOvermindBrain(aiBrain) then
        return false
    end

    local econ = GetEcon(aiBrain)
    local policy = GetPolicy(aiBrain)
    local massRatio = minMassRatio or (policy and policy.MassFabMassRatio) or 0.96
    local energyRatio = minEnergyRatio or (policy and policy.MassFabEnergyRatio) or 0.95
    local energyIncome = minEnergyIncome or (policy and policy.MassFabEnergyIncome) or 1400
    local minMassTrend = (policy and policy.MassFabMassTrend) or 0.2
    local minEnergyTrend = (policy and policy.MassFabEnergyTrend) or 130
    local minMexT3 = (policy and policy.MassFabMinT3Mex) or 4
    local minPgenT3 = (policy and policy.MassFabMinT3Pgen) or 2
    local mexT3 = GetUnitCount(aiBrain, categories.MASSEXTRACTION * categories.TECH3)
    local pgenT3 = GetUnitCount(aiBrain, categories.ENERGYPRODUCTION * categories.TECH3)

    if IsMassStarved(aiBrain, 0.82, -0.05, 0) then
        return false
    end

    if mexT3 < minMexT3 or pgenT3 < minPgenT3 then
        return false
    end

    return econ.MassStorageRatio >= massRatio
        and econ.MassTrend >= minMassTrend
        and econ.EnergyStorageRatio >= energyRatio
        and econ.EnergyIncome >= energyIncome
        and econ.EnergyTrend >= minEnergyTrend
end

function ShouldAddFactory(aiBrain, locationType, minMassIncome, minEnergyIncome, minMassRatio, minEnergyRatio)
    if not IsOvermindBrain(aiBrain) then
        return false
    end

    if not EBC.MassToFactoryRatioBaseCheck(aiBrain, locationType) then
        return false
    end

    local econ = GetEcon(aiBrain)
    local policy = GetPolicy(aiBrain)
    local capacity = GetAuthoritativeCapacityPlan(aiBrain)
    local now = GetGameTimeSeconds()
    local massIncome = minMassIncome or (policy and policy.FactoryMassIncome) or 5
    local energyIncome = minEnergyIncome or (policy and policy.FactoryEnergyIncome) or 70
    local massRatio = minMassRatio or (policy and policy.FactoryMassRatio) or 0.35
    local energyRatio = minEnergyRatio or (policy and policy.FactoryEnergyRatio) or 0.3
    local minMassTrend = (policy and policy.FactoryMinMassTrend) or -0.02
    local minEnergyTrend = (policy and policy.FactoryMinEnergyTrend) or 8
    local minMassPerFactory = (policy and policy.FactoryMassPerFactory) or 1.2
    local maxFactoriesPerMex = (policy and policy.FactoryToMexCap) or 0.95
    local phase = (policy and policy.MacroPhase) or 'consolidate'
    local softCap = (policy and policy.PrimaryFactorySoftCap) or 3
    local factoryCount = GetUnitCount(aiBrain, categories.FACTORY * categories.STRUCTURE)
    local mexCount = GetUnitCount(aiBrain, categories.MASSEXTRACTION * categories.STRUCTURE)
    local massPerFactory = econ.MassIncome
    local forceFactoryRecovery = HasRecoveryFlag(aiBrain, 'ForceFactoryRecovery')
    local stagnation = 0
    local recovery = GetRecovery(aiBrain)
    if recovery then
        stagnation = recovery.StagnationTime or 0
    end

    if factoryCount > 0 then
        massPerFactory = econ.MassIncome / factoryCount
    end

    local isPrimary = IsPrimaryLocation(aiBrain, locationType, 44)
    if capacity then
        if IsFactoryGrowthHardBlocked(aiBrain, capacity) then
            return false
        end
        local landFactories = GetExistingUnitCount(aiBrain, categories.FACTORY * categories.LAND * categories.STRUCTURE)
        local airFactories = GetExistingUnitCount(aiBrain, categories.FACTORY * categories.AIR * categories.STRUCTURE)
        local seaFactories = GetExistingUnitCount(aiBrain, categories.FACTORY * categories.NAVAL * categories.STRUCTURE)
        if IsFactoryCapacityOvershoot(capacity, nil, landFactories, airFactories, seaFactories) then
            return false
        end
        local anyGrowth = capacity.AddLandFactory or capacity.AddAirFactory or capacity.AddSeaFactory
        if not isPrimary then
            return anyGrowth and IsSecondaryExpansionReady(aiBrain, recovery, now, econ, factoryCount)
        end
        return anyGrowth == true
    end

    if IsFactoryGrowthHardBlocked(aiBrain, false) then
        return false
    end

    local queueBlocked = recovery and (recovery.FactoryQueueExpansionBlocked
        or (((recovery.FactoryQueueDeficitRatio or 0) >= 0.34) and ((recovery.FactoryQueueStarvationTime or 0) >= 12)))

    if not isPrimary then
        if queueBlocked then
            return false
        end
        return IsSecondaryExpansionReady(aiBrain, recovery, now, econ, factoryCount)
    end

    if HasCriticalFactoryTask(aiBrain) then
        return false
    end

    if phase == 'bootstrap' and factoryCount >= 2 and not MassOverflowRisk(aiBrain, 0.92, 0.4) then
        return false
    end

    if phase == 'recover' and factoryCount >= 2 and not forceFactoryRecovery then
        return false
    end

    if phase == 'consolidate' and factoryCount >= softCap and not MassOverflowRisk(aiBrain, 0.9, 0.35) then
        return false
    end

    if forceFactoryRecovery then
        return econ.EnergyStorageRatio >= 0.08
            and econ.EnergyTrend >= -14
            and econ.MassIncome >= 1.8
            and econ.MassTrend >= -0.28
    end

    if now >= 130 and factoryCount <= 1 then
        return econ.EnergyStorageRatio >= 0.005
            and econ.EnergyTrend >= -30
            and econ.MassIncome >= 1.4
            and econ.EnergyIncome >= 10
            and econ.MassTrend >= -0.55
    end

    if now >= 280 and factoryCount <= 2 then
        return econ.EnergyStorageRatio >= 0.01
            and econ.EnergyTrend >= -24
            and econ.MassIncome >= 1.8
            and econ.EnergyIncome >= 18
            and econ.MassTrend >= -0.46
    end

    if stagnation >= 95 then
        return econ.EnergyStorageRatio >= 0.1 and econ.MassIncome >= 2.1 and econ.MassTrend >= -0.2
    end

    if now < 540 and factoryCount < 4 then
        return econ.MassIncome >= 2.4 and econ.EnergyIncome >= 34 and econ.EnergyStorageRatio >= 0.1 and econ.MassTrend >= -0.22
    end

    -- Ensure early production baseline before strict scaling checks.
    if factoryCount < 2 then
        return econ.MassIncome >= 2.6 and econ.EnergyIncome >= 32 and econ.EnergyStorageRatio >= 0.12 and econ.MassTrend >= -0.18
    end

    if factoryCount >= 2 and massPerFactory < minMassPerFactory and not MassOverflowRisk(aiBrain, 0.92, 0.4) then
        return false
    end

    if mexCount >= 4 and factoryCount > (mexCount * maxFactoriesPerMex) and not MassOverflowRisk(aiBrain, 0.9, 0.35) then
        return false
    end

    if MassOverflowRisk(aiBrain, 0.82, 0.2) and HasSafeEnergy(aiBrain, 0.5, 16) and massPerFactory >= (minMassPerFactory * 0.8) then
        return true
    end

    return econ.MassIncome >= massIncome
        and econ.EnergyIncome >= energyIncome
        and econ.MassStorageRatio >= massRatio
        and econ.EnergyStorageRatio >= energyRatio
        and econ.MassTrend >= minMassTrend
        and econ.EnergyTrend >= minEnergyTrend
        and massPerFactory >= minMassPerFactory
end

function ShouldAddLandFactory(aiBrain, locationType, minMassIncome, minEnergyIncome, minMassRatio, minEnergyRatio)
    local capacity = GetAuthoritativeCapacityPlan(aiBrain)
    if IsFactoryGrowthHardBlocked(aiBrain, capacity, 'land') then
        return false
    end
    if capacity then
        local landFactories = GetExistingUnitCount(aiBrain, categories.FACTORY * categories.LAND * categories.STRUCTURE)
        local airFactories = GetExistingUnitCount(aiBrain, categories.FACTORY * categories.AIR * categories.STRUCTURE)
        local seaFactories = GetExistingUnitCount(aiBrain, categories.FACTORY * categories.NAVAL * categories.STRUCTURE)
        if IsFactoryCapacityOvershoot(capacity, 'land', landFactories, airFactories, seaFactories) then
            return false
        end
    end
    if capacity then
        local recovery = GetRecovery(aiBrain) or {}
        local now = GetGameTimeSeconds()
        local factoryCount = GetUnitCount(aiBrain, categories.FACTORY * categories.STRUCTURE)
        local allow = false
        if not IsPrimaryLocation(aiBrain, locationType, 44) then
            allow = capacity.AddLandFactory == true and IsSecondaryExpansionReady(aiBrain, recovery, now, GetEcon(aiBrain), factoryCount)
        else
            allow = capacity.AddLandFactory == true or HasSecondLandFactoryBootstrapDebt(aiBrain, capacity, 'land')
        end
        if not allow then
            return false
        end
        return ApproveFactoryBuildRequest(aiBrain, 'land')
    end
    if not ShouldAddFactory(aiBrain, locationType, minMassIncome, minEnergyIncome, minMassRatio, minEnergyRatio) then
        return false
    end

    if HasRecoveryFlag(aiBrain, 'ForceFactoryLand') then
        return ApproveFactoryBuildRequest(aiBrain, 'land')
    end
    if HasRecoveryFlag(aiBrain, 'ForceFactoryAir') then
        return false
    end

    local landFactories, airFactories = GetFactoryCounts(aiBrain)
    local total = landFactories + airFactories
    if total < 4 then
        return ApproveFactoryBuildRequest(aiBrain, 'land')
    end

    local ownAir = GetUnitCount(aiBrain, categories.MOBILE * categories.AIR - categories.SCOUT)
    local enemyAir = 0
    if aiBrain.OvermindRuntime and aiBrain.OvermindRuntime.OpponentModel then
        enemyAir = aiBrain.OvermindRuntime.OpponentModel.Air or 0
    end

    if landFactories < 2 then
        return ApproveFactoryBuildRequest(aiBrain, 'land')
    end

    if total <= 0 then
        return ApproveFactoryBuildRequest(aiBrain, 'land')
    end

    local posture = GetPosture(aiBrain)
    local desiredAirShare = 0.34
    if posture == 'air_rush' then
        desiredAirShare = 0.46
    elseif posture == 'land_push' then
        desiredAirShare = 0.27
    elseif posture == 'turtle' then
        desiredAirShare = 0.4
    end

    local currentAirShare = airFactories / total
    if currentAirShare < (desiredAirShare - 0.08) and ownAir < math.max(8, enemyAir * 0.92) then
        return false
    end

    return ApproveFactoryBuildRequest(aiBrain, 'land')
end

function ShouldAddAirFactory(aiBrain, locationType, minMassIncome, minEnergyIncome, minMassRatio, minEnergyRatio)
    local capacity = GetAuthoritativeCapacityPlan(aiBrain)
    if IsFactoryGrowthHardBlocked(aiBrain, capacity, 'air') then
        return false
    end
    if capacity then
        local landFactories = GetExistingUnitCount(aiBrain, categories.FACTORY * categories.LAND * categories.STRUCTURE)
        local airFactories = GetExistingUnitCount(aiBrain, categories.FACTORY * categories.AIR * categories.STRUCTURE)
        local seaFactories = GetExistingUnitCount(aiBrain, categories.FACTORY * categories.NAVAL * categories.STRUCTURE)
        if IsFactoryCapacityOvershoot(capacity, 'air', landFactories, airFactories, seaFactories) then
            return false
        end
    end
    if capacity then
        local recovery = GetRecovery(aiBrain) or {}
        local now = GetGameTimeSeconds()
        local factoryCount = GetUnitCount(aiBrain, categories.FACTORY * categories.STRUCTURE)
        local allow = false
        if not IsPrimaryLocation(aiBrain, locationType, 44) then
            allow = capacity.AddAirFactory == true and IsSecondaryExpansionReady(aiBrain, recovery, now, GetEcon(aiBrain), factoryCount)
        else
            allow = capacity.AddAirFactory == true
        end
        if not allow then
            return false
        end
        return ApproveFactoryBuildRequest(aiBrain, 'air')
    end
    if not ShouldAddFactory(aiBrain, locationType, minMassIncome, minEnergyIncome, minMassRatio, minEnergyRatio) then
        return false
    end

    if HasRecoveryFlag(aiBrain, 'ForceFactoryAir') then
        return ApproveFactoryBuildRequest(aiBrain, 'air')
    end
    if HasRecoveryFlag(aiBrain, 'ForceFactoryLand') then
        return false
    end

    local landFactories, airFactories = GetFactoryCounts(aiBrain)
    local total = landFactories + airFactories
    if total < 4 then
        return ApproveFactoryBuildRequest(aiBrain, 'air')
    end

    local ownAir = GetUnitCount(aiBrain, categories.MOBILE * categories.AIR - categories.SCOUT)
    local enemyAir = 0
    if aiBrain.OvermindRuntime and aiBrain.OvermindRuntime.OpponentModel then
        enemyAir = aiBrain.OvermindRuntime.OpponentModel.Air or 0
    end

    if airFactories < 1 and landFactories >= 1 then
        return ApproveFactoryBuildRequest(aiBrain, 'air')
    end

    if total <= 0 then
        return ApproveFactoryBuildRequest(aiBrain, 'air')
    end

    local posture = GetPosture(aiBrain)
    local desiredAirShare = 0.34
    if posture == 'air_rush' then
        desiredAirShare = 0.46
    elseif posture == 'land_push' then
        desiredAirShare = 0.27
    elseif posture == 'turtle' then
        desiredAirShare = 0.4
    end

    local currentAirShare = airFactories / total
    if currentAirShare > (desiredAirShare + 0.1) and ownAir >= math.max(10, enemyAir * 1.05) then
        return false
    end

    return ApproveFactoryBuildRequest(aiBrain, 'air')
end

function ShouldForceFactoryRecovery(aiBrain)
    if not IsOvermindBrain(aiBrain) then
        return false
    end
    local capacity = GetAuthoritativeCapacityPlan(aiBrain) or {}
    return HasRecoveryFlag(aiBrain, 'ForceFactoryRecovery') or capacity.CriticalFactoryRecovery == true
end

function ShouldForceLandFactoryRecovery(aiBrain)
    if not IsOvermindBrain(aiBrain) then
        return false
    end
    local capacity = GetAuthoritativeCapacityPlan(aiBrain) or {}
    return HasRecoveryFlag(aiBrain, 'ForceFactoryLand')
        or (capacity.CriticalFactoryRecovery == true and string.lower(capacity.CriticalFactoryDomain or 'none') == 'land')
end

function ShouldForceAirFactoryRecovery(aiBrain)
    if not IsOvermindBrain(aiBrain) then
        return false
    end
    local capacity = GetAuthoritativeCapacityPlan(aiBrain) or {}
    return HasRecoveryFlag(aiBrain, 'ForceFactoryAir')
        or (capacity.CriticalFactoryRecovery == true and string.lower(capacity.CriticalFactoryDomain or 'none') == 'air')
end

function ShouldForceScoutRecovery(aiBrain)
    if not IsOvermindBrain(aiBrain) then
        return false
    end
    return HasRecoveryFlag(aiBrain, 'ForceScoutRecovery')
end

function ShouldForceDefenseRecovery(aiBrain)
    if not IsOvermindBrain(aiBrain) then
        return false
    end
    local now = GetGameTimeSeconds()
    if IsFirstHQPriorityState(aiBrain, 3) and not IsUnderLandHarass(aiBrain, 4) and not IsUnderAirHarass(aiBrain, 4) and not IsBomberPanic(aiBrain) then
        return false
    end
    if IsLowTechDefenseCapped(aiBrain, IsBomberPanic(aiBrain)) then
        return false
    end
    if IsStructureBuildClaimed(aiBrain, 'defense', now) or HasUnfinishedDefenseBuild(aiBrain, 'defense') then
        return false
    end
    if IsStructureMassBlocked(aiBrain) and not IsUnderLandHarass(aiBrain, 2) and not IsUnderAirHarass(aiBrain, 2) then
        return false
    end
    local need = HasRecoveryFlag(aiBrain, 'ForceDefenseRecovery')
    if need then
        ClaimStructureBuild(aiBrain, 'defense', 30, now)
    end
    return need
end

function ShouldForceBaseEngineerRecovery(aiBrain)
    if not IsOvermindBrain(aiBrain) then
        return false
    end
    return HasRecoveryFlag(aiBrain, 'ForceBaseEngineerRecovery')
end

function IsProductionStagnating(aiBrain, minTime)
    if not IsOvermindBrain(aiBrain) then
        return false
    end
    local recovery = GetRecovery(aiBrain)
    if not recovery then
        return false
    end
    return (recovery.StagnationTime or 0) >= (minTime or 80)
end

local function GetFactoryIdleStats(aiBrain)
    local recovery = GetRecovery(aiBrain)
    if not recovery then
        return 0, 0, 0
    end
    return recovery.FactoryCount or 0, recovery.IdleFactories or 0, recovery.IdleRatio or 0
end

function NeedFactoryHeartbeatProduction(aiBrain, minIdleRatio, minIdleFactories, minStagnation)
    if not IsOvermindBrain(aiBrain) then
        return false
    end
    local recovery = GetRecovery(aiBrain)
    if not recovery then
        return false
    end

    local _, idleFactories, idleRatio = GetFactoryIdleStats(aiBrain)
    local needRatio = minIdleRatio or 0.33
    local needIdle = minIdleFactories or 1
    local needStagnation = minStagnation or 50

    if recovery.ForceFactoryRecovery then
        return true
    end

    if (recovery.FactoryQueueStarvationTime or 0) >= needStagnation and (recovery.FactoryQueueDeficitRatio or 0) >= needRatio then
        return true
    end

    return idleFactories >= needIdle and idleRatio >= needRatio and (recovery.StagnationTime or 0) >= needStagnation
end

function ShouldFactoryDeadlockBreak(aiBrain, minTime)
    if not IsOvermindBrain(aiBrain) then
        return false
    end
    local recovery = GetRecovery(aiBrain)
    if not recovery then
        return false
    end
    if recovery.ForceFactoryDeadlock then
        return true
    end
    local need = minTime or 25
    return (recovery.FactoryAnyQueueStarvationTime or 0) >= need and (recovery.FactoryQueueDeficit or 0) >= 1
end

function ShouldUseACUBuilders(aiBrain)
    if not IsOvermindBrain(aiBrain) then
        return false
    end

    local runtime = aiBrain.OvermindRuntime or {}
    local engState = runtime.EngineerState or {}
    local factoryTask = engState.UnfinishedFactoryTask or {}
    if factoryTask.Active == true and (factoryTask.ReadyFactories or 0) <= 0 then
        return false
    end

    local now = GetGameTimeSeconds()
    if now < 140 then
        return true
    end

    if (runtime.ACUSafetyLockUntil or -999) > now then
        return false
    end

    local hpRatio = GetACUHealthRatio(aiBrain)
    if hpRatio < 0.9 and now < 1200 then
        return false
    end

    local raid = runtime.RaidDefense or {}
    if raid.UnderLandHarass or raid.UnderAirHarass then
        local mainPos = GetMainPos(aiBrain, 'MAIN')
        if mainPos then
            local enemyNearBase = aiBrain:GetNumUnitsAroundPoint(
                categories.MOBILE * (categories.LAND + categories.AIR) - categories.ENGINEER - categories.SCOUT - categories.COMMAND,
                mainPos,
                42,
                'Enemy') or 0
            if enemyNearBase >= 1 then
                return false
            end
        end
    end

    return true
end

function ShouldEmergencyRebuildEngineers(aiBrain, locationType, minTotal, minBase)
    if not IsOvermindBrain(aiBrain) then
        return false
    end

    local entry = GetRolePlanEntry(aiBrain, 'Engineer')
    local policy = GetPolicy(aiBrain)
    local engCount = GetUnitCount(aiBrain, categories.ENGINEER * categories.MOBILE)
    local factoryCount = GetUnitCount(aiBrain, categories.FACTORY * categories.STRUCTURE)
    local mexCount = GetUnitCount(aiBrain, categories.MASSEXTRACTION * categories.STRUCTURE)
    local baseFloor = math.max(minBase or 2, (policy and policy.BaseEngineerFloor) or 3)
    local hardFloor = math.max(
        minTotal or 4,
        math.min(10, math.max(baseFloor + 1, factoryCount + 1, math.floor(mexCount * 0.55) + 1)))

    local mainPos = GetMainPos(aiBrain, locationType)
    local baseEngineers = 0
    if mainPos then
        baseEngineers = aiBrain:GetNumUnitsAroundPoint(categories.ENGINEER * categories.MOBILE, mainPos, 80, 'Ally') or 0
    end

    local recovery = GetRecovery(aiBrain) or {}
    local engState = GetEngineerState(aiBrain) or {}
    local factoryTask = engState.UnfinishedFactoryTask or {}
    local structureTask = engState.UnfinishedStructureTask or {}
    local criticalTask = factoryTask.Active == true or structureTask.Active == true
    local econBootstrap = IsEconomyBootstrapState(aiBrain)
    local runtime = aiBrain.OvermindRuntime or {}
    local raid = runtime.RaidDefense or {}
    local bomberPanic = IsBomberPanic(aiBrain)
    local exposedMexAirRaid = IsExposedMexAirRaid(aiBrain)

    if HasRecoveryFlag(aiBrain, 'ForceBaseEngineerRecovery') or recovery.ForceFactoryRecovery then
        return true
    end
    if (bomberPanic or raid.UnderAirHarass or exposedMexAirRaid) and engCount < (hardFloor + 2) then
        return true
    end
    if engCount <= math.max(1, baseFloor - 1) then
        return true
    end
    if baseEngineers <= 0 and engCount < hardFloor then
        return true
    end
    if econBootstrap and engCount < hardFloor then
        return true
    end
    if criticalTask and engCount < (hardFloor + 1) then
        return true
    end
    if entry then
        local _, _, currentUnits, desiredUnits = GetRolePlanMetrics(entry)
        if currentUnits < math.max(hardFloor, desiredUnits) and (desiredUnits - currentUnits) >= 2 then
            return true
        end
    end
    return false
end

function ShouldBuildFactoryEngineer(aiBrain, locationType, minPerFactory, minTotal)
    if not IsOvermindBrain(aiBrain) then
        return false
    end

    local entry = GetRolePlanEntry(aiBrain, 'Engineer')
    local policy = GetPolicy(aiBrain)
    local phase = (policy and policy.MacroPhase) or 'consolidate'
    local factoryCount = GetUnitCount(aiBrain, categories.FACTORY * categories.STRUCTURE)
    local engCount = GetUnitCount(aiBrain, categories.ENGINEER * categories.MOBILE)
    local mexCount = GetUnitCount(aiBrain, categories.MASSEXTRACTION * categories.STRUCTURE)
    local now = GetGameTimeSeconds()
    local perFactory = minPerFactory or (policy and policy.EngineerFactoryRatio) or 0.95
    local targetTotal = math.max(
        minTotal or 6,
        math.floor(factoryCount * perFactory),
        math.floor(mexCount * ((phase == 'bootstrap' or phase == 'recover') and 0.95 or 0.75))
    )
    if phase == 'bootstrap' and targetTotal < 5 then
        targetTotal = 5
    end
    local starterPhase = IsStarterPhaseState(aiBrain)
    local director = GetProductionDirector(aiBrain)
    local constraints = director and director.ConstraintState or {}
    local runtime = aiBrain.OvermindRuntime or {}
    local raid = runtime.RaidDefense or {}
    local bomberPanic = IsBomberPanic(aiBrain)
    local bomberWatch = IsBomberWatch(aiBrain)
    local exposedMexAirRaid = IsExposedMexAirRaid(aiBrain)
    if starterPhase then
        targetTotal = math.max(targetTotal, constraints.StarterEngineerFloor or 6)
    end
    if bomberWatch and not bomberPanic and not exposedMexAirRaid then
        targetTotal = targetTotal + 1
    end
    if bomberPanic or raid.UnderAirHarass or exposedMexAirRaid then
        targetTotal = targetTotal + 2
    end
    targetTotal = math.min(targetTotal, (phase == 'bootstrap') and 9 or 12)
    local mainPos = GetMainPos(aiBrain, locationType)
    local baseEngineers = 0
    if mainPos then
        baseEngineers = aiBrain:GetNumUnitsAroundPoint(categories.ENGINEER * categories.MOBILE, mainPos, 80, 'Ally') or 0
    end
    local baseFloor = (policy and policy.BaseEngineerFloor) or 3
    local engState = GetEngineerState(aiBrain) or {}
    local factoryTask = engState.UnfinishedFactoryTask or {}
    local structureTask = engState.UnfinishedStructureTask or {}
    local econBootstrap = IsEconomyBootstrapState(aiBrain)

    if ShouldEmergencyRebuildEngineers(aiBrain, locationType, minTotal or 4, math.max(2, baseFloor - 1)) then
        return true
    end

    if HasRecoveryFlag(aiBrain, 'ForceBaseEngineerRecovery') then
        return true
    end

    local recovery = GetRecovery(aiBrain) or {}
    if entry then
        local currentStrength, desiredStrength, currentUnits, desiredUnits = GetRolePlanMetrics(entry)
        desiredUnits = math.max(desiredUnits, minTotal or 0)
        local landScreen = GetUnitCount(aiBrain, categories.MOBILE * categories.LAND * categories.TECH1 - categories.ENGINEER - categories.SCOUT - categories.COMMAND)
        local earlyScreenFloor = (now < 240) and 4 or ((now < 420) and 8 or ((now < 660) and 12 or 0))
        if earlyScreenFloor > 0
            and factoryCount <= 2
            and engCount >= 4
            and landScreen < earlyScreenFloor
            and not HasRecoveryFlag(aiBrain, 'ForceBaseEngineerRecovery')
            and not recovery.ForceFactoryRecovery then
            return false
        end
        if factoryTask.Active and (factoryTask.AssignedBuilders or 0) < (factoryTask.RequiredBuilders or 0) then
            desiredUnits = desiredUnits + math.max(1, (factoryTask.RequiredBuilders or 0) - (factoryTask.AssignedBuilders or 0))
        end
        if structureTask.Active and (structureTask.AssignedBuilders or 0) < (structureTask.RequiredBuilders or 0) then
            desiredUnits = desiredUnits + math.max(0, (structureTask.RequiredBuilders or 0) - (structureTask.AssignedBuilders or 0))
        end
        if recovery.FactoryQueueExpansionBlocked and currentUnits >= desiredUnits and baseEngineers >= math.max(2, baseFloor - 1) then
            return false
        end
        if currentStrength + 0.05 < desiredStrength then
            return true
        end
        if currentUnits >= (desiredUnits + 3)
            and currentStrength >= (desiredStrength - 0.05)
            and baseEngineers >= baseFloor
            and not factoryTask.Active
            and not structureTask.Active then
            return false
        end
        if currentUnits < desiredUnits then
            return true
        end
        if econBootstrap and currentUnits < math.max(desiredUnits, 7) then
            return true
        end
        if starterPhase and currentUnits < math.max(desiredUnits, constraints.StarterEngineerFloor or 6) then
            return true
        end
        return baseEngineers < baseFloor and currentUnits < (desiredUnits + 1)
    end

    if recovery.FactoryQueueExpansionBlocked and engCount >= math.max(5, factoryCount) then
        return false
    end

    if engCount >= math.max(8, factoryCount + 3) and baseEngineers >= math.max(2, baseFloor - 1) then
        return false
    end

    if engCount < targetTotal then
        return true
    end

    if econBootstrap and engCount < math.max(targetTotal, 7) then
        return true
    end

    if starterPhase and engCount < math.max(targetTotal, constraints.StarterEngineerFloor or 6) then
        return true
    end

    return baseEngineers < baseFloor
end

local function GetDoctrineShares(aiBrain)
    local posture = GetPosture(aiBrain)
    local shares = {
        LandAA = 0.16,
        LandIndirect = 0.14,
        AirFighter = 0.55,
        AirBomber = 0.3,
    }

    if posture == 'air_rush' then
        shares.LandAA = 0.24
        shares.LandIndirect = 0.08
        shares.AirFighter = 0.7
        shares.AirBomber = 0.2
    elseif posture == 'land_push' then
        shares.LandAA = 0.14
        shares.LandIndirect = 0.18
        shares.AirFighter = 0.48
        shares.AirBomber = 0.38
    elseif posture == 'turtle' then
        shares.LandAA = 0.16
        shares.LandIndirect = 0.2
        shares.AirFighter = 0.45
        shares.AirBomber = 0.42
    elseif posture == 'eco_greed' then
        shares.LandAA = 0.15
        shares.LandIndirect = 0.16
        shares.AirFighter = 0.58
        shares.AirBomber = 0.34
    end

    return shares
end

function ShouldBuildLandDoctrine(aiBrain, role)
    if not IsOvermindBrain(aiBrain) then
        return false
    end

    local landAll = GetUnitCount(aiBrain, categories.LAND * categories.MOBILE - categories.ENGINEER - categories.SCOUT - categories.COMMAND)
    local landAA = GetUnitCount(aiBrain, categories.LAND * categories.MOBILE * categories.ANTIAIR - categories.ENGINEER - categories.SCOUT - categories.COMMAND)
    local landIndirect = GetUnitCount(aiBrain, categories.LAND * categories.MOBILE * categories.INDIRECTFIRE - categories.ENGINEER - categories.SCOUT - categories.COMMAND)
    local landTank = math.max(0, landAll - landAA - landIndirect)
    local enemyAir = GetUnitCount(aiBrain, categories.MOBILE * categories.AIR - categories.SCOUT - categories.TRANSPORTATION - categories.COMMAND)
    local shares = GetDoctrineShares(aiBrain)
    local recovery = GetRecovery(aiBrain)

    if role == 'aa' then
        local targetAA = math.max(2, math.floor(math.max(1, landAll) * shares.LandAA))
        if enemyAir >= 8 then
            targetAA = targetAA + 1
        end
        targetAA = math.min(targetAA, math.max(4, math.floor(math.max(1, landAll) * 0.34)))
        return landAA < targetAA
    elseif role == 'indirect' then
        local targetIndirect = math.max(2, math.floor(math.max(1, landAll) * shares.LandIndirect))
        return landIndirect < targetIndirect
    end

    local targetTank = math.max(5, math.floor(math.max(1, landAll) * 0.52))
    if recovery and recovery.ForceFactoryRecovery and (recovery.StagnationTime or 0) > 80 then
        targetTank = targetTank + 3
    end
    return landTank < targetTank
end

function ShouldBuildAirDoctrine(aiBrain, role)
    if not IsOvermindBrain(aiBrain) then
        return false
    end

    local airCombat = GetUnitCount(aiBrain, categories.AIR * categories.MOBILE - categories.SCOUT - categories.TRANSPORTATION - categories.COMMAND)
    local airFighter = GetUnitCount(aiBrain, categories.AIR * categories.MOBILE * categories.ANTIAIR - categories.SCOUT - categories.TRANSPORTATION - categories.COMMAND)
    local airBomber = GetUnitCount(aiBrain, categories.AIR * categories.MOBILE * categories.BOMBER - categories.SCOUT - categories.TRANSPORTATION - categories.COMMAND)
    local shares = GetDoctrineShares(aiBrain)

    if role == 'fighter' then
        local targetFighter = math.max(3, math.floor(math.max(1, airCombat) * shares.AirFighter))
        return airFighter < targetFighter
    end

    local targetBomber = math.max(2, math.floor(math.max(1, airCombat) * shares.AirBomber))
    return airBomber < targetBomber
end

function ShouldEmergencyFactoryScale(aiBrain, locationType, minGameTime, maxFactories)
    if not IsOvermindBrain(aiBrain) then
        return false
    end

    local now = GetGameTimeSeconds()
    local startAt = minGameTime or 150
    if now < startAt then
        return false
    end

    local econ = GetEcon(aiBrain)
    local factories = GetExistingUnitCount(aiBrain, categories.FACTORY * categories.STRUCTURE)
    local completeFactories = GetCompletedUnitCount(aiBrain, categories.FACTORY * categories.STRUCTURE)
    local pendingFactories = math.max(0, factories - completeFactories)
    local mexes = GetUnitCount(aiBrain, categories.MASSEXTRACTION * categories.STRUCTURE)
    local maxFac = maxFactories or 2
    local recovery = GetRecovery(aiBrain)
    local policy = GetPolicy(aiBrain)
    local phase = (policy and policy.MacroPhase) or 'consolidate'

    if factories > maxFac then
        return false
    end

    if pendingFactories >= 1 then
        return false
    end

    if mexes < 3 and now < 300 then
        return false
    end

    local queueBlocked = recovery and (recovery.FactoryQueueExpansionBlocked
        or (((recovery.FactoryQueueDeficitRatio or 0) >= 0.24) and ((recovery.FactoryQueueStarvationTime or 0) >= 8)))
    if queueBlocked then
        return false
    end

    if phase == 'bootstrap' and factories >= 2 then
        return false
    end

    if phase == 'recover' and not (recovery and recovery.ForceFactoryRecovery) then
        return false
    end

    local econOkay = econ.EnergyStorageRatio >= 0.035
        and econ.EnergyTrend >= -10
        and econ.MassTrend >= -0.14
        and econ.MassIncome >= 3.4
        and econ.EnergyIncome >= 40
    if not econOkay then
        return false
    end

    if recovery and (recovery.ForceFactoryRecovery or recovery.StagnationTime >= 65) then
        return true
    end

    if now >= 180 and factories <= 1 then
        return true
    end

    if now >= 360 and factories <= 2 then
        return true
    end

    return false
end

function ShouldHardFactoryBootstrap(aiBrain, locationType, minGameTime, maxFactories)
    if not IsOvermindBrain(aiBrain) then
        return false
    end

    local now = GetGameTimeSeconds()
    if now < (minGameTime or 130) then
        return false
    end

    local factories = GetExistingUnitCount(aiBrain, categories.FACTORY * categories.STRUCTURE)
    local completeFactories = GetCompletedUnitCount(aiBrain, categories.FACTORY * categories.STRUCTURE)
    local pendingFactories = math.max(0, factories - completeFactories)
    local mexes = GetUnitCount(aiBrain, categories.MASSEXTRACTION * categories.STRUCTURE)
    local maxFac = maxFactories or 2
    local recovery = GetRecovery(aiBrain) or {}
    local policy = GetPolicy(aiBrain)
    local phase = (policy and policy.MacroPhase) or 'consolidate'
    if factories > maxFac then
        return false
    end

    if pendingFactories >= 1 then
        return false
    end

    if recovery.FactoryQueueExpansionBlocked
        or (((recovery.FactoryQueueDeficitRatio or 0) >= 0.24) and ((recovery.FactoryQueueStarvationTime or 0) >= 8)) then
        return false
    end

    if mexes < 3 and now < 300 then
        return false
    end

    if phase ~= 'bootstrap' and factories >= 2 then
        return false
    end

    local econ = GetEcon(aiBrain)
    if econ.EnergyStorageRatio < 0.03 then
        return false
    end
    if econ.EnergyTrend < -14 then
        return false
    end
    if econ.MassTrend < -0.2 then
        return false
    end
    if econ.MassIncome < 2.4 or econ.EnergyIncome < 26 then
        return false
    end

    return true
end

function IsUnderLandHarass(aiBrain, minEnemy)
    if not IsOvermindBrain(aiBrain) then
        return false
    end
    local runtime = aiBrain.OvermindRuntime
    if not runtime or not runtime.RaidDefense then
        return false
    end
    local need = minEnemy or 1
    return runtime.RaidDefense.UnderLandHarass and (runtime.RaidDefense.LastLandEnemyCount or 0) >= need
end

function IsUnderAirHarass(aiBrain, minEnemy)
    if not IsOvermindBrain(aiBrain) then
        return false
    end
    local runtime = aiBrain.OvermindRuntime
    if not runtime or not runtime.RaidDefense then
        return false
    end
    local need = minEnemy or 1
    return runtime.RaidDefense.UnderAirHarass and (runtime.RaidDefense.LastAirEnemyCount or 0) >= need
end

function IsUnderBomberHarass(aiBrain, minEnemy)
    if not IsOvermindBrain(aiBrain) then
        return false
    end
    local runtime = aiBrain.OvermindRuntime
    if not runtime or not runtime.RaidDefense then
        return false
    end
    local need = minEnemy or 1
    return runtime.RaidDefense.UnderAirHarass and (runtime.RaidDefense.LastBomberEnemyCount or 0) >= need
end

function NeedBaselineRadar(aiBrain, minCount, radius)
    if not IsOvermindBrain(aiBrain) then
        return false
    end

    local basePos = GetMainPos(aiBrain, 'MAIN')
    if not basePos then
        return false
    end

    local required = minCount or 1
    local checkRadius = radius or 180
    local totalCount = aiBrain:GetNumUnitsAroundPoint(categories.STRUCTURE * categories.RADAR * categories.TECH1, basePos, checkRadius, 'Ally') or 0
    local completeCount = GetCompletedUnitCount(aiBrain, categories.STRUCTURE * categories.RADAR * categories.TECH1, basePos, checkRadius)
    local now = GetGameTimeSeconds()
    local econ = GetEcon(aiBrain)
    local policy = GetPolicy(aiBrain)
    local director = GetProductionDirector(aiBrain)
    local constraints = director and director.ConstraintState or {}
    local minTime = (policy and policy.RadarMinTime) or 300
    local minIncome = (policy and policy.RadarMinEnergyIncome) or 30
    local minStored = (policy and policy.RadarMinEnergyStored) or 1800
    local energyStored = aiBrain.GetEconomyStored and (aiBrain:GetEconomyStored('ENERGY') or 0) or 0
    local bomberWatch = IsBomberWatch(aiBrain)
    local underHarass = IsUnderLandHarass(aiBrain, 1) or IsUnderAirHarass(aiBrain, 1) or IsUnderBomberHarass(aiBrain, 1) or bomberWatch

    if totalCount >= required or completeCount >= required then
        return false
    end
    if ShouldBypassGenericFirstRadar(aiBrain) then
        return false
    end
    if totalCount > completeCount then
        return false
    end
    if IsRadarBuildLocked(aiBrain, now) or IsRadarBuildClaimed(aiBrain, now) then
        return false
    end

    if constraints.StarterRadarRequired == true then
        local powerReady = GetCompletedUnitCount(aiBrain, categories.ENERGYPRODUCTION * categories.STRUCTURE)
        local requiredPower = constraints.StarterPowerFloor or constraints.BootstrapPowerFloor or 1
        if powerReady < math.max(1, requiredPower - 1) then
            return false
        end
        ClaimRadarBuild(aiBrain, 12, now)
        return true
    end

    if not underHarass and now < minTime then
        return false
    end
    if not underHarass and (econ.EnergyIncome or 0) < minIncome and (econ.EnergyTrend or 0) < 4 then
        return false
    end
    if not underHarass and energyStored < minStored and (econ.EnergyStorageRatio or 0) < 0.14 then
        return false
    end

    local need = completeCount < required
    if need then
        ClaimRadarBuild(aiBrain, 9, now)
    end
    return need
end

function ShouldBuildCoverageRadar(aiBrain, minCount)
    if not IsOvermindBrain(aiBrain) then
        return false
    end

    local required = math.max(minCount or 1, GetDesiredRadarCount(aiBrain))
    local totalCount = GetUnitCount(aiBrain, categories.STRUCTURE * categories.RADAR)
    local completeCount = GetCompletedUnitCount(aiBrain, categories.STRUCTURE * categories.RADAR)
    local now = GetGameTimeSeconds()
    local econ = GetEcon(aiBrain)
    local policy = GetPolicy(aiBrain)
    local minIncome = ((policy and policy.RadarMinEnergyIncome) or 30) + 16
    local minStored = ((policy and policy.RadarMinEnergyStored) or 1800) + 900
    local energyStored = aiBrain.GetEconomyStored and (aiBrain:GetEconomyStored('ENERGY') or 0) or 0
    local bomberWatch = IsBomberWatch(aiBrain)
    if totalCount >= required or completeCount >= required then
        return false
    end
    if completeCount <= 0 then
        return false
    end
    if totalCount > completeCount then
        return false
    end
    if IsRadarBuildLocked(aiBrain, now) or IsRadarBuildClaimed(aiBrain, now) then
        return false
    end
    if (not bomberWatch) and now < 620 and (econ.EnergyStorageRatio or 0) < 0.12 and (econ.EnergyTrend or 0) < 8 then
        return false
    end
    if (econ.EnergyIncome or 0) < (bomberWatch and (minIncome - 10) or minIncome) and (econ.EnergyTrend or 0) < 8 then
        return false
    end
    if energyStored < (bomberWatch and (minStored - 700) or minStored) and (econ.EnergyStorageRatio or 0) < 0.2 then
        return false
    end
    local need = completeCount < required
    if need then
        ClaimRadarBuild(aiBrain, 9, now)
    end
    return need
end

function IsBomberPanic(aiBrain)
    if not IsOvermindBrain(aiBrain) then
        return false
    end
    local runtime = aiBrain.OvermindRuntime
    if not runtime or not runtime.RaidDefense then
        return false
    end
    local panicUntil = runtime.RaidDefense.BomberPanicUntil or -999
    return panicUntil > GetGameTimeSeconds()
end

function IsExposedMexAirRaid(aiBrain)
    if not IsOvermindBrain(aiBrain) then
        return false
    end
    local runtime = aiBrain.OvermindRuntime
    if not runtime or not runtime.RaidDefense then
        return false
    end
    return runtime.RaidDefense.ExposedMexUnderAirRaid == true and runtime.RaidDefense.ExposedMexThreatPos ~= false
end

function IsBomberWatch(aiBrain)
    if not IsOvermindBrain(aiBrain) then
        return false
    end
    if IsBomberPanic(aiBrain) or IsExposedMexAirRaid(aiBrain) then
        return false
    end
    local runtime = aiBrain.OvermindRuntime or {}
    local opp = runtime.OpponentModel or {}
    local raid = runtime.RaidDefense or {}
    return (opp.Bomber or 0) >= 1 or (raid.LastBomberEnemyCount or 0) >= 1
end

function IsT1Mode(aiBrain, modeName)
    if not IsOvermindBrain(aiBrain) then
        return false
    end
    local director = GetProductionDirector(aiBrain)
    if not director or not modeName then
        return false
    end
    return director.Mode == modeName
end

function IsT1NavalActive(aiBrain)
    if not IsOvermindBrain(aiBrain) then
        return false
    end
    local director = GetProductionDirector(aiBrain)
    return director and director.NavalActive == true
end

function ShouldBuildT1FactoryType(aiBrain, factoryType, locationType)
    if not IsOvermindBrain(aiBrain) then
        return false
    end

    local kind = string.lower(factoryType or '')
    local director = GetProductionDirector(aiBrain)
    local now = GetGameTimeSeconds()
    local landFactories = GetExistingUnitCount(aiBrain, categories.FACTORY * categories.LAND * categories.STRUCTURE)
    local airFactories = GetExistingUnitCount(aiBrain, categories.FACTORY * categories.AIR * categories.STRUCTURE)
    local seaFactories = GetExistingUnitCount(aiBrain, categories.FACTORY * categories.NAVAL * categories.STRUCTURE)
    local totalFactories = landFactories + airFactories + seaFactories
    local capacity = GetAuthoritativeCapacityPlan(aiBrain)
    local recovery = GetRecovery(aiBrain) or {}
    local isPrimary = IsPrimaryLocation(aiBrain, locationType, 44)
    if IsFactoryGrowthHardBlocked(aiBrain, capacity, kind) then
        return false
    end
    if capacity and IsFactoryCapacityOvershoot(capacity, kind, landFactories, airFactories, seaFactories) then
        return false
    end

    if not isPrimary then
        local econ = GetEcon(aiBrain)
        if not IsSecondaryExpansionReady(aiBrain, recovery, now, econ, totalFactories) then
            return false
        end
    end

    if capacity then
        local allow = false
        if kind == 'land' then
            allow = capacity.AddLandFactory == true or (isPrimary and HasSecondLandFactoryBootstrapDebt(aiBrain, capacity, kind))
        elseif kind == 'air' then
            allow = capacity.AddAirFactory == true
        elseif kind == 'sea' or kind == 'naval' then
            allow = director and director.NavalActive == true and capacity.AddSeaFactory == true
        else
            allow = false
        end
        if not allow then
            return false
        end
        return ApproveFactoryBuildRequest(aiBrain, kind)
    end

    local completeFactories = GetCompletedUnitCount(aiBrain, categories.FACTORY * categories.STRUCTURE)
    local pendingFactories = math.max(0, totalFactories - completeFactories)
    local queueBlocked = recovery.FactoryQueueExpansionBlocked
        or (((recovery.FactoryQueueDeficitRatio or 0) >= 0.34) and ((recovery.FactoryQueueStarvationTime or 0) >= 12))
    local ecoBlocked = IsFactoryExpansionEcoBlocked(aiBrain, landFactories, airFactories, seaFactories)

    if queueBlocked then
        if kind == 'land' then
            if landFactories <= 0 then
                return ApproveFactoryBuildRequest(aiBrain, kind)
            end
            return recovery.ForceFactoryRecovery and landFactories <= 1 and ApproveFactoryBuildRequest(aiBrain, kind)
        elseif kind == 'air' then
            return recovery.ForceFactoryAir and airFactories <= 0 and landFactories >= 1 and ApproveFactoryBuildRequest(aiBrain, kind)
        elseif kind == 'sea' or kind == 'naval' then
            return recovery.ForceFactoryRecovery and director and director.NavalActive and seaFactories <= 0 and ApproveFactoryBuildRequest(aiBrain, kind)
        end
        return false
    end

    if kind == 'land' then
        local target = 1
        if now >= 140 then
            target = 2
        end
        if now >= 320 then
            target = 3
        end
        if now >= 620 then
            target = 4
        end
        return landFactories < target and ApproveFactoryBuildRequest(aiBrain, kind)
    elseif kind == 'air' then
        local target = 0
        if now >= 210 then
            target = 1
        end
        if now >= 520 then
            target = 2
        end
        return airFactories < target and ApproveFactoryBuildRequest(aiBrain, kind)
    elseif kind == 'sea' or kind == 'naval' then
        local navalActive = director and director.NavalActive
        return navalActive and seaFactories < 1 and ApproveFactoryBuildRequest(aiBrain, kind)
    end
    return false
end

function ShouldBuildT1LandRole(aiBrain, role)
    if not IsOvermindBrain(aiBrain) then
        return false
    end
    local key = string.lower(role or '')
    local now = GetGameTimeSeconds()
    local bomberPanic = IsBomberPanic(aiBrain)
    local bomberWatch = IsBomberWatch(aiBrain)
    local exposedMexAirRaid = IsExposedMexAirRaid(aiBrain)
    local director = GetProductionDirector(aiBrain)
    local econBootstrap = IsEconomyBootstrapState(aiBrain)
    if econBootstrap and not IsUnderLandHarass(aiBrain, 1) and not IsUnderAirHarass(aiBrain, 1) and not bomberPanic and not exposedMexAirRaid then
        return false
    end
    local rolePlan = director and director.RolePlan or false
    local entry = false
    if rolePlan then
        if key == 'tank' then
            entry = rolePlan.LandDirect
        elseif key == 'aa' then
            entry = rolePlan.LandAA
        elseif key == 'indirect' or key == 'arty' or key == 'artillery' then
            entry = rolePlan.LandIndirect
        elseif key == 'scout' then
            entry = rolePlan.LandScout
        end
    end

    if entry then
        local minUnits = 0
        if key == 'aa' and (bomberPanic or exposedMexAirRaid or bomberWatch) then
            local floor = 0
            if bomberPanic or exposedMexAirRaid then
                floor = (now < 480) and 5 or 7
            else
                floor = (now < 480) and 3 or 4
            end
            minUnits = math.max(minUnits, floor)
        end
        return RolePlanNeedsMore(entry, minUnits)
    end

    local landCombat = GetUnitCount(aiBrain, categories.MOBILE * categories.LAND * categories.TECH1 - categories.ENGINEER - categories.SCOUT - categories.COMMAND)
    local landAA = GetUnitCount(aiBrain, categories.MOBILE * categories.LAND * categories.ANTIAIR * categories.TECH1 - categories.ENGINEER - categories.SCOUT - categories.COMMAND)
    local landIndirect = GetUnitCount(aiBrain, categories.MOBILE * categories.LAND * categories.INDIRECTFIRE * categories.TECH1 - categories.ENGINEER - categories.SCOUT - categories.COMMAND)
    local landScout = GetUnitCount(aiBrain, categories.MOBILE * categories.LAND * categories.SCOUT * categories.TECH1)
    local landTank = math.max(0, landCombat - landAA - landIndirect)
    if key == 'tank' then
        local target = (now < 360) and 10 or 18
        return landTank < target
    elseif key == 'aa' then
        local target = 2 + math.floor(now / 260)
        if bomberPanic or exposedMexAirRaid then
            target = math.max(target, (now < 480) and 5 or 7)
        elseif bomberWatch then
            target = math.max(target, (now < 480) and 3 or 4)
        end
        return landAA < target
    elseif key == 'indirect' or key == 'arty' or key == 'artillery' then
        local target = 1 + math.floor(now / 320)
        return landIndirect < target
    elseif key == 'scout' then
        local target = (now > 300) and 3 or 2
        return landScout < target
    end
    return false
end

function ShouldBuildT1AirRole(aiBrain, role)
    if not IsOvermindBrain(aiBrain) then
        return false
    end
    local key = string.lower(role or '')
    local now = GetGameTimeSeconds()
    local director = GetProductionDirector(aiBrain)
    local bomberPanic = IsBomberPanic(aiBrain)
    local bomberWatch = IsBomberWatch(aiBrain)
    local exposedMexAirRaid = IsExposedMexAirRaid(aiBrain)
    local econBootstrap = IsEconomyBootstrapState(aiBrain)
    if econBootstrap and not IsUnderAirHarass(aiBrain, 1) and not IsUnderBomberHarass(aiBrain, 1) and not exposedMexAirRaid then
        return false
    end
    local rolePlan = director and director.RolePlan or false
    local entry = false
    if rolePlan then
        if key == 'fighter' then
            entry = rolePlan.AirFighter
        elseif key == 'bomber' then
            entry = rolePlan.AirBomber
        elseif key == 'scout' then
            entry = rolePlan.AirScout
        end
    end

    if entry then
        local minUnits = 0
        if key == 'fighter' and (bomberPanic or exposedMexAirRaid or bomberWatch) then
            minUnits = (now < 480)
                and ((bomberPanic or exposedMexAirRaid) and 4 or 2)
                or ((bomberPanic or exposedMexAirRaid) and 6 or 3)
        end
        return RolePlanNeedsMore(entry, minUnits)
    end

    local airFighter = GetUnitCount(aiBrain, categories.MOBILE * categories.AIR * categories.ANTIAIR * categories.TECH1 - categories.SCOUT - categories.TRANSPORTATION - categories.COMMAND)
    local airBomber = GetUnitCount(aiBrain, categories.MOBILE * categories.AIR * categories.BOMBER * categories.TECH1 - categories.SCOUT - categories.TRANSPORTATION - categories.COMMAND)
    local airScout = GetUnitCount(aiBrain, categories.MOBILE * categories.AIR * categories.SCOUT * categories.TECH1)
    if key == 'fighter' then
        local target = (now < 420) and 4 or 8
        if bomberPanic or exposedMexAirRaid then
            target = math.max(target, (now < 480) and 4 or 6)
        elseif bomberWatch then
            target = math.max(target, (now < 480) and 2 or 3)
        end
        return airFighter < target
    elseif key == 'bomber' then
        local target = (now < 420) and 2 or 6
        return airBomber < target
    elseif key == 'scout' then
        local target = (now > 300) and 5 or 3
        return airScout < target
    end
    return false
end

function ShouldBuildT1NavalRole(aiBrain, role)
    if not IsOvermindBrain(aiBrain) then
        return false
    end
    local director = GetProductionDirector(aiBrain)
    if not director or not director.NavalActive then
        return false
    end

    local key = string.lower(role or '')
    local rolePlan = director.RolePlan or false
    local entry = false
    if rolePlan then
        if key == 'frigate' then
            entry = rolePlan.SeaSurface
        elseif key == 'sub' then
            entry = rolePlan.SeaSub
        elseif key == 'aa' then
            entry = rolePlan.SeaAA
        end
    end
    if entry then
        return RolePlanNeedsMore(entry, 0)
    end
    return false
end

function ShouldBuildT1StructureRole(aiBrain, role)
    if not IsOvermindBrain(aiBrain) then
        return false
    end
    local key = string.lower(role or '')
    local structureKey = NormalizeStructureRole(key)
    local now = GetGameTimeSeconds()
    local bomberPanic = IsBomberPanic(aiBrain)
    local director = GetProductionDirector(aiBrain)
    local econBootstrap = IsEconomyBootstrapState(aiBrain)
    if econBootstrap and not IsUnderLandHarass(aiBrain, 1) and not IsUnderAirHarass(aiBrain, 1) and not bomberPanic then
        return false
    end
    if (structureKey == 'pd' or structureKey == 'aa') then
        if IsLowTechDefenseCapped(aiBrain, bomberPanic) then
            return false
        end
        if IsFirstHQPriorityState(aiBrain, 3) then
            local landHarass = IsUnderLandHarass(aiBrain, 3)
            local airHarass = IsUnderAirHarass(aiBrain, 3)
            if structureKey == 'pd' and not landHarass then
                return false
            end
            if structureKey == 'aa' and not airHarass and not bomberPanic then
                return false
            end
            local existingDefense = GetExistingUnitCount(aiBrain, categories.STRUCTURE * categories.DEFENSE * categories.TECH1)
            local cap = bomberPanic and 3 or 2
            if existingDefense >= cap then
                return false
            end
        end
        if IsStructureBuildClaimed(aiBrain, structureKey, now) or HasUnfinishedDefenseBuild(aiBrain, structureKey) or HasUnfinishedDefenseBuild(aiBrain, 'defense') then
            return false
        end
        if IsStructureMassBlocked(aiBrain) and not bomberPanic and not IsUnderLandHarass(aiBrain, 2) and not IsUnderAirHarass(aiBrain, 2) then
            return false
        end
    end
    local structurePlan = director and director.StructurePlan or false
    local current = director and director.Current or false
    local structures = current and current.Structures or false
    if structurePlan and structures then
        if key == 'radar' then
            if ShouldBypassGenericFirstRadar(aiBrain) then
                return false
            end
            if IsRadarBuildLocked(aiBrain, now) or IsRadarBuildClaimed(aiBrain, now) then
                return false
            end
            local totalRadar = GetUnitCount(aiBrain, categories.STRUCTURE * categories.RADAR * categories.TECH1)
            local completeRadar = GetCompletedUnitCount(aiBrain, categories.STRUCTURE * categories.RADAR * categories.TECH1)
            if totalRadar > completeRadar then
                return false
            end
            local need = (structures.Radar or 0) < (structurePlan.Radar or 0)
            if need then
                ClaimRadarBuild(aiBrain, 9, now)
            end
            return need
        elseif key == 'pd' or key == 'ground' then
            local need = (structures.PD or 0) < (structurePlan.PD or 0)
            if need then
                ClaimStructureBuild(aiBrain, 'pd', 30, now)
            end
            return need
        elseif key == 'aa' then
            local target = structurePlan.BaseAA or 0
            if IsBomberWatch(aiBrain) then
                target = math.max(target, 1)
            end
            if bomberPanic then
                target = math.max(target, (now < 520) and 2 or 3)
            end
            local need = (structures.BaseAA or 0) < target
            if need then
                ClaimStructureBuild(aiBrain, 'aa', 30, now)
            end
            return need
        elseif key == 'sonar' then
            return director.NavalActive and (structures.Sonar or 0) < (structurePlan.Sonar or 0)
        elseif key == 'navaldef' or key == 'torp' then
            return director.NavalActive and (structures.NavalDefense or 0) < (structurePlan.NavalDefense or 0)
        end
        return false
    end

    local radar = GetUnitCount(aiBrain, categories.STRUCTURE * categories.RADAR * categories.TECH1)
    local completeRadar = GetCompletedUnitCount(aiBrain, categories.STRUCTURE * categories.RADAR * categories.TECH1)
    local pd = GetUnitCount(aiBrain, categories.STRUCTURE * categories.DEFENSE * categories.DIRECTFIRE * categories.TECH1)
    local aa = GetUnitCount(aiBrain, categories.STRUCTURE * categories.DEFENSE * categories.ANTIAIR * categories.TECH1)
    if key == 'radar' then
        if ShouldBypassGenericFirstRadar(aiBrain) then
            return false
        end
        if IsRadarBuildLocked(aiBrain, now) or IsRadarBuildClaimed(aiBrain, now) then
            return false
        end
        if radar > completeRadar then
            return false
        end
        local need = radar < 1
        if need then
            ClaimRadarBuild(aiBrain, 9, now)
        end
        return need
    elseif key == 'pd' or key == 'ground' then
        local target = (now < 620) and 1 or 2
        local need = pd < target
        if need then
            ClaimStructureBuild(aiBrain, 'pd', 30, now)
        end
        return need
    elseif key == 'aa' then
        local target = (now < 420) and 1 or 2
        if IsBomberWatch(aiBrain) then
            target = math.max(target, 1)
        end
        if bomberPanic then
            target = math.max(target, (now < 520) and 2 or 3)
        end
        local need = aa < target
        if need then
            ClaimStructureBuild(aiBrain, 'aa', 30, now)
        end
        return need
    end
    return false
end
