local M = {}

local function ComputeAirThreatFlags(runtime, now)
    local raid = runtime.RaidDefense or {}
    local constraints = ((runtime.ProductionDirector or {}).ConstraintState or {})
    local bomberWatch = constraints.BomberWatch == true
    local bomberPanic = ((raid.BomberPanicUntil or -999) > now) or ((raid.LastBomberEnemyCount or 0) >= 1 and raid.UnderAirHarass)
    local exposedMexAirRaid = raid.ExposedMexUnderAirRaid == true and raid.ExposedMexThreatPos ~= false
    return bomberWatch, bomberPanic, exposedMexAirRaid
end

local function HasEnemyCombatNear(aiBrain, pos, radius)
    if not aiBrain or not pos then
        return false
    end
    local count = aiBrain:GetNumUnitsAroundPoint(
        categories.MOBILE * (categories.LAND + categories.AIR + categories.NAVAL) - categories.ENGINEER - categories.SCOUT,
        pos,
        radius or 42,
        'Enemy'
    ) or 0
    return count > 0
end

M.ComputeAirThreatFlags = ComputeAirThreatFlags
M.HasEnemyCombatNear = HasEnemyCombatNear

local ModuleEnv = getfenv(1)
rawset(ModuleEnv, 'ComputeAirThreatFlags', ComputeAirThreatFlags)
rawset(ModuleEnv, 'HasEnemyCombatNear', HasEnemyCombatNear)
return M
