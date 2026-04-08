local EngineerCategory = categories.ENGINEER * categories.MOBILE
local LandDirectCategory = categories.MOBILE * categories.LAND * categories.DIRECTFIRE
    - categories.ENGINEER - categories.SCOUT - categories.ANTIAIR - categories.COMMAND
local LandAACategory = categories.MOBILE * categories.LAND * categories.ANTIAIR
    - categories.ENGINEER - categories.SCOUT - categories.COMMAND
local LandIndirectCategory = categories.MOBILE * categories.LAND * categories.INDIRECTFIRE
    - categories.ENGINEER - categories.SCOUT - categories.COMMAND
local LandScoutCategory = categories.MOBILE * categories.LAND * categories.SCOUT - categories.ENGINEER

local AirFighterCategory = categories.MOBILE * categories.AIR * categories.ANTIAIR
    - categories.SCOUT - categories.TRANSPORTATION - categories.COMMAND
local AirBomberCategory = categories.MOBILE * categories.AIR * categories.BOMBER
    - categories.SCOUT - categories.TRANSPORTATION - categories.COMMAND
local AirScoutCategory = categories.MOBILE * categories.AIR * categories.SCOUT

local SeaSurfaceCategory = categories.MOBILE * categories.NAVAL
    - categories.SUBMERSIBLE - categories.ANTIAIR - categories.SCOUT - categories.ENGINEER - categories.COMMAND
local SeaSubCategory = categories.MOBILE * categories.NAVAL * categories.SUBMERSIBLE
local SeaAACategory = categories.MOBILE * categories.NAVAL * categories.ANTIAIR

local RoleWeightBaselines = {
    Engineer = 10,
    LandDirect = 65,
    LandAA = 60,
    LandIndirect = 90,
    LandScout = 35,
    AirFighter = 90,
    AirBomber = 120,
    AirScout = 45,
    SeaSurface = 180,
    SeaSub = 190,
    SeaAA = 180,
}

local RoleTargetStrengthRange = {
    Engineer = { 0.9, 4.8 },
    LandDirect = { 0.85, 3.2 },
    LandAA = { 0.85, 3.0 },
    LandIndirect = { 0.95, 3.6 },
    LandScout = { 0.75, 2.2 },
    AirFighter = { 0.9, 3.5 },
    AirBomber = { 0.95, 4.2 },
    AirScout = { 0.8, 2.4 },
    SeaSurface = { 1.0, 5.0 },
    SeaSub = { 1.0, 5.0 },
    SeaAA = { 1.0, 4.6 },
}

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

function GetUnitBlueprint(unit)
    if not unit or unit.Dead then
        return false
    end
    if unit.GetBlueprint then
        local ok, bp = pcall(function()
            return unit:GetBlueprint()
        end)
        if ok and type(bp) == 'table' then
            return bp
        end
    end
    return unit.Blueprint or false
end

function GetUnitRole(unit)
    if EntityCategoryContains(EngineerCategory, unit) then
        return 'Engineer'
    elseif EntityCategoryContains(LandDirectCategory, unit) then
        return 'LandDirect'
    elseif EntityCategoryContains(LandAACategory, unit) then
        return 'LandAA'
    elseif EntityCategoryContains(LandIndirectCategory, unit) then
        return 'LandIndirect'
    elseif EntityCategoryContains(LandScoutCategory, unit) then
        return 'LandScout'
    elseif EntityCategoryContains(AirFighterCategory, unit) then
        return 'AirFighter'
    elseif EntityCategoryContains(AirBomberCategory, unit) then
        return 'AirBomber'
    elseif EntityCategoryContains(AirScoutCategory, unit) then
        return 'AirScout'
    elseif EntityCategoryContains(SeaSurfaceCategory, unit) then
        return 'SeaSurface'
    elseif EntityCategoryContains(SeaSubCategory, unit) then
        return 'SeaSub'
    elseif EntityCategoryContains(SeaAACategory, unit) then
        return 'SeaAA'
    end
    return false
end

function GetBlueprintRoleWeight(roleName, bp)
    if roleName == 'Engineer' then
        local eco = bp and bp.Economy or false
        local buildRate = eco and eco.BuildRate or 10
        return Clamp(buildRate / 10, 0.75, 5.5)
    end

    local eco = bp and bp.Economy or false
    local defense = bp and bp.Defense or false
    local mass = eco and eco.BuildCostMass or 0
    local energy = eco and eco.BuildCostEnergy or 0
    local massEquivalent = mass + (energy * 0.012)
    local baseline = RoleWeightBaselines[roleName] or 70
    local health = defense and defense.Health or 0
    local healthScale = Clamp(0.92 + math.min(0.26, math.sqrt(math.max(1, health)) / 180), 0.9, 1.18)
    local weight = (massEquivalent / math.max(1, baseline)) * healthScale

    if roleName == 'LandScout' or roleName == 'AirScout' then
        return Clamp(weight, 0.5, 2.8)
    elseif roleName == 'AirBomber' then
        return Clamp(weight, 0.4, 5.5)
    elseif roleName == 'SeaSurface' or roleName == 'SeaSub' or roleName == 'SeaAA' then
        return Clamp(weight, 0.6, 7.5)
    end
    return Clamp(weight, 0.35, 6.5)
end

function GetFallbackUnitStrength(roleName)
    local range = RoleTargetStrengthRange[roleName] or { 0.9, 3.0 }
    return range[1]
end

function GetUnitStrength(unit)
    local roleName = GetUnitRole(unit)
    if not roleName then
        return 0, false
    end
    return GetBlueprintRoleWeight(roleName, GetUnitBlueprint(unit)), roleName
end

function SumUnitStrength(list)
    local total = 0
    for _, unit in list or {} do
        total = total + (GetUnitStrength(unit) or 0)
    end
    return Round(total, 2)
end

function AverageUnitStrength(list, roleName)
    local count = 0
    local total = 0
    for _, unit in list or {} do
        local strength, classifiedRole = GetUnitStrength(unit)
        if strength > 0 and (not roleName or classifiedRole == roleName) then
            count = count + 1
            total = total + strength
        end
    end
    if count <= 0 then
        return GetFallbackUnitStrength(roleName)
    end
    local range = RoleTargetStrengthRange[roleName] or { 0.75, 4.0 }
    return Clamp(total / count, range[1], range[2])
end

function GetRoleTargetUnitStrength(roleName, currentStrength, currentUnits)
    local range = RoleTargetStrengthRange[roleName] or { 0.9, 3.0 }
    local units = math.max(0, currentUnits or 0)
    local avg = units > 0 and ((currentStrength or 0) / units) or 1
    local target = math.max(range[1], avg)
    return Clamp(target, range[1], range[2])
end

function ComputeDesiredRoleStrength(roleName, desiredUnits, currentStrength, currentUnits)
    local units = math.max(0, math.floor((desiredUnits or 0) + 0.5))
    if units <= 0 then
        return 0
    end
    return Round(units * GetRoleTargetUnitStrength(roleName, currentStrength, currentUnits), 2)
end

local Module = {
    GetUnitBlueprint = GetUnitBlueprint,
    GetUnitRole = GetUnitRole,
    GetBlueprintRoleWeight = GetBlueprintRoleWeight,
    GetFallbackUnitStrength = GetFallbackUnitStrength,
    GetUnitStrength = GetUnitStrength,
    SumUnitStrength = SumUnitStrength,
    AverageUnitStrength = AverageUnitStrength,
    GetRoleTargetUnitStrength = GetRoleTargetUnitStrength,
    ComputeDesiredRoleStrength = ComputeDesiredRoleStrength,
}

return Module
