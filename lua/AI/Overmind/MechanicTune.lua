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
    ProfileId = 'baseline',
    GeneratedAt = '',
    GeneratedBy = 'manual',
    ForceSideEscortAABias = 0,
    ForceACUEmergencyThreatScaleBias = 0,
    ForceACUEmergencyBaseNeedBias = 0,
    ForceACUEmergencyHoldBias = 0,
    ForceACUEmergencyCrisisShareBias = 0,
    CombatIndirectEscortBias = 0,
    CombatHeavyEscortBias = 0,
    CombatAASupportBias = 0,
    EngineerRepairThreatBias = 0,
    EngineerRepairDistanceBias = 0,
    EngineerRepairRouteRiskBias = 0,
    EngineerACURepairPriorityBias = 0,
    EngineerACURepairThreatBias = 0,
    EngineerACURepairDistanceBias = 0,
    EngineerACURepairHealthBias = 0,
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

    cfg.ForceSideEscortAABias = ClampNumber(cfg.ForceSideEscortAABias, -1, 2, DefaultConfig.ForceSideEscortAABias)
    cfg.ForceACUEmergencyThreatScaleBias = ClampNumber(cfg.ForceACUEmergencyThreatScaleBias, -0.16, 0.22, DefaultConfig.ForceACUEmergencyThreatScaleBias)
    cfg.ForceACUEmergencyBaseNeedBias = ClampNumber(cfg.ForceACUEmergencyBaseNeedBias, -4, 10, DefaultConfig.ForceACUEmergencyBaseNeedBias)
    cfg.ForceACUEmergencyHoldBias = ClampNumber(cfg.ForceACUEmergencyHoldBias, -8, 16, DefaultConfig.ForceACUEmergencyHoldBias)
    cfg.ForceACUEmergencyCrisisShareBias = ClampNumber(cfg.ForceACUEmergencyCrisisShareBias, -0.12, 0.18, DefaultConfig.ForceACUEmergencyCrisisShareBias)
    cfg.CombatIndirectEscortBias = ClampNumber(cfg.CombatIndirectEscortBias, -1, 2, DefaultConfig.CombatIndirectEscortBias)
    cfg.CombatHeavyEscortBias = ClampNumber(cfg.CombatHeavyEscortBias, -1, 2, DefaultConfig.CombatHeavyEscortBias)
    cfg.CombatAASupportBias = ClampNumber(cfg.CombatAASupportBias, -1, 2, DefaultConfig.CombatAASupportBias)
    cfg.EngineerRepairThreatBias = ClampNumber(cfg.EngineerRepairThreatBias, -0.45, 0.7, DefaultConfig.EngineerRepairThreatBias)
    cfg.EngineerRepairDistanceBias = ClampNumber(cfg.EngineerRepairDistanceBias, -80, 120, DefaultConfig.EngineerRepairDistanceBias)
    cfg.EngineerRepairRouteRiskBias = ClampNumber(cfg.EngineerRepairRouteRiskBias, -0.8, 1.2, DefaultConfig.EngineerRepairRouteRiskBias)
    cfg.EngineerACURepairPriorityBias = ClampNumber(cfg.EngineerACURepairPriorityBias, -120, 220, DefaultConfig.EngineerACURepairPriorityBias)
    cfg.EngineerACURepairThreatBias = ClampNumber(cfg.EngineerACURepairThreatBias, -0.35, 0.9, DefaultConfig.EngineerACURepairThreatBias)
    cfg.EngineerACURepairDistanceBias = ClampNumber(cfg.EngineerACURepairDistanceBias, -60, 140, DefaultConfig.EngineerACURepairDistanceBias)
    cfg.EngineerACURepairHealthBias = ClampNumber(cfg.EngineerACURepairHealthBias, -0.18, 0.26, DefaultConfig.EngineerACURepairHealthBias)

    return cfg
end

function GetConfig(aiBrain)
    if CachedConfig then
        return CachedConfig
    end

    local source = false
    local ok, result = pcall(import, '/mods/OvermindAI/lua/AI/Overmind/MechanicTuneConfig.lua')
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
        LOG(string.format('*OVERMIND MECHTUNE A%d id=%s escortAA=%.1f acu=%.2f/%.1f/%.1f repair=%.2f/%.0f/%.2f acuRepair=%.0f/%.2f/%.0f',
            aiBrain:GetArmyIndex(),
            tostring(cfg.ProfileId or 'baseline'),
            cfg.ForceSideEscortAABias or 0,
            cfg.ForceACUEmergencyThreatScaleBias or 0,
            cfg.ForceACUEmergencyBaseNeedBias or 0,
            cfg.ForceACUEmergencyCrisisShareBias or 0,
            cfg.EngineerRepairThreatBias or 0,
            cfg.EngineerRepairDistanceBias or 0,
            cfg.EngineerRepairRouteRiskBias or 0,
            cfg.EngineerACURepairPriorityBias or 0,
            cfg.EngineerACURepairThreatBias or 0,
            cfg.EngineerACURepairDistanceBias or 0))
    end

    return cfg
end

return {
    GetConfig = GetConfig,
}
