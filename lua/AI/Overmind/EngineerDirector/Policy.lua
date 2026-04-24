local Common = import('/mods/OvermindAI/lua/AI/Overmind/EngineerDirector/Common.lua')

local M = {}

local function NeedsBootstrapPower(aiBrain, runtime)
    local director = runtime and runtime.ProductionDirector or {}
    local constraints = director and director.ConstraintState or {}
    if constraints.EconBootstrap ~= true and constraints.StarterPhase ~= true then
        return false
    end
    local required = constraints.StarterPowerFloor or constraints.BootstrapPowerFloor or 1
    local units = aiBrain:GetListOfUnits(categories.ENERGYPRODUCTION * categories.STRUCTURE, false, true) or {}
    local ready = 0
    for _, unit in units do
        if unit and not unit.Dead and Common.GetFraction(unit) >= 0.95 and not unit:IsUnitState('BeingBuilt') then
            ready = ready + 1
        end
    end
    return ready < required
end

local function NeedsCriticalRadar(runtime)
    local prod = runtime and runtime.ProductionDirector or {}
    local constraints = prod.ConstraintState or {}
    local structurePlan = prod.StructurePlan or {}
    local current = prod.Current or {}
    local currentStructures = current.Structures or {}
    local eco = runtime and runtime.EcoState or {}
    local powerReady = (((current.Eco or {}).Power or {}).Ready) or 0
    return (structurePlan.RadarCritical == true
            or ((structurePlan.Radar or 0) > (currentStructures.Radar or 0))
            or (constraints.StarterRadarRequired == true and (currentStructures.Radar or 0) <= 0))
        and (currentStructures.Radar or 0) <= 0
        and powerReady > 0
        and (eco.EnergyStorageRatio or 0) > 0.02
        and (eco.EnergyTrend or 0) > -12
end

local function GetRadarReservedBuilderIds(runtime, now)
    local reserved = {}
    local radar = runtime and runtime.RadarFallback or false
    if radar and radar.DirectBuilderId and ((radar.DirectExpiresAt or -999) > now) then
        reserved[radar.DirectBuilderId] = true
    end
    return reserved
end


M.NeedsBootstrapPower = NeedsBootstrapPower
M.NeedsCriticalRadar = NeedsCriticalRadar
M.GetRadarReservedBuilderIds = GetRadarReservedBuilderIds

local ModuleEnv = getfenv(1)
rawset(ModuleEnv, 'NeedsBootstrapPower', NeedsBootstrapPower)
rawset(ModuleEnv, 'NeedsCriticalRadar', NeedsCriticalRadar)
rawset(ModuleEnv, 'GetRadarReservedBuilderIds', GetRadarReservedBuilderIds)
return M
