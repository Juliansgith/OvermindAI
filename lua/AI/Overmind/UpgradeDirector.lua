local OvermindMemory = import('/mods/OvermindAI/lua/AI/Overmind/Memory.lua')

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

local function PickMexTarget(aiBrain, runtime, state)
    local director = runtime.ProductionDirector or {}
    local current = director.Current or {}
    local techPlan = director.TechPlan or {}
    local constraints = director.ConstraintState or {}
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
    local scoutingDebt = techPlan.ExtractorUpgradeReason == 'scouting_debt'
    local surplusSpendWindow = constraints.SurplusSpendWindow == true
    local strongSurplusWindow = constraints.StrongSurplusWindow == true
    local mexBudget, budgetT2Cap = ComputeEarlyMexUpgradeBudget(eco, readyLand, totalLand, powerReady, mexReady)
    local activeMexUpgrades = CountActiveMexUpgrades(aiBrain)
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
    local dynamicT2Cap = math.max(budgetT2Cap, ComputeDynamicMexCap(eco, readyLand, totalLand, powerReady, mexReady, surplusSpendWindow, strongSurplusWindow))

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
                local isLocal = distMain <= localRadius
                local scopeClass = ClassifyMexScope(distMain, distAnchor)
                local localRiskCap = (budgetT2Cap >= 1) and 3.8 or 3.2
                local localThreatCap = (budgetT2Cap >= 1) and 2.2 or 1.8
                if tech == 1 and allowLocalT2 and isLocal and risk <= localRiskCap and threat <= localThreatCap then
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
                        - (scopeClass == 'outer_local' and 80 or 0)
                        - (scopeClass == 'remote' and 220 or 0)
                        - (distMain > 210 and 45 or 0)
                        - (distAnchor > 160 and 55 or 0)
                    if localScore > bestScore then
                        bestScore = localScore
                        best = mex
                        bestTech = 'tech2'
                        bestScope = scopeClass == 'core' and 'core' or 'local'
                    end
                elseif tech == 1 and allowGeneralT2 and risk <= (isLocal and 3.4 or 2.4) and threat <= (isLocal and 1.9 or 1.1) then
                    local generalScore = score + (isLocal and 70 or 28) + ((mapControl >= 0.5) and 10 or 0) + (surplusSpendWindow and 18 or 0) + (tempoMode and 18 or 0) + (scoutingDebt and 12 or 0)
                        + (scopeClass == 'core' and 120 or 0)
                        + (scopeClass == 'inner_local' and 45 or 0)
                        - (scopeClass == 'outer_local' and 45 or 0)
                        - (scopeClass == 'remote' and 120 or 0)
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
        state.Reason = budgetT2Cap >= 1 and bestTech == 'tech2' and 'budget_consolidation'
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
        state.Reason = budgetT2Cap >= 1 and 'budget_wait'
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

local function PickFactoryTarget(aiBrain, runtime, state)
    local director = runtime.ProductionDirector or {}
    local current = director.Current or {}
    local constraints = director.ConstraintState or {}
    local planner = runtime.StrategicPlanner or {}
    local eco = runtime.EcoState or {}
    local mainPos = GetMainPos(aiBrain, runtime)
    local factoryClusterPos = GetFactoryClusterPos(aiBrain, mainPos)
    local factories = current.Factories or {}
    local landFactories = factories.Land or {}
    local readyLand = landFactories.Ready or 0
    local totalLand = landFactories.Total or 0
    local powerReady = (((current.Eco or {}).Power or {}).Ready) or 0
    local mexReady = (((current.Eco or {}).Mex or {}).Ready) or 0
    local upgradeCount = CountActiveLandFactoryUpgrades(aiBrain)

    state.Managed = true
    state.TargetUnit = false
    state.TargetId = false
    state.Enabled = false
    state.Reason = 'none'
    state.TargetKind = 'land'
    state.UpgradeBp = false
    state.InFlight = upgradeCount

    if upgradeCount > 0 then
        local allFactories = aiBrain:GetListOfUnits(categories.FACTORY * categories.LAND * categories.STRUCTURE, false, true) or {}
        for _, fac in allFactories do
            if fac and not fac.Dead and fac:IsUnitState('Upgrading') then
                state.TargetUnit = fac
                state.TargetId = GetEntityId(fac)
                state.Enabled = true
                state.UpgradeBp = GetUpgradeBlueprintId(fac)
                state.Reason = 'in_flight'
                return
            end
        end
        state.Reason = 'in_flight'
        return
    end
    local stableLandFloor = readyLand >= 5 and totalLand <= readyLand and powerReady >= 5 and mexReady >= 5
    if constraints.CriticalFactory or constraints.CriticalStructure or constraints.EcoCrash or constraints.QueueStarved or constraints.PowerBufferLow then
        local hqPowerOverride = constraints.PowerBufferLow
            and stableLandFloor
            and (eco.EnergyStorageRatio or 0) >= 0.18
            and (eco.EnergyTrend or 0) >= 0
        local hqFactoryOverride = constraints.CriticalFactory
            and stableLandFloor
            and not constraints.CriticalStructure
            and not constraints.EcoCrash
            and not constraints.QueueStarved
        if (hqPowerOverride or hqFactoryOverride) and not constraints.CriticalStructure and not constraints.EcoCrash and not constraints.QueueStarved then
            -- fall through
        else
            state.Reason = constraints.CriticalFactory and 'critical_factory'
            or constraints.CriticalStructure and 'critical_structure'
            or constraints.EcoCrash and 'eco_crash'
            or constraints.QueueStarved and 'queue_starved'
            or 'power_buffer_low'
            return
        end
    end
    local surplusSpendWindow = constraints.SurplusSpendWindow == true
    local strongSurplusWindow = constraints.StrongSurplusWindow == true

    if readyLand < 4 or totalLand < 4 or powerReady < 4 or mexReady < 4 then
        state.Reason = 'factory_floor'
        return
    end
    if not surplusSpendWindow and ((eco.MassIncome or 0) < 3.2 or (eco.EnergyIncome or 0) < 58) then
        state.Reason = 'income_floor'
        return
    end
    if not surplusSpendWindow and ((eco.MassStorageRatio or 0) < 0.06 or (eco.EnergyStorageRatio or 0) < 0.12) then
        state.Reason = 'storage_floor'
        return
    end
    if not surplusSpendWindow and ((eco.MassTrend or 0) < -0.14 or (eco.EnergyTrend or 0) < -2) then
        state.Reason = 'trend_floor'
        return
    end
    if planner.TradeTechForTempo and readyLand < 5 and not surplusSpendWindow then
        state.Reason = 'tempo_hold'
        return
    end
    if not strongSurplusWindow and (eco.MassTrend or 0) < -0.08 then
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
                if risk <= 3 and threat <= 1.8 then
                    local facScore = score + 80 - (dist * 0.04) + (surplusSpendWindow and 18 or 0) + (strongSurplusWindow and 12 or 0) + (readyLand >= 5 and 20 or 0)
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
        state.Reason = strongSurplusWindow and 'surplus_hq'
            or readyLand >= 5 and 'midgame_hq'
            or 'first_hq'
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

    PickMexTarget(aiBrain, runtime, state.Extractor)
    MaybeStartMexUpgrade(aiBrain, now, state.Extractor)
    PickFactoryTarget(aiBrain, runtime, state.Factory)

    if (now - (state.LastLogTime or -999)) >= 20 then
        state.LastLogTime = now
        LOG(string.format('*OVERMIND UPGDIR A%d t=%.1f mex=%s:%s/%s cap=%d inflight=%d fac=%s:%s',
            aiBrain:GetArmyIndex(),
            now,
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
