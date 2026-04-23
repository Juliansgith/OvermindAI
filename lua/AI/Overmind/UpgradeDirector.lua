local OvermindMemory = import('/mods/OvermindAI/lua/AI/Overmind/Memory.lua')
local OvermindEconomyLedger = import('/mods/OvermindAI/lua/AI/Overmind/EconomyLedger.lua')

local Module = {}

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

local function GetEntityId(unit)
    if not unit or unit.Dead then
        return false
    end
    if unit.GetEntityId then
        local ok, id = pcall(function()
            return unit:GetEntityId()
        end)
        if ok and id then
            return tostring(id)
        end
    end
    return tostring(unit)
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

local function GetUpgradeBlueprintId(unit)
    if not unit or unit.Dead or not unit.GetBlueprint then
        return false
    end
    local bp = unit:GetBlueprint()
    if not bp or not bp.General then
        return false
    end
    local upgradeBp = bp.General.UpgradesTo
    if type(upgradeBp) ~= 'string' or upgradeBp == '' then
        return false
    end
    return upgradeBp
end

local function GetUnitTechLevel(unit)
    if not unit then
        return 0
    end
    if EntityCategoryContains(categories.TECH3, unit) then
        return 3
    elseif EntityCategoryContains(categories.TECH2, unit) then
        return 2
    elseif EntityCategoryContains(categories.TECH1, unit) then
        return 1
    end
    return 0
end

local function GetCommandQueueLength(unit)
    local q = unit and unit.GetCommandQueue and unit:GetCommandQueue() or false
    return q and table.getn(q) or 0
end

local function CountActiveMexUpgrades(aiBrain)
    local mexes = aiBrain:GetListOfUnits(categories.MASSEXTRACTION * categories.STRUCTURE, false, true) or {}
    local count = 0
    for _, mex in mexes do
        if mex and not mex.Dead and mex:IsUnitState('Upgrading') then
            count = count + 1
        end
    end
    return count
end

local function CountActiveLandFactoryUpgrades(aiBrain)
    local factories = aiBrain:GetListOfUnits(categories.FACTORY * categories.LAND * categories.STRUCTURE, false, true) or {}
    local count = 0
    for _, fac in factories do
        if fac and not fac.Dead and fac:IsUnitState('Upgrading') then
            count = count + 1
        end
    end
    return count
end

local function GetFactoryClusterPos(aiBrain, fallbackPos)
    local factories = aiBrain:GetListOfUnits(categories.FACTORY * categories.STRUCTURE, false, true) or {}
    local sx = 0
    local sz = 0
    local count = 0

    for _, fac in factories do
        if fac and not fac.Dead and IsReadyStructure(fac) and not fac:IsUnitState('Upgrading') and fac.GetPosition then
            local pos = fac:GetPosition()
            if pos then
                sx = sx + (pos[1] or 0)
                sz = sz + (pos[3] or 0)
                count = count + 1
            end
        end
    end

    if count >= 2 then
        return { sx / count, 0, sz / count }, count
    end

    return fallbackPos, count
end

local function ScoreSafeUpgradeLocation(aiBrain, pos, mainPos, anchorPos, localRadius)
    local risk = OvermindMemory.GetExpansionRisk(aiBrain, pos, 90)
    local threat = aiBrain:GetThreatAtPosition(pos, 1, true, 'AntiSurface') or 0
    local distMain = Distance2D(pos, mainPos)
    local distAnchor = anchorPos and Distance2D(pos, anchorPos) or distMain
    local dist = math.min(distMain, distAnchor)
    local localBias = (distMain <= localRadius) and 24 or 0
    local coreBias = (distMain <= 110 and 54)
        or (distMain <= 170 and 24)
        or (distMain <= 240 and 8)
        or 0
    local factoryRingBias = (distAnchor <= 85 and 92)
        or (distAnchor <= 135 and 54)
        or (distAnchor <= 200 and 22)
        or 0
    local score = 100 - (risk * 12) - (threat * 20) - (distMain * 0.03) - (distAnchor * 0.11) + localBias + coreBias + factoryRingBias
    return score, risk, threat, distMain, distAnchor
end

local function ClassifyMexScope(distMain, distAnchor)
    if distMain <= 150 and distAnchor <= 115 then
        return 'core'
    elseif distMain <= 240 and distAnchor <= 170 then
        return 'inner_local'
    elseif distMain <= 340 then
        return 'outer_local'
    end
    return 'remote'
end

local function CountActiveMexUpgradeScopes(aiBrain, mainPos, anchorPos, localRadius)
    local mexes = aiBrain:GetListOfUnits(categories.MASSEXTRACTION * categories.STRUCTURE, false, true) or {}
    local counts = {
        Total = 0,
        Core = 0,
        InnerLocal = 0,
        OuterLocal = 0,
        Remote = 0,
        Local = 0,
    }
    for _, mex in mexes do
        if mex and not mex.Dead and mex:IsUnitState('Upgrading') then
            local pos = mex.GetPosition and mex:GetPosition() or false
            if pos then
                local distMain = Distance2D(pos, mainPos)
                local distAnchor = anchorPos and Distance2D(pos, anchorPos) or distMain
                local scope = ClassifyMexScope(distMain, distAnchor)
                counts.Total = counts.Total + 1
                if scope == 'core' then
                    counts.Core = counts.Core + 1
                    counts.Local = counts.Local + 1
                elseif scope == 'inner_local' then
                    counts.InnerLocal = counts.InnerLocal + 1
                    counts.Local = counts.Local + 1
                elseif scope == 'outer_local' then
                    counts.OuterLocal = counts.OuterLocal + 1
                    if distMain <= localRadius then
                        counts.Local = counts.Local + 1
                    end
                else
                    counts.Remote = counts.Remote + 1
                end
            end
        end
    end
    return counts
end

local function ComputeDynamicMexCap(eco, readyLand, totalLand, powerReady, mexReady, surplusSpendWindow, strongSurplusWindow)
    if readyLand < 2 or totalLand < 3 or powerReady < 3 or mexReady < 4 then
        return 0
    end

    local cap = 1
    if surplusSpendWindow then
        cap = cap + 1
    end
    if strongSurplusWindow then
        cap = cap + 1
    end
    if readyLand >= 5 then
        cap = cap + 1
    end
    if totalLand >= 6 and (eco.MassIncome or 0) >= 10 then
        cap = cap + 1
    end
    if (eco.MassStorageRatio or 0) >= 0.58 and (eco.EnergyStorageRatio or 0) >= 0.44 then
        cap = cap + 1
    end
    if (eco.MassIncome or 0) >= 14 and (eco.EnergyIncome or 0) >= 200 and (eco.MassTrend or 0) >= 0.08 then
        cap = cap + math.max(0, math.floor(((eco.MassIncome or 0) - 10) / 4))
    end

    return math.max(1, cap)
end

local function ComputeEarlyMexUpgradeBudget(eco, readyLand, totalLand, powerReady, mexReady)
    if readyLand < 2 or totalLand < 2 or powerReady < 3 or mexReady < 4 then
        return 0, 0
    end

    local massIncome = eco.MassIncome or 0
    local massTrend = eco.MassTrend or 0
    local massStorage = eco.MassStorageRatio or 0
    local energyTrend = eco.EnergyTrend or 0
    local energyStorage = eco.EnergyStorageRatio or 0

    local effectiveBudget = massIncome
        + math.max(0, massTrend * 8)
        + math.max(0, (massStorage - 0.08) * 10)
        + math.max(0, (energyStorage - 0.14) * 3)
        + math.max(0, readyLand - 2) * 0.6
        + math.max(0, mexReady - 4) * 0.35

    if energyTrend < -12 or energyStorage < 0.04 or massTrend < -0.34 or massStorage < 0.02 then
        return effectiveBudget, 0
    end

    local cap = 0
    if effectiveBudget >= 7.5 then
        cap = 1
    end
    if effectiveBudget >= 12.0 and massTrend >= -0.12 and massStorage >= 0.08 then
        cap = 2
    end

    return effectiveBudget, cap
end

local function GetMacroObjective(runtime)
    local macro = runtime and runtime.MacroController or false
    if type(macro) == 'table' and macro.Phase then
        return macro.Phase
    end
    local director = runtime and runtime.ProductionDirector or {}
    return director.MacroObjective or 'land_factory_floor'
end

local function PickMexTarget(aiBrain, runtime, state)
    local director = runtime.ProductionDirector or {}
    local current = director.Current or {}
    local techPlan = director.TechPlan or {}
    local constraints = director.ConstraintState or {}
    local policy = runtime.EcoPolicy or {}
    local planner = runtime.StrategicPlanner or {}
    local eco = runtime.EcoState or {}
    local confidence = director.Confidence or {}
    local zone = runtime.ZoneModel or {}
    local mainPos = GetMainPos(aiBrain, runtime)
    local factoryClusterPos = GetFactoryClusterPos(aiBrain, mainPos)
    local localRadius = 340
    local factories = current.Factories or {}
    local readyLand = ((factories.Land or {}).Ready) or 0
    local totalLand = ((factories.Land or {}).Total) or 0
    local powerReady = (((current.Eco or {}).Power or {}).Ready) or 0
    local mexReady = (((current.Eco or {}).Mex or {}).Ready) or 0
    local mapControl = zone.MapControl or 0
    local tempoMode = planner.TradeTechForTempo or planner.PunishGreed or techPlan.ExtractorUpgradeReason == 'tempo_mode'
    local prioritizeProduction = policy.PrioritizeProduction == true
    local contestMapMode = policy.ContestMapMode == true
    local focusOnT1Spam = policy.FocusOnT1Spam == true
    local localMexOnly = policy.LocalMexUpgradeOnly == true
    local policyMexConcurrency = policy.MexUpgradeConcurrency
    if policyMexConcurrency == nil then
        policyMexConcurrency = policy.LocalMexUpgradeMaxConcurrent or 2
    end
    local localMexConcurrentCap = math.max(1, policyMexConcurrency or 1)
    local frontSecure = policy.FrontSecure == true
    local outerMexShare = policy.OuterMexShare or 0
    local outerHoldShare = policy.OuterHoldShare or 0
    local safeForwardMexCount = policy.SafeForwardMexCount or 0
    local contestableZoneCount = policy.ContestableZoneCount or 0
    local scoutingDebt = techPlan.ExtractorUpgradeReason == 'scouting_debt'
    local surplusSpendWindow = constraints.SurplusSpendWindow == true
    local strongSurplusWindow = constraints.StrongSurplusWindow == true
    local macroObjective = GetMacroObjective(runtime)
    local frontUnsettled = contestMapMode
        and not frontSecure
        and (safeForwardMexCount >= 2 or outerMexShare >= 0.32 or contestableZoneCount >= 3)
    local frontUpgradeReopen = frontSecure
        and mapControl >= 0.44
        and contestableZoneCount <= 2
        and outerHoldShare >= 0.48
    local mexBudget, budgetT2Cap = ComputeEarlyMexUpgradeBudget(eco, readyLand, totalLand, powerReady, mexReady)
    local activeMexUpgrades = CountActiveMexUpgrades(aiBrain)
    local activeUpgradeScopes = CountActiveMexUpgradeScopes(aiBrain, mainPos, factoryClusterPos, localRadius)
    local stableFactoryFloor = readyLand >= 2
        and totalLand <= (readyLand + 1)
        and powerReady >= 3
        and mexReady >= 4
        and (eco.EnergyStorageRatio or 0) >= 0.05

    state.Managed = true
    state.TargetUnit = false
    state.TargetId = false
    state.TargetTech = false
    state.Scope = false
    state.Enabled = false
    state.Reason = 'none'
    state.Cap = 0
    state.Aggressive = false

    local hasLandHQ = (aiBrain:GetCurrentUnits(categories.FACTORY * categories.LAND * categories.STRUCTURE * (categories.TECH2 + categories.TECH3)) or 0) > 0
    local hqPressureEscape = ((runtime.MacroController or {}).HQPressureEscape == true)
    local factoryDirective = ((runtime.UpgradeDirector or {}).Factory) or {}
    local firstHQObjective = macroObjective == 'starter_mex_claim'
        or macroObjective == 'mass_consolidation'
        or macroObjective == 'first_land_hq'
        or macroObjective == 'first_t2_engineer'
        or macroObjective == 'first_t2_power'
    local reserveForFirstHQ = not hasLandHQ
        and (hqPressureEscape or factoryDirective.NeedsFirstLandHQ == true or firstHQObjective)
        and readyLand >= 2
        and mexReady <= 8

    local allowBudgetThroughFactoryRecovery = constraints.CriticalFactory
        and budgetT2Cap >= 1
        and activeMexUpgrades <= 0
        and stableFactoryFloor
        and not constraints.CriticalStructure
        and not constraints.EcoCrash
        and not constraints.QueueStarved
    if constraints.CriticalFactory or constraints.CriticalStructure or constraints.EcoCrash or constraints.QueueStarved then
        if not ((constraints.CriticalFactory and stableFactoryFloor and not constraints.CriticalStructure and not constraints.EcoCrash and not constraints.QueueStarved) or allowBudgetThroughFactoryRecovery) then
            state.Reason = constraints.CriticalFactory and 'critical_factory' or constraints.CriticalStructure and 'critical_structure' or constraints.EcoCrash and 'eco_crash' or 'queue_starved'
            state.InFlight = activeMexUpgrades
            return
        end
    end

    state.InFlight = activeMexUpgrades
    state.LocalInFlight = activeUpgradeScopes.Local or 0
    state.RemoteInFlight = activeUpgradeScopes.Remote or 0
    if reserveForFirstHQ and activeMexUpgrades <= 0 then
        state.Reason = 'first_hq_reserved'
        state.Cap = 0
        return
    end
    if (policyMexConcurrency or 0) <= 0 and activeMexUpgrades <= 0 then
        state.Reason = 'policy_hold'
        state.Cap = 0
        return
    end
    local inflightTarget = false
    local inflightTargetTech = false
    local inflightTargetScope = false

    local allowLocalT2 = readyLand >= 2
        and totalLand >= 2
        and powerReady >= 3
        and mexReady >= 4
        and (eco.MassIncome or 0) >= 2.3
        and (eco.EnergyIncome or 0) >= 28
        and (eco.MassTrend or 0) >= -0.34
        and (eco.EnergyTrend or 0) >= -12
        and (eco.EnergyStorageRatio or 0) >= 0.05
        and not constraints.LandPanic
        and not constraints.AirPanic
    if budgetT2Cap >= 1 then
        allowLocalT2 = true
    end
    if surplusSpendWindow and readyLand >= 4 and powerReady >= 4 and mexReady >= 5 then
        allowLocalT2 = true
    end

    local allowGeneralT2 = techPlan.UpgradeExtractors == true
        and (eco.MassIncome or 0) >= 3.2
        and (eco.EnergyIncome or 0) >= 40
        and (eco.MassStorageRatio or 0) >= 0.16
        and (eco.EnergyStorageRatio or 0) >= 0.14
        and (confidence.Global or 0) >= 0.55
    if budgetT2Cap >= 1 then
        allowGeneralT2 = true
    end
    if surplusSpendWindow and readyLand >= 4 and powerReady >= 4 and mexReady >= 5 and not constraints.LandPanic and not constraints.AirPanic then
        allowGeneralT2 = true
    end
    if localMexOnly and not strongSurplusWindow then
        allowGeneralT2 = false
    elseif frontUnsettled and not surplusSpendWindow and not strongSurplusWindow then
        allowGeneralT2 = false
    elseif frontUpgradeReopen and budgetT2Cap >= 1 then
        allowGeneralT2 = true
    end
    if focusOnT1Spam then
        allowGeneralT2 = false
    end

    local allowTech3 = techPlan.UpgradeExtractors == true
        and not tempoMode
        and not scoutingDebt
        and readyLand >= 4
        and powerReady >= 5
        and mexReady >= 4
        and (eco.MassIncome or 0) >= 5
        and (eco.EnergyIncome or 0) >= 70
        and (eco.MassStorageRatio or 0) >= 0.24
        and (eco.EnergyStorageRatio or 0) >= 0.24
        and (eco.MassTrend or 0) >= -0.05
        and (eco.EnergyTrend or 0) >= 2
        and (confidence.Global or 0) >= 0.62
        and mapControl >= 0.42
    if strongSurplusWindow and not tempoMode and not scoutingDebt and readyLand >= 5 and powerReady >= 5 and mexReady >= 5 then
        allowTech3 = true
    end
    if contestMapMode or focusOnT1Spam then
        allowTech3 = false
    end
    local dynamicT2Cap = math.max(policyMexConcurrency or 0, budgetT2Cap, ComputeDynamicMexCap(eco, readyLand, totalLand, powerReady, mexReady, surplusSpendWindow, strongSurplusWindow))
    if macroObjective == 'mass_consolidation' then
        dynamicT2Cap = math.max(dynamicT2Cap, math.max(1, budgetT2Cap))
    elseif macroObjective == 'first_land_hq' or macroObjective == 'first_t2_engineer' or macroObjective == 'first_t2_power' then
        dynamicT2Cap = math.min(dynamicT2Cap, 1)
    end
    if localMexOnly then
        dynamicT2Cap = math.min(dynamicT2Cap, localMexConcurrentCap)
    end
    if frontUnsettled and not strongSurplusWindow then
        dynamicT2Cap = math.min(dynamicT2Cap, 1)
    end

    if activeMexUpgrades > 0 then
        local activeMexes = aiBrain:GetListOfUnits(categories.MASSEXTRACTION * categories.STRUCTURE, false, true) or {}
        for _, mex in activeMexes do
            if mex and not mex.Dead and mex:IsUnitState('Upgrading') then
                local pos = mex.GetPosition and mex:GetPosition() or false
                local dist = pos and Distance2D(pos, mainPos) or 999
                inflightTarget = mex
                inflightTargetTech = GetUnitTechLevel(mex) >= 3 and 'tech3' or 'tech2'
                inflightTargetScope = (dist <= localRadius) and 'local' or 'remote'
                break
            end
        end
    end

    if activeMexUpgrades <= 0 and (macroObjective == 'bootstrap_factory'
        or macroObjective == 'starter_mex_claim'
        or macroObjective == 'land_factory_floor'
        or macroObjective == 'first_land_hq'
        or macroObjective == 'first_t2_engineer'
        or macroObjective == 'first_t2_power') then
        state.Reason = 'objective_hold'
        state.Cap = 0
        return
    end

    if focusOnT1Spam and not strongSurplusWindow and not frontUpgradeReopen and (policyMexConcurrency or 0) <= 0 then
        state.Reason = 't1_spam'
        state.Cap = 0
        return
    end

    local best = false
    local bestTech = false
    local bestScope = false
    local bestScore = -999999

    local mexes = aiBrain:GetListOfUnits(categories.MASSEXTRACTION * categories.STRUCTURE, false, true) or {}
    for _, mex in mexes do
        if mex and not mex.Dead and IsReadyStructure(mex) and not mex:IsUnitState('Upgrading') then
            local tech = GetUnitTechLevel(mex)
            local pos = mex.GetPosition and mex:GetPosition() or false
            local upgradeBp = GetUpgradeBlueprintId(mex)
            if pos and upgradeBp then
                local score, risk, threat, distMain, distAnchor = ScoreSafeUpgradeLocation(aiBrain, pos, mainPos, factoryClusterPos, localRadius)
                if macroObjective == 'mass_consolidation' then
                    score = score + 38
                elseif macroObjective == 'surplus_scale' then
                    score = score + 10
                end
                local isLocal = distMain <= localRadius
                local scopeClass = ClassifyMexScope(distMain, distAnchor)
                local localScopeEligible = scopeClass == 'core' or scopeClass == 'inner_local' or ((not localMexOnly) and scopeClass == 'outer_local')
                local localRiskCap = (budgetT2Cap >= 1) and 3.8 or 3.2
                local localThreatCap = (budgetT2Cap >= 1) and 2.2 or 1.8
                if tech == 1 and allowLocalT2 and isLocal and localScopeEligible and risk <= localRiskCap and threat <= localThreatCap then
                    local localScore = score
                        + 90
                        + (tempoMode and 55 or 20)
                        + (scoutingDebt and 28 or 0)
                        + (surplusSpendWindow and 26 or 0)
                        + (budgetT2Cap >= 1 and 56 or 0)
                        + math.min(30, math.max(0, mexBudget - 7.5) * 3.0)
                        + (distAnchor <= 85 and 36 or 0)
                        + (distAnchor <= 135 and 18 or 0)
                        + (scopeClass == 'core' and 160 or 0)
                        + (scopeClass == 'inner_local' and 70 or 0)
                        + (frontUpgradeReopen and scopeClass == 'outer_local' and 20 or 0)
                        - (scopeClass == 'outer_local' and 80 or 0)
                        - (scopeClass == 'remote' and 220 or 0)
                        - (frontUnsettled and scopeClass == 'outer_local' and 18 or 0)
                        - (distMain > 210 and 45 or 0)
                        - (distAnchor > 160 and 55 or 0)
                    if localScore > bestScore then
                        bestScore = localScore
                        best = mex
                        bestTech = 'tech2'
                        bestScope = scopeClass == 'core' and 'core' or 'local'
                    end
                elseif tech == 1 and allowGeneralT2 and not localMexOnly and risk <= (isLocal and 3.4 or 2.4) and threat <= (isLocal and 1.9 or 1.1) then
                    local generalScore = score + (isLocal and 70 or 28) + ((mapControl >= 0.5) and 10 or 0) + (surplusSpendWindow and 18 or 0) + (tempoMode and 18 or 0) + (scoutingDebt and 12 or 0)
                        + (scopeClass == 'core' and 120 or 0)
                        + (scopeClass == 'inner_local' and 45 or 0)
                        + (frontUpgradeReopen and scopeClass == 'outer_local' and 28 or 0)
                        - (scopeClass == 'outer_local' and 45 or 0)
                        - (scopeClass == 'remote' and 120 or 0)
                        - (frontUnsettled and scopeClass == 'outer_local' and 40 or 0)
                        - (frontUnsettled and scopeClass == 'remote' and 80 or 0)
                    if generalScore > bestScore then
                        bestScore = generalScore
                        best = mex
                        bestTech = 'tech2'
                        bestScope = scopeClass == 'core' and 'core' or (isLocal and 'local' or 'remote')
                    end
                elseif tech == 2 and allowTech3 and risk <= (isLocal and 2.8 or 2.0) and threat <= (isLocal and 1.6 or 0.9) then
                    local t3Score = score + (isLocal and 34 or 12)
                        + (scopeClass == 'core' and 90 or 0)
                        + (scopeClass == 'inner_local' and 35 or 0)
                        - (scopeClass == 'outer_local' and 40 or 0)
                        - (scopeClass == 'remote' and 100 or 0)
                    if t3Score > bestScore then
                        bestScore = t3Score
                        best = mex
                        bestTech = 'tech3'
                        bestScope = scopeClass == 'core' and 'core' or (isLocal and 'local' or 'remote')
                    end
                end
            end
        end
    end

    if best then
        state.TargetUnit = best
        state.TargetId = GetEntityId(best)
        state.TargetTech = bestTech
        state.Scope = bestScope
        state.Enabled = true
        state.Reason = macroObjective == 'mass_consolidation' and bestTech == 'tech2' and 'objective_mass_consolidation'
            or localMexOnly and bestTech == 'tech2' and 'local_tempo_consolidation'
            or budgetT2Cap >= 1 and bestTech == 'tech2' and 'budget_consolidation'
            or tempoMode and bestTech == 'tech2' and 'tempo_consolidation'
            or surplusSpendWindow and bestTech == 'tech2' and 'surplus_consolidation'
            or scoutingDebt and bestTech == 'tech2' and 'scout_safe_consolidation'
            or bestTech == 'tech3' and 'safe_tech3'
            or 'safe_upgrade'
        state.Cap = (bestTech == 'tech3') and 1 or dynamicT2Cap
        state.Aggressive = state.Cap > 1
    elseif inflightTarget then
        state.TargetUnit = inflightTarget
        state.TargetId = GetEntityId(inflightTarget)
        state.TargetTech = inflightTargetTech
        state.Scope = inflightTargetScope
        state.Enabled = true
        state.Reason = 'in_flight'
        state.Cap = (inflightTargetTech == 'tech3') and 1 or dynamicT2Cap
        state.Aggressive = state.Cap > 1
    else
        state.Reason = (localMexOnly and activeUpgradeScopes.Local >= localMexConcurrentCap) and 'local_concurrency'
            or budgetT2Cap >= 1 and 'budget_wait'
            or tempoMode and not surplusSpendWindow and 'tempo_mode'
            or scoutingDebt and not surplusSpendWindow and 'safe_wait'
            or surplusSpendWindow and 'surplus_wait'
            or (techPlan.ExtractorUpgradeReason or 'macro_hold')
        state.Cap = budgetT2Cap
    end
end

local function MaybeStartMexUpgrade(aiBrain, now, state)
    local target = state.TargetUnit
    if not state.Enabled or not target or target.Dead then
        return
    end
    if state.InFlight >= math.max(1, state.Cap or 0) then
        return
    end
    if (state.NextMexIssueTime or -999) > now then
        return
    end
    if target:IsUnitState('Upgrading') then
        return
    end

    local upgradeBp = GetUpgradeBlueprintId(target)
    if not upgradeBp or not IssueUpgrade then
        return
    end

    IssueUpgrade({ target }, upgradeBp)
    state.LastMexIssueTime = now
    state.NextMexIssueTime = now + 2
    state.InFlight = (state.InFlight or 0) + 1
end

local function PickFactoryTarget(aiBrain, runtime, state, now)
    local director = runtime.ProductionDirector or {}
    local current = director.Current or {}
    local constraints = director.ConstraintState or {}
    local planner = runtime.StrategicPlanner or {}
    local macro = runtime.MacroController or {}
    local eco = runtime.EcoState or {}
    local macroObjective = GetMacroObjective(runtime)
    local mainPos = GetMainPos(aiBrain, runtime)
    local factoryClusterPos = GetFactoryClusterPos(aiBrain, mainPos)
    local factories = current.Factories or {}
    local landFactories = factories.Land or {}
    local readyLand = landFactories.Ready or 0
    local totalLand = landFactories.Total or 0
    local powerReady = (((current.Eco or {}).Power or {}).Ready) or 0
    local mexReady = (((current.Eco or {}).Mex or {}).Ready) or 0
    local upgradeCount = CountActiveLandFactoryUpgrades(aiBrain)
    local t2LandFactories = aiBrain:GetCurrentUnits(categories.FACTORY * categories.LAND * categories.STRUCTURE * categories.TECH2) or 0
    local factoryTask = current.FactoryTask or {}

    state.Managed = true
    state.TargetUnit = false
    state.TargetId = false
    state.Enabled = false
    state.Reason = 'none'
    state.TargetKind = 'land'
    state.UpgradeBp = false
    state.InFlight = upgradeCount
    state.PowerRecoveryWanted = false
    state.NeedsFirstLandHQ = false
    state.Mandatory = false

    local needsFirstHQOverall = t2LandFactories <= 0
    state.NeedsFirstLandHQ = needsFirstHQOverall and true or false
    state.Mandatory = needsFirstHQOverall and true or false
    state.PowerRecoveryWanted = constraints.PowerBufferLow and needsFirstHQOverall

    local firstHQEscapeFloorReady = readyLand >= 4
        and mexReady >= 5
        and powerReady >= 5
        and not constraints.EcoCrash
    local forceFirstHQAfterEscape = firstHQEscapeFloorReady
        and (
            now >= 480
            or readyLand >= 4
            or macro.NeedFirstLandHQ == true
        )
    if macro.HQPressureEscape == true and needsFirstHQOverall and not forceFirstHQAfterEscape then
        state.Reason = 'pressure_escape'
        state.NeedsFirstLandHQ = true
        state.Mandatory = false
        state.PowerRecoveryWanted = false
        return
    end

    if upgradeCount > 0 then
        local allFactories = aiBrain:GetListOfUnits(categories.FACTORY * categories.LAND * categories.STRUCTURE, false, true) or {}
        for _, fac in allFactories do
            if fac and not fac.Dead and fac:IsUnitState('Upgrading') then
                state.TargetUnit = fac
                state.TargetId = GetEntityId(fac)
                state.Enabled = true
                state.UpgradeBp = GetUpgradeBlueprintId(fac)
                state.Reason = needsFirstHQOverall and 'mandatory_first_hq_in_flight' or 'in_flight'
                return
            end
        end
        state.Reason = needsFirstHQOverall and 'mandatory_first_hq_in_flight' or 'in_flight'
        return
    end
    local stableLandFloor = readyLand >= 3
        and totalLand >= 3
        and totalLand <= (readyLand + 2)
        and powerReady >= 3
        and mexReady >= 3
    local stillNeedsFirstHQ = t2LandFactories <= 0 and upgradeCount <= 0
    local macroWantsHQ = macroObjective == 'first_land_hq'
        or macroObjective == 'first_t2_engineer'
        or macroObjective == 'first_t2_power'
        or macroObjective == 'surplus_scale'
    local mandatoryFirstHQ = stillNeedsFirstHQ
        and (stableLandFloor or (readyLand >= 4 and totalLand >= 4 and mexReady >= 3 and powerReady >= 3))
        and readyLand >= 3
        and totalLand >= 3
        and mexReady >= 3
        and not constraints.CriticalStructure
        and not constraints.EcoCrash
    if stillNeedsFirstHQ and macroWantsHQ and readyLand >= 3 and totalLand >= 3 and mexReady >= 4 and powerReady >= 3 then
        mandatoryFirstHQ = true
    end
    state.NeedsFirstLandHQ = stillNeedsFirstHQ and true or false
    state.Mandatory = mandatoryFirstHQ and true or false
    local landFactoryDebt = factoryTask.Active and factoryTask.Domain == 'Land'
    local airFactoryDebt = factoryTask.Active and factoryTask.Domain == 'Air'
    state.PowerRecoveryWanted = constraints.PowerBufferLow and (mandatoryFirstHQ or needsFirstHQOverall)
    if constraints.CriticalFactory or constraints.CriticalStructure or constraints.EcoCrash or constraints.QueueStarved or constraints.PowerBufferLow then
        local ignoreAirFactoryDebt = constraints.CriticalFactory
            and mandatoryFirstHQ
            and airFactoryDebt
            and not constraints.CriticalStructure
            and not constraints.EcoCrash
            and not constraints.QueueStarved
        local hqPowerOverride = constraints.PowerBufferLow
            and mandatoryFirstHQ
            and (
                powerReady >= 6
                or (
                    (eco.EnergyIncome or 0) >= 10
                    and (eco.EnergyStorageRatio or 0) >= 0.00
                    and (eco.EnergyTrend or 0) >= -10
                    and readyLand >= 4
                    and mexReady >= 4
                )
                or (
                    airFactoryDebt
                    and powerReady >= 5
                    and (eco.EnergyIncome or 0) >= 8
                    and (eco.EnergyTrend or 0) >= -12
                )
            )
        local hqFactoryOverride = ignoreAirFactoryDebt or (constraints.CriticalFactory
            and mandatoryFirstHQ
            and (not landFactoryDebt or airFactoryDebt)
            and not constraints.CriticalStructure
            and not constraints.EcoCrash
            and not constraints.QueueStarved
            and (eco.MassTrend or 0) >= -0.28
            and (eco.MassStorageRatio or 0) >= 0.02)
        local hqStructureOverride = constraints.CriticalStructure
            and mandatoryFirstHQ
            and firstHQEscapeFloorReady
            and readyLand >= 4
            and powerReady >= 6
            and not constraints.EcoCrash
            and not constraints.QueueStarved
            and (eco.EnergyTrend or 0) >= -18
            and (constraints.CriticalStructureKind ~= 'Power' or powerReady >= 8)
        if (hqPowerOverride or hqFactoryOverride or hqStructureOverride) and not constraints.EcoCrash and not constraints.QueueStarved then
            -- fall through
        else
            state.Reason = constraints.CriticalFactory and (airFactoryDebt and 'air_factory_debt' or 'critical_factory')
            or constraints.CriticalStructure and 'critical_structure'
            or constraints.EcoCrash and 'eco_crash'
            or constraints.QueueStarved and 'queue_starved'
            or 'power_buffer_low'
            return
        end
    end
    local surplusSpendWindow = constraints.SurplusSpendWindow == true
    local strongSurplusWindow = constraints.StrongSurplusWindow == true
    local firstHQMassIncomeFloor = mandatoryFirstHQ and ((airFactoryDebt and 1.5) or 1.7) or 3.2
    local firstHQEnergyIncomeFloor = mandatoryFirstHQ and ((airFactoryDebt and 8) or 10) or 58
    local firstHQMassStorageFloor = mandatoryFirstHQ and ((airFactoryDebt and 0.00) or 0.01) or 0.06
    local firstHQEnergyStorageFloor = mandatoryFirstHQ and 0.00 or 0.12
    local firstHQMassTrendFloor = mandatoryFirstHQ and ((airFactoryDebt and -0.70) or -0.55) or -0.14
    local firstHQEnergyTrendFloor = mandatoryFirstHQ and ((airFactoryDebt and -18) or -14) or -2

    if readyLand < 3 or totalLand < 3 or powerReady < 3 or mexReady < 3 then
        state.Reason = 'factory_floor'
        return
    end
    if not surplusSpendWindow and not macroWantsHQ and ((eco.MassIncome or 0) < firstHQMassIncomeFloor or (eco.EnergyIncome or 0) < firstHQEnergyIncomeFloor) then
        state.Reason = 'income_floor'
        return
    end
    if not surplusSpendWindow and not macroWantsHQ and ((eco.MassStorageRatio or 0) < firstHQMassStorageFloor or (eco.EnergyStorageRatio or 0) < firstHQEnergyStorageFloor) then
        state.Reason = 'storage_floor'
        return
    end
    if not surplusSpendWindow and not macroWantsHQ and ((eco.MassTrend or 0) < firstHQMassTrendFloor or (eco.EnergyTrend or 0) < firstHQEnergyTrendFloor) then
        state.Reason = 'trend_floor'
        return
    end
    if planner.TradeTechForTempo and readyLand < 4 and not surplusSpendWindow and not mandatoryFirstHQ and not macroWantsHQ then
        state.Reason = 'tempo_hold'
        return
    end
    if not strongSurplusWindow and not mandatoryFirstHQ and (eco.MassTrend or 0) < -0.08 then
        state.Reason = 'mass_floor'
        return
    end

    local best = false
    local bestScore = -999999
    local allFactories = aiBrain:GetListOfUnits(categories.FACTORY * categories.LAND * categories.STRUCTURE, false, true) or {}
    for _, fac in allFactories do
        if fac and not fac.Dead and IsReadyStructure(fac) and not fac:IsUnitState('Upgrading') and EntityCategoryContains(categories.TECH1, fac) then
            local upgradeBp = GetUpgradeBlueprintId(fac)
            local pos = fac.GetPosition and fac:GetPosition() or false
            if upgradeBp and pos and GetCommandQueueLength(fac) <= 0 then
                local score, risk, threat, dist, _ = ScoreSafeUpgradeLocation(aiBrain, pos, mainPos, factoryClusterPos, 280)
                local riskLimit = mandatoryFirstHQ and 4.2 or 3
                local threatLimit = mandatoryFirstHQ and 2.6 or 1.8
                if risk <= riskLimit and threat <= threatLimit then
                    local facScore = score + 80 - (dist * 0.04) + (surplusSpendWindow and 18 or 0) + (strongSurplusWindow and 12 or 0) + (readyLand >= 5 and 20 or 0) + (mandatoryFirstHQ and 40 or 0)
                    if facScore > bestScore then
                        bestScore = facScore
                        best = fac
                        state.UpgradeBp = upgradeBp
                    end
                end
            end
        end
    end

    if best then
        state.TargetUnit = best
        state.TargetId = GetEntityId(best)
        state.Enabled = true
        state.Reason = macroObjective == 'first_land_hq' and 'objective_first_land_hq'
            or mandatoryFirstHQ and 'mandatory_first_hq'
            or strongSurplusWindow and 'surplus_hq'
            or readyLand >= 5 and 'midgame_hq'
            or 'first_hq'
    elseif mandatoryFirstHQ then
        local forcedTarget = false
        local forcedBp = false
        local forcedScore = 999999
        local allFactories = aiBrain:GetListOfUnits(categories.FACTORY * categories.LAND * categories.STRUCTURE, false, true) or {}
        for _, fac in allFactories do
            if fac and not fac.Dead and IsReadyStructure(fac) and not fac:IsUnitState('Upgrading') and EntityCategoryContains(categories.TECH1, fac) then
                local upgradeBp = GetUpgradeBlueprintId(fac)
                local pos = fac.GetPosition and fac:GetPosition() or false
                if upgradeBp and pos and GetCommandQueueLength(fac) <= 1 then
                    local _, risk, threat, dist, _ = ScoreSafeUpgradeLocation(aiBrain, pos, mainPos, factoryClusterPos, 320)
                    if risk <= 6.0 and threat <= 4.0 then
                        local forcedValue = (risk * 10) + (threat * 8) + (dist * 0.03)
                        if forcedValue < forcedScore then
                            forcedScore = forcedValue
                            forcedTarget = fac
                            forcedBp = upgradeBp
                        end
                    end
                end
            end
        end
        if forcedTarget then
            state.TargetUnit = forcedTarget
            state.TargetId = GetEntityId(forcedTarget)
            state.Enabled = true
            state.UpgradeBp = forcedBp
            state.Reason = 'forced_first_hq'
        elseif forceFirstHQAfterEscape then
            local emergencyTarget = false
            local emergencyBp = false
            local emergencyScore = 999999
            local fallbackFactories = aiBrain:GetListOfUnits(categories.FACTORY * categories.LAND * categories.STRUCTURE, false, true) or {}
            for _, fac in fallbackFactories do
                if fac and not fac.Dead and IsReadyStructure(fac) and not fac:IsUnitState('Upgrading') and EntityCategoryContains(categories.TECH1, fac) then
                    local upgradeBp = GetUpgradeBlueprintId(fac)
                    local pos = fac.GetPosition and fac:GetPosition() or false
                    if upgradeBp and pos and fac:CanBuild(upgradeBp) and GetCommandQueueLength(fac) <= 1 then
                        local _, risk, threat, dist, _ = ScoreSafeUpgradeLocation(aiBrain, pos, mainPos, factoryClusterPos, 420)
                        local fallbackValue = (risk * 7) + (threat * 5) + (dist * 0.02)
                        if fallbackValue < emergencyScore then
                            emergencyScore = fallbackValue
                            emergencyTarget = fac
                            emergencyBp = upgradeBp
                        end
                    end
                end
            end
            if emergencyTarget then
                state.TargetUnit = emergencyTarget
                state.TargetId = GetEntityId(emergencyTarget)
                state.Enabled = true
                state.UpgradeBp = emergencyBp
                state.Reason = 'unsafe_forced_first_hq'
            else
                state.UpgradeBp = false
                state.Reason = 'no_factory_available'
            end
        else
            state.UpgradeBp = false
            state.Reason = 'no_safe_factory'
        end
    else
        state.UpgradeBp = false
        state.Reason = 'no_safe_factory'
    end
end

local function UpdateDirector(aiBrain, now)
    local runtime = aiBrain.OvermindRuntime or {}
    aiBrain.OvermindRuntime = runtime

    local state = runtime.UpgradeDirector or {
        Extractor = {},
        Factory = {},
        LastLogTime = -999,
    }
    runtime.UpgradeDirector = state
    state.Extractor = state.Extractor or {}
    state.Factory = state.Factory or {}

    PickFactoryTarget(aiBrain, runtime, state.Factory, now)
    PickMexTarget(aiBrain, runtime, state.Extractor)
    MaybeStartMexUpgrade(aiBrain, now, state.Extractor)

    OvermindEconomyLedger.PublishUpgradeActivity(aiBrain, runtime, now, {
        ActiveMexUpgrades = state.Extractor.InFlight or 0,
        TargetTech = state.Extractor.TargetTech or 'none',
        TargetScope = state.Extractor.Scope or 'none',
        Reason = state.Extractor.Reason or 'none',
        Cap = state.Extractor.Cap or 0,
        Enabled = state.Extractor.Enabled and true or false,
        LocalInFlight = state.Extractor.LocalInFlight or 0,
        RemoteInFlight = state.Extractor.RemoteInFlight or 0,
        FactoryEnabled = state.Factory.Enabled and true or false,
        FactoryReason = state.Factory.Reason or 'none',
    })

    if (now - (state.LastLogTime or -999)) >= 20 then
        state.LastLogTime = now
        LOG(string.format('*OVERMIND UPGDIR A%d t=%.1f obj=%s mex=%s:%s/%s cap=%d inflight=%d fac=%s:%s',
            aiBrain:GetArmyIndex(),
            now,
            GetMacroObjective(runtime),
            tostring(state.Extractor.TargetTech or 'none'),
            tostring(state.Extractor.Scope or 'none'),
            tostring(state.Extractor.Reason or 'none'),
            state.Extractor.Cap or 0,
            state.Extractor.InFlight or 0,
            tostring(state.Factory.Enabled and 'on' or 'off'),
            tostring(state.Factory.Reason or 'none')))
    end
end

Module.Update = UpdateDirector

function Update(aiBrain, now)
    return UpdateDirector(aiBrain, now)
end

return Module
