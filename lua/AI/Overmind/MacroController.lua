local Module = {
    Name = 'MacroController',
    StateSlice = 'MacroController',
}

local OvermindEconomySignals = import('/mods/OvermindAI/lua/AI/Overmind/EconomySignals.lua')

local TransitionPhases = {
    bootstrap_factory = true,
    starter_mex_claim = true,
    land_factory_floor = true,
    mass_consolidation = true,
    first_land_hq = true,
    first_t2_engineer = true,
    first_t2_power = true,
}

local function GetFraction(unit)
    if not unit or unit.Dead then
        return 0
    end
    if unit.GetFractionComplete then
        return unit:GetFractionComplete()
    end
    if unit.GetHealth and unit.GetMaxHealth then
        local maxHealth = math.max(1, unit:GetMaxHealth() or 1)
        return (unit:GetHealth() or 0) / maxHealth
    end
    return 1
end

local function IsReadyUnit(unit)
    return unit
        and not unit.Dead
        and GetFraction(unit) >= 0.95
        and not unit:IsUnitState('BeingBuilt')
        and not unit:IsUnitState('Upgrading')
end

local function CountUnits(aiBrain, category)
    return aiBrain:GetCurrentUnits(category) or 0
end

local function CountReadyUnits(aiBrain, category)
    local count = 0
    local units = aiBrain:GetListOfUnits(category, false, true) or {}
    for _, unit in units do
        if IsReadyUnit(unit) then
            count = count + 1
        end
    end
    return count
end

local function CountActiveLandFactoryUpgrades(aiBrain)
    local count = 0
    local units = aiBrain:GetListOfUnits(categories.FACTORY * categories.LAND * categories.STRUCTURE, false, true) or {}
    for _, unit in units do
        if unit and not unit.Dead and unit:IsUnitState('Upgrading') then
            count = count + 1
        end
    end
    return count
end

local function CountActiveMexUpgrades(aiBrain)
    local count = 0
    local units = aiBrain:GetListOfUnits(categories.MASSEXTRACTION * categories.STRUCTURE, false, true) or {}
    for _, unit in units do
        if unit and not unit.Dead and unit:IsUnitState('Upgrading') then
            count = count + 1
        end
    end
    return count
end

local function ComputeMassBudget(eco)
    eco = eco or {}
    return (eco.MassIncome or 0)
        + math.max(0, (eco.MassTrend or 0) * 8)
        + math.max(0, ((eco.MassStorageRatio or 0) - 0.04) * 10)
end

local function HasCriticalLandFactoryDebt(runtime, readyLand)
    local task = ((runtime.EngineerState or {}).UnfinishedFactoryTask) or {}
    if not task.Active or task.Domain ~= 'Land' then
        return false
    end
    if (task.ReadyFactories or 0) < math.max(1, math.min(2, readyLand or 0)) then
        return true
    end
    if (task.AssignedBuilders or 0) < math.max(1, task.RequiredBuilders or 0) then
        return true
    end
    if (task.StallTime or 0) >= 8 then
        return true
    end
    return false
end

local function DetermineDesiredPhase(aiBrain, runtime, now)
    local eco = runtime.EcoState or {}
    local policy = runtime.EcoPolicy or {}
    local recovery = runtime.Recovery or {}
    local economySignals = runtime.EconomySignals or {}
    local policySeed = economySignals.PolicySeed or {}
    local raid = runtime.RaidDefense or {}
    local opp = runtime.OpponentModel or {}
    local intel = runtime.IntelModel or {}
    local graph = runtime.ZoneGraph or {}
    local zone = runtime.ZoneModel or {}
    local constraints = ((runtime.ProductionDirector or {}).ConstraintState) or {}
    local readyLand = CountReadyUnits(aiBrain, categories.FACTORY * categories.LAND * categories.STRUCTURE)
    local totalLand = CountUnits(aiBrain, categories.FACTORY * categories.LAND * categories.STRUCTURE)
    local readyMex = CountReadyUnits(aiBrain, categories.MASSEXTRACTION * categories.STRUCTURE)
    local readyPower = CountReadyUnits(aiBrain, categories.ENERGYPRODUCTION * categories.STRUCTURE)
    local t2LandFactories = CountUnits(aiBrain, categories.FACTORY * categories.LAND * categories.STRUCTURE * (categories.TECH2 + categories.TECH3))
    local techEngineers = CountUnits(aiBrain, categories.ENGINEER * categories.MOBILE * (categories.TECH2 + categories.TECH3))
    local techPower = CountReadyUnits(aiBrain, categories.ENERGYPRODUCTION * categories.STRUCTURE * (categories.TECH2 + categories.TECH3))
    local activeLandFactoryUpgrades = CountActiveLandFactoryUpgrades(aiBrain)
    local activeMexUpgrades = CountActiveMexUpgrades(aiBrain)
    local criticalFactoryDebt = HasCriticalLandFactoryDebt(runtime, readyLand)
    local ecoCrash = ((eco.MassStorageRatio or 0) <= 0.01 and (eco.EnergyStorageRatio or 0) <= 0.01)
        or recovery.EcoCrash == true
    local underHarass = raid.UnderLandHarass == true or raid.UnderAirHarass == true
    local massBudget = ComputeMassBudget(eco)
    local contestedZones = intel.ContestedZones or graph.ContestedZones or 0
    local mapControl = intel.MapControl or graph.MapControl or zone.MapControl or 0
    local frontPressure = constraints.FrontPressure or 0
    local basePressure = constraints.BasePressure or 0
    local approachReal = constraints.ApproachReal == true
    local landPanic = constraints.LandPanic == true
    local acuCrisisActive = now < (runtime.ACUCrisisUntil or -999)
    local structure = OvermindEconomySignals.GetStructure(aiBrain, runtime, now)
    local contestTempoMap = structure.StructuralContestMap
        and (contestedZones >= 2 or structure.ContestableZoneCount >= 3)
        and now < 840
        and mapControl <= 0.62
        and (opp.RelativePower or 1) <= 1.08
    if policySeed.ContestMapMode == true then
        contestTempoMap = true
    end
    local focusOnT1Spam = policySeed.FocusOnT1Spam == true
        or (policy.FocusOnT1Spam == true and not structure.T1SpamSuppressedByFailure)
    local starterMexTarget = (contestTempoMap or focusOnT1Spam) and 5 or 6
    local starterMexDeadline = contestTempoMap and 420 or 540
    local landFactoryFloorTarget = (contestTempoMap or focusOnT1Spam) and 2 or 3
    local firstHQFloorReady = readyLand >= 4
        and readyMex >= 5
        and readyPower >= 5
        and not ecoCrash
    local pressureEscapeExpired = firstHQFloorReady
        and (
            now >= 660
            or (readyLand >= 5 and massBudget >= 4.8)
            or (readyLand >= 6 and now >= 540)
        )
    local hqPressureEscape = t2LandFactories <= 0
        and activeLandFactoryUpgrades <= 0
        and readyLand >= 2
        and not pressureEscapeExpired
        and (
            acuCrisisActive
            or ((landPanic or underHarass or approachReal) and (frontPressure >= 0.18 or basePressure >= 0.14))
            or (frontPressure >= 0.26 and basePressure >= 0.18)
        )

    local facts = {
        ReadyLandFactories = readyLand,
        TotalLandFactories = totalLand,
        ReadyMexes = readyMex,
        ReadyPower = readyPower,
        T2LandFactories = t2LandFactories,
        TechEngineers = techEngineers,
        TechPower = techPower,
        ActiveLandFactoryUpgrades = activeLandFactoryUpgrades,
        ActiveMexUpgrades = activeMexUpgrades,
        CriticalLandFactoryDebt = criticalFactoryDebt,
        EcoCrash = ecoCrash,
        UnderHarass = underHarass,
        ContestTempoMap = contestTempoMap,
        OuterMexShare = structure.OuterMexShare or 0,
        SafeForwardMexCount = structure.SafeForwardMexCount or 0,
        ContestableZoneCount = structure.ContestableZoneCount or 0,
        LandRouteDepth = structure.LandRouteDepth or 0,
        MassBudget = massBudget,
        EnergyTrend = eco.EnergyTrend or 0,
        MassTrend = eco.MassTrend or 0,
        FrontPressure = frontPressure,
        BasePressure = basePressure,
        HQPressureEscape = hqPressureEscape and true or false,
        FocusOnT1Spam = focusOnT1Spam and true or false,
        ACUCrisisActive = acuCrisisActive and true or false,
    }

    if readyLand <= 0 and totalLand <= 0 then
        return 'bootstrap_factory', 'missing_first_factory', facts
    end

    if readyLand >= 1 and readyPower >= 1 and readyMex < starterMexTarget and now < starterMexDeadline and not criticalFactoryDebt then
        return 'starter_mex_claim', 'starter_mex_gap', facts
    end

    if criticalFactoryDebt or readyLand < landFactoryFloorTarget or totalLand < landFactoryFloorTarget then
        return 'land_factory_floor', criticalFactoryDebt and 'critical_land_factory' or 'pre_hq_floor', facts
    end

    if t2LandFactories <= 0 then
        if hqPressureEscape then
            return 'mass_consolidation', 'hq_pressure_escape', facts
        end
        if focusOnT1Spam then
            if firstHQFloorReady and now >= 660 then
                return 'first_land_hq', 't1_spam_forced_hq', facts
            end
            if readyLand >= 4
                and readyMex >= 5
                and readyPower >= 4
                and massBudget >= 8.5
                and mapControl >= 0.42
                and not ecoCrash
                and not underHarass
                and not landPanic then
                return 'first_land_hq', 't1_spam_exit', facts
            end
            return 'mass_consolidation', 'focus_t1_spam', facts
        end
        if readyLand >= landFactoryFloorTarget and readyMex >= 4 and readyPower >= 3 then
            if activeLandFactoryUpgrades > 0 then
                return 'first_land_hq', 'hq_in_flight', facts
            end
            if contestTempoMap
                and readyLand < 4
                and readyMex >= 5
                and readyPower >= 3
                and massBudget >= 5.2
                and not ecoCrash
                and not underHarass then
                return 'mass_consolidation', 'contest_mode_tempo', facts
            end
            if massBudget >= 7.0 and not ecoCrash then
                return 'first_land_hq', 'phase_owned_hq', facts
            end
            if readyLand >= landFactoryFloorTarget and readyMex >= 4 and readyPower >= 3 and massBudget >= (contestTempoMap and 5.4 or 6.0) and not underHarass then
                return 'mass_consolidation', 'budget_window', facts
            end
            return 'first_land_hq', 'forced_transition', facts
        end
        return 'land_factory_floor', 'hq_floor', facts
    end

    if techEngineers <= 0 then
        return 'first_t2_engineer', 'missing_t2_engineer', facts
    end

    if techPower <= 0 and (readyPower < 5 or (eco.EnergyIncome or 0) < 90 or (eco.EnergyTrend or 0) < 4) then
        return 'first_t2_power', 'missing_t2_power', facts
    end

    return 'surplus_scale', 'post_t2_scale', facts
end

local function ApplyLatch(state, desiredPhase, desiredReason, facts, now)
    local current = state.Phase or false
    if not current then
        return desiredPhase, desiredReason
    end

    local starterLatchMexFloor = facts.ContestTempoMap and 5 or 6
    local starterLatchDeadline = facts.ContestTempoMap and 420 or 540
    if current == 'starter_mex_claim'
        and facts.ReadyMexes < starterLatchMexFloor
        and now < starterLatchDeadline
        and not facts.CriticalLandFactoryDebt then
        return current, 'latched_starter_mex_claim'
    end

    if current == 'land_factory_floor' and facts.CriticalLandFactoryDebt then
        return current, 'latched_land_factory_floor'
    end

    if current == 'mass_consolidation'
        and facts.HQPressureEscape
        and facts.T2LandFactories <= 0 then
        return current, 'latched_hq_pressure_escape'
    end

    if current == 'first_land_hq'
        and facts.HQPressureEscape
        and (now - (state.PhaseStartedAt or now)) >= 10 then
        return 'mass_consolidation', 'hq_pressure_escape'
    end

    if current == 'first_land_hq'
        and facts.T2LandFactories <= 0
        and (facts.ActiveLandFactoryUpgrades > 0 or (facts.ReadyLandFactories >= 2 and facts.ReadyMexes >= 4))
        and not facts.EcoCrash then
        return current, 'latched_first_land_hq'
    end

    if current == 'first_t2_engineer' and facts.TechEngineers <= 0 then
        return current, 'latched_first_t2_engineer'
    end

    if current == 'first_t2_power' and facts.TechPower <= 0 then
        return current, 'latched_first_t2_power'
    end

    return desiredPhase, desiredReason
end

function Module.Update(aiBrain, now)
    local runtime = aiBrain.OvermindRuntime or {}
    aiBrain.OvermindRuntime = runtime

    local state = runtime.MacroController or {
        Phase = 'bootstrap_factory',
        Reason = 'boot',
        PhaseStartedAt = now,
        LastLogTime = -999,
    }
    runtime.MacroController = state

    local desiredPhase, desiredReason, facts = DetermineDesiredPhase(aiBrain, runtime, now)
    local phase, reason = ApplyLatch(state, desiredPhase, desiredReason, facts, now)

    if phase ~= state.Phase then
        state.Phase = phase
        state.PhaseStartedAt = now
    end
    state.Reason = reason

    state.TransitionLocked = TransitionPhases[phase] == true
    state.HQPressureEscape = (facts.HQPressureEscape and phase ~= 'first_land_hq') and true or false
    state.SuppressAirExpansion = state.TransitionLocked and phase ~= 'surplus_scale'
    state.SuppressDefenseDrift = phase == 'bootstrap_factory'
        or phase == 'starter_mex_claim'
        or phase == 'land_factory_floor'
        or phase == 'first_land_hq'
        or phase == 'first_t2_engineer'
        or phase == 'first_t2_power'
    state.SuppressCombatPlanner = state.TransitionLocked and phase ~= 'surplus_scale'
    state.StrictACU = state.TransitionLocked
    state.NeedStarterMex = phase == 'starter_mex_claim'
    state.NeedFactoryRecovery = phase == 'land_factory_floor' or facts.CriticalLandFactoryDebt
    state.NeedMassConsolidation = phase == 'mass_consolidation'
    state.NeedFirstLandHQ = phase == 'first_land_hq'
    state.NeedFirstT2Engineer = phase == 'first_t2_engineer'
    state.NeedFirstT2Power = phase == 'first_t2_power'
    state.NeedUpgradeAssist = phase == 'first_land_hq' or phase == 'first_t2_engineer' or phase == 'first_t2_power'
    state.NeedPowerRecovery = (phase == 'first_land_hq' or phase == 'first_t2_power')
        and (facts.ReadyPower < 4 or facts.EnergyTrend < -6)
    state.Facts = facts
    state.LastUpdate = now

    if now - (state.LastLogTime or -999) >= 24 then
        state.LastLogTime = now
        LOG(string.format(
            '*OVERMIND MACROCTRL A%d t=%.1f phase=%s reason=%s lock=%d spam=%d land=%d/%d mex=%d pwr=%d hq=%d t2eng=%d t2pwr=%d budget=%.1f debt=%d outer=%.2f sfwd=%d contest=%d depth=%.1f',
            aiBrain:GetArmyIndex(),
            now,
            phase,
            reason,
            state.TransitionLocked and 1 or 0,
            facts.FocusOnT1Spam and 1 or 0,
            facts.ReadyLandFactories or 0,
            facts.TotalLandFactories or 0,
            facts.ReadyMexes or 0,
            facts.ReadyPower or 0,
            (facts.T2LandFactories or 0) + (facts.ActiveLandFactoryUpgrades or 0),
            facts.TechEngineers or 0,
            facts.TechPower or 0,
            facts.MassBudget or 0,
            facts.CriticalLandFactoryDebt and 1 or 0,
            facts.OuterMexShare or 0,
            facts.SafeForwardMexCount or 0,
            facts.ContestableZoneCount or 0,
            facts.LandRouteDepth or 0))
    end
end

function Update(aiBrain, now)
    return Module.Update(aiBrain, now)
end

return Module
