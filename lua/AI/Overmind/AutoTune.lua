local function ClampNumber(value, minV, maxV, fallback)
    if type(value) ~= 'number' then
        return fallback
    end
    if value < minV then
        return minV
    end
    if value > maxV then
        return maxV
    end
    return value
end

local DefaultConfig = {
    Version = 1,
    FactoryFloorEarly = 2,
    FactoryFloorMid = 3,
    FactoryFloorLate = 5,
    FactoryRecoveryStagnation = 85,
    ScoutMinCount = 3,
    ACUOpeningMaxDistance = 16,
    ACUMidMaxDistance = 24,
    ACULateMaxDistance = 38,
    SafeExpandHotspotCapBias = 0,
    BaseEngineerFloorMin = 3,
}

local CachedConfig = false

local function MergeConfig(source)
    local cfg = {}
    for key, value in DefaultConfig do
        cfg[key] = value
    end

    if type(source) == 'table' then
        for key, value in source do
            cfg[key] = value
        end
    end

    cfg.FactoryFloorEarly = ClampNumber(cfg.FactoryFloorEarly, 2, 7, DefaultConfig.FactoryFloorEarly)
    cfg.FactoryFloorMid = ClampNumber(cfg.FactoryFloorMid, 3, 10, DefaultConfig.FactoryFloorMid)
    cfg.FactoryFloorLate = ClampNumber(cfg.FactoryFloorLate, 4, 14, DefaultConfig.FactoryFloorLate)
    cfg.FactoryRecoveryStagnation = ClampNumber(cfg.FactoryRecoveryStagnation, 45, 220, DefaultConfig.FactoryRecoveryStagnation)
    cfg.ScoutMinCount = ClampNumber(cfg.ScoutMinCount, 1, 7, DefaultConfig.ScoutMinCount)
    cfg.ACUOpeningMaxDistance = ClampNumber(cfg.ACUOpeningMaxDistance, 16, 70, DefaultConfig.ACUOpeningMaxDistance)
    cfg.ACUMidMaxDistance = ClampNumber(cfg.ACUMidMaxDistance, 24, 100, DefaultConfig.ACUMidMaxDistance)
    cfg.ACULateMaxDistance = ClampNumber(cfg.ACULateMaxDistance, 35, 130, DefaultConfig.ACULateMaxDistance)
    cfg.SafeExpandHotspotCapBias = ClampNumber(cfg.SafeExpandHotspotCapBias, -4, 4, DefaultConfig.SafeExpandHotspotCapBias)
    cfg.BaseEngineerFloorMin = ClampNumber(cfg.BaseEngineerFloorMin, 2, 7, DefaultConfig.BaseEngineerFloorMin)

    return cfg
end

function GetConfig(aiBrain)
    if CachedConfig then
        return CachedConfig
    end

    local source = false
    local ok, result = pcall(import, '/mods/OvermindAI/lua/AI/Overmind/AutoTuneConfig.lua')
    if ok and type(result) == 'table' then
        source = result
    end

    local cfg = MergeConfig(source)
    CachedConfig = cfg

    if aiBrain and aiBrain.GetArmyIndex and LOG then
        LOG(string.format('*OVERMIND AUTOTUNE A%d floor=%d/%d/%d scout=%d acu=%d/%d/%d riskBias=%.2f',
            aiBrain:GetArmyIndex(),
            cfg.FactoryFloorEarly,
            cfg.FactoryFloorMid,
            cfg.FactoryFloorLate,
            cfg.ScoutMinCount,
            cfg.ACUOpeningMaxDistance,
            cfg.ACUMidMaxDistance,
            cfg.ACULateMaxDistance,
            cfg.SafeExpandHotspotCapBias))
    end

    return cfg
end
