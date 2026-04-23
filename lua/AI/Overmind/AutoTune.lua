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
    Version = 2,
    CandidateId = 'baseline',
    ParentCandidateId = 'manual',
    Score = 0,
    FactoryFloorEarly = 2,
    FactoryFloorMid = 3,
    FactoryFloorLate = 5,
    FactoryRecoveryStagnation = 85,
    ScoutMinCount = 5,
    ACUOpeningMaxDistance = 16,
    ACUMidMaxDistance = 24,
    ACULateMaxDistance = 38,
    SafeExpandHotspotCapBias = 0,
    BaseEngineerFloorMin = 3,
    BaseEngineerFloorBias = 0,
    EngineerFactoryRatioBias = 0,
    FactoryMassIncomeBias = 0,
    FactoryEnergyIncomeBias = 0,
    FactoryMassRatioBias = 0,
    FactoryEnergyRatioBias = 0,
    FactoryMassPerFactoryBias = 0,
    FactoryToMexCapBias = 0,
    FactoryTempoBias = 0,
    SafeExpandDistanceBias = 0,
    SafeExpandThreatCapBias = 0,
    SafeExpandEnemyBufferBias = 0,
    ReclaimQuotaTimeBias = 0,
    ReclaimScoreBias = 0,
    ReclaimQuotaBias = 0,
    ExpansionQuotaBias = 0,
    UpgradeTimeBias = 0,
    AirFactoryTimeBias = 0,
    RadarTimeBias = 0,
    PowerNeedRatioBias = 0,
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
    cfg.BaseEngineerFloorBias = ClampNumber(cfg.BaseEngineerFloorBias, -1, 3, DefaultConfig.BaseEngineerFloorBias)
    cfg.EngineerFactoryRatioBias = ClampNumber(cfg.EngineerFactoryRatioBias, -0.25, 0.35, DefaultConfig.EngineerFactoryRatioBias)
    cfg.FactoryMassIncomeBias = ClampNumber(cfg.FactoryMassIncomeBias, -2.5, 2.5, DefaultConfig.FactoryMassIncomeBias)
    cfg.FactoryEnergyIncomeBias = ClampNumber(cfg.FactoryEnergyIncomeBias, -45, 45, DefaultConfig.FactoryEnergyIncomeBias)
    cfg.FactoryMassRatioBias = ClampNumber(cfg.FactoryMassRatioBias, -0.14, 0.14, DefaultConfig.FactoryMassRatioBias)
    cfg.FactoryEnergyRatioBias = ClampNumber(cfg.FactoryEnergyRatioBias, -0.16, 0.16, DefaultConfig.FactoryEnergyRatioBias)
    cfg.FactoryMassPerFactoryBias = ClampNumber(cfg.FactoryMassPerFactoryBias, -0.35, 0.35, DefaultConfig.FactoryMassPerFactoryBias)
    cfg.FactoryToMexCapBias = ClampNumber(cfg.FactoryToMexCapBias, -0.24, 0.24, DefaultConfig.FactoryToMexCapBias)
    cfg.FactoryTempoBias = ClampNumber(cfg.FactoryTempoBias, -0.35, 0.45, DefaultConfig.FactoryTempoBias)
    cfg.SafeExpandDistanceBias = ClampNumber(cfg.SafeExpandDistanceBias, -180, 240, DefaultConfig.SafeExpandDistanceBias)
    cfg.SafeExpandThreatCapBias = ClampNumber(cfg.SafeExpandThreatCapBias, -0.45, 0.65, DefaultConfig.SafeExpandThreatCapBias)
    cfg.SafeExpandEnemyBufferBias = ClampNumber(cfg.SafeExpandEnemyBufferBias, -45, 55, DefaultConfig.SafeExpandEnemyBufferBias)
    cfg.ReclaimQuotaTimeBias = ClampNumber(cfg.ReclaimQuotaTimeBias, -120, 180, DefaultConfig.ReclaimQuotaTimeBias)
    cfg.ReclaimScoreBias = ClampNumber(cfg.ReclaimScoreBias, -90, 110, DefaultConfig.ReclaimScoreBias)
    cfg.ReclaimQuotaBias = ClampNumber(cfg.ReclaimQuotaBias, -1, 2, DefaultConfig.ReclaimQuotaBias)
    cfg.ExpansionQuotaBias = ClampNumber(cfg.ExpansionQuotaBias, -1, 2, DefaultConfig.ExpansionQuotaBias)
    cfg.UpgradeTimeBias = ClampNumber(cfg.UpgradeTimeBias, -120, 210, DefaultConfig.UpgradeTimeBias)
    cfg.AirFactoryTimeBias = ClampNumber(cfg.AirFactoryTimeBias, -180, 240, DefaultConfig.AirFactoryTimeBias)
    cfg.RadarTimeBias = ClampNumber(cfg.RadarTimeBias, -180, 240, DefaultConfig.RadarTimeBias)
    cfg.PowerNeedRatioBias = ClampNumber(cfg.PowerNeedRatioBias, -0.14, 0.16, DefaultConfig.PowerNeedRatioBias)

    return cfg
end

function GetConfig(aiBrain)
    if CachedConfig then
        return CachedConfig
    end

    local source = false
    local ok, result = pcall(import, '/mods/OvermindAI/lua/AI/Overmind/AutoTuneConfig.lua')
    if ok and type(result) == 'table' then
        if type(result.Config) == 'table' then
            source = result.Config
        else
            source = result
        end
    end

    local cfg = MergeConfig(source)
    CachedConfig = cfg

    if aiBrain and aiBrain.GetArmyIndex and LOG then
        LOG(string.format('*OVERMIND AUTOTUNE A%d id=%s score=%.1f floor=%d/%d/%d scout=%d acu=%d/%d/%d facBias=%.2f reclaimBias=%.2f quotaBias=%.1f expandBias=%.1f riskBias=%.2f',
            aiBrain:GetArmyIndex(),
            tostring(cfg.CandidateId or 'baseline'),
            cfg.Score or 0,
            cfg.FactoryFloorEarly,
            cfg.FactoryFloorMid,
            cfg.FactoryFloorLate,
            cfg.ScoutMinCount,
            cfg.ACUOpeningMaxDistance,
            cfg.ACUMidMaxDistance,
            cfg.ACULateMaxDistance,
            cfg.FactoryTempoBias or 0,
            cfg.ReclaimScoreBias or 0,
            cfg.ReclaimQuotaBias or 0,
            cfg.ExpansionQuotaBias or 0,
            cfg.SafeExpandHotspotCapBias))
    end

    return cfg
end
