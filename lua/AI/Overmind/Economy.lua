local AIUtils = import('/lua/ai/aiutilities.lua')
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

local function GetUnitLoad(aiBrain)
    local unitCount = aiBrain:GetCurrentUnits(categories.ALLUNITS) or 0
    local cap = 1000
    if GetArmyUnitCap then
        cap = GetArmyUnitCap(aiBrain:GetArmyIndex()) or 1000
    end
    if cap <= 0 then
        cap = 1000
    end

    return unitCount, cap, unitCount / cap
end

function Update(aiBrain, now)
    local runtime = aiBrain.OvermindRuntime or {}
    aiBrain.OvermindRuntime = runtime

    local econNumbers = AIUtils.AIGetEconomyNumbers(aiBrain) or {}
    local massStored = aiBrain:GetEconomyStored('MASS') or 0
    local energyStored = aiBrain:GetEconomyStored('ENERGY') or 0
    local massTrend = econNumbers.MassTrend or aiBrain:GetEconomyTrend('MASS') or 0
    local energyTrend = econNumbers.EnergyTrend or aiBrain:GetEconomyTrend('ENERGY') or 0
    local massIncome = econNumbers.MassIncome or 0
    local energyIncome = econNumbers.EnergyIncome or 0
    local massRequested = econNumbers.MassRequested or 0
    local energyRequested = econNumbers.EnergyRequested or 0
    local massRatio = econNumbers.MassStorageRatio
    local energyRatio = econNumbers.EnergyStorageRatio
    local combatMomentum = OvermindMemory.GetCombatMomentum(aiBrain)
    local ecoMomentum = OvermindMemory.GetEconomicMomentum(aiBrain)
    local unitCount, unitCap, unitLoad = GetUnitLoad(aiBrain)
    local goalMod = runtime.GoalAggressionModifier or 0
    local tuning = runtime.Tuning or {}

    if massRatio == nil then
        local massStorage = econNumbers.MassStorage or 600
        if massStorage <= 0 then
            massStorage = 600
        end
        massRatio = massStored / massStorage
    end
    if energyRatio == nil then
        local energyStorage = econNumbers.EnergyStorage or 4000
        if energyStorage <= 0 then
            energyStorage = 4000
        end
        energyRatio = energyStored / energyStorage
    end

    massRatio = Clamp(massRatio or 0, 0, 1.5)
    energyRatio = Clamp(energyRatio or 0, 0, 1.5)

    local stallingMass = massStored < 125 and massTrend < -0.05
    local stallingEnergy = energyStored < 1500 and energyTrend < -2

    local aggression = 1.0
    aggression = aggression + combatMomentum * 0.55
    aggression = aggression + math.min(0.35, ecoMomentum * 0.25)

    if not stallingMass then
        aggression = aggression + 0.08
    else
        aggression = aggression - 0.18
    end

    if not stallingEnergy then
        aggression = aggression + 0.06
    else
        aggression = aggression - 0.15
    end

    if unitLoad > 0.9 then
        aggression = aggression + 0.2
    elseif unitLoad < 0.5 then
        aggression = aggression - 0.05
    end

    if aiBrain.OvermindCheat then
        aggression = aggression + 0.2
    end

    aggression = aggression + goalMod + (tuning.AggressionBias or 0)
    runtime.Aggression = Clamp(aggression, 0.5, 1.95)
    runtime.SpendPressure = Clamp((runtime.Aggression - 1) + (tuning.EconPressureBias or 0), -0.5, 1.0)
    runtime.CombatMomentum = combatMomentum
    runtime.EconomicMomentum = ecoMomentum
    runtime.EcoState = {
        MassStored = massStored,
        EnergyStored = energyStored,
        MassStorageRatio = massRatio,
        EnergyStorageRatio = energyRatio,
        MassTrend = massTrend,
        EnergyTrend = energyTrend,
        MassIncome = massIncome,
        EnergyIncome = energyIncome,
        MassRequested = massRequested,
        EnergyRequested = energyRequested,
        MassEfficiency = econNumbers.MassEfficiency or 0,
        EnergyEfficiency = econNumbers.EnergyEfficiency or 0,
        MassStorage = econNumbers.MassStorage or 0,
        EnergyStorage = econNumbers.EnergyStorage or 0,
        StallingMass = stallingMass,
        StallingEnergy = stallingEnergy,
        UnitCount = unitCount,
        UnitCap = unitCap,
        UnitLoad = unitLoad,
    }
    runtime.LastEconomyUpdate = now
end
