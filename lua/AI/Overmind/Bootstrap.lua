local AIUtils = import('/lua/ai/aiutilities.lua')
local OvermindScheduler = import('/mods/OvermindAI/lua/AI/Overmind/Scheduler.lua')
local OvermindMemory = import('/mods/OvermindAI/lua/AI/Overmind/Memory.lua')

local ActiveBrains = {}
local BuildFingerprint = 'v270-single-owner-engineer-expansion'

local NavUtils = false
do
    local ok, mod = pcall(import, '/lua/sim/NavUtils.lua')
    if ok and type(mod) == 'table' then
        NavUtils = mod
    end
end

local function GetPersonality(aiBrain)
    if aiBrain.Personality then
        return aiBrain.Personality
    end

    if ScenarioInfo and ScenarioInfo.ArmySetup and ScenarioInfo.ArmySetup[aiBrain.Name] then
        return ScenarioInfo.ArmySetup[aiBrain.Name].AIPersonality or ''
    end

    return ''
end

function IsOvermindPersonality(personality)
    if not personality then
        return false
    end

    local lowerPersonality = string.lower(personality)
    return string.find(lowerPersonality, 'overmind') ~= nil
end

local function NormalizePersonality(aiBrain, rawPersonality)
    local isCheat = false
    local normalized = rawPersonality or ''

    if string.find(string.lower(normalized), 'cheat') then
        isCheat = true
        normalized = 'overmind'
    end

    aiBrain.OvermindCheat = isCheat
    aiBrain.OvermindPersonality = normalized

    if ScenarioInfo and ScenarioInfo.ArmySetup and ScenarioInfo.ArmySetup[aiBrain.Name] then
        ScenarioInfo.ArmySetup[aiBrain.Name].AIPersonality = normalized
    end

    aiBrain.Personality = normalized
end

local function Clamp(v, minV, maxV)
    if v < minV then
        return minV
    end
    if v > maxV then
        return maxV
    end
    return v
end

local function ToInt(value)
    if type(value) == 'number' then
        return math.floor(value)
    end
    if type(value) == 'string' then
        local parsed = tonumber(value)
        if parsed then
            return math.floor(parsed)
        end
    end
    return false
end

local function MixEntropy(seed, value)
    local s = ToInt(seed) or 0
    local v = ToInt(value) or 0
    return math.mod(((s * 1103515245) + (v * 12345) + 1013904223), 2147483647)
end

local function ResolveBrainAutomationData(aiBrain)
    if type(AutomationGetAIBrainData) ~= 'function' then
        return false
    end
    local ok, data = pcall(AutomationGetAIBrainData, aiBrain)
    if ok and type(data) == 'table' then
        return data
    end
    return false
end

local function BuildRandomizationProfile(aiBrain)
    local armyIndex = aiBrain:GetArmyIndex() or 1
    local sx, sz = aiBrain:GetArmyStartPos()
    local brainData = ResolveBrainAutomationData(aiBrain)

    local inputSeed = false
    local instanceId = false
    if brainData then
        inputSeed = ToInt(brainData.autorun_seed) or ToInt(brainData.random_seed) or ToInt(brainData.seed)
        instanceId = ToInt(brainData.autorun_instance) or ToInt(brainData.instance)
    end
    if not inputSeed and ScenarioInfo and ScenarioInfo.Options then
        inputSeed = ToInt(ScenarioInfo.Options.RandomSeed)
    end
    if not inputSeed and type(Random) == 'function' then
        local ok, randomSeed = pcall(function()
            return Random(1, 2147483000)
        end)
        if ok and type(randomSeed) == 'number' then
            inputSeed = math.floor(randomSeed)
        end
    end
    if not inputSeed then
        inputSeed = math.mod(((armyIndex * 7919) + math.floor(GetGameTimeSeconds() * 11)), 2147483000)
    end
    if not instanceId then
        instanceId = armyIndex
    end

    local entropy = 7919
    entropy = MixEntropy(entropy, inputSeed)
    entropy = MixEntropy(entropy, instanceId)
    entropy = MixEntropy(entropy, armyIndex * 131)
    entropy = MixEntropy(entropy, math.floor((sx or 0) * 10))
    entropy = MixEntropy(entropy, math.floor((sz or 0) * 10))

    local cadenceScale = Clamp(1 + ((((math.mod(entropy, 17)) - 8) * 0.01)), 0.90, 1.10)
    local tickBias = ((math.mod(math.floor(entropy / 17), 7)) - 3)
    local keyJitterBias = ((math.mod(math.floor(entropy / 43), 9)) - 4) * 0.02

    return {
        Seed = entropy,
        InputSeed = inputSeed,
        Instance = instanceId,
        CadenceScale = cadenceScale,
        TickBias = tickBias,
        KeyJitterBias = keyJitterBias,
        KeyIntervalJitter = {},
        KeyPhaseJitter = {},
        KeyAdvanceJitter = {},
        BrainData = brainData,
    }
end

function PreCreate(aiBrain)
    local personality = GetPersonality(aiBrain)

    if not IsOvermindPersonality(personality) then
        return
    end

    aiBrain.OvermindAI = true
    aiBrain.OvermindEnabled = true
    aiBrain.OvermindRawPersonality = personality

    NormalizePersonality(aiBrain, personality)

end

function PostCreate(aiBrain, planName)
    if not aiBrain.OvermindAI or aiBrain.OvermindStarted then
        return
    end

    aiBrain.OvermindStarted = true
    aiBrain.OvermindStartTime = GetGameTimeSeconds()
    ActiveBrains[aiBrain:GetArmyIndex()] = aiBrain
    aiBrain.OvermindRuntime = aiBrain.OvermindRuntime or {
        StrategyGoal = 'hold',
        GoalAggressionModifier = 0,
        Tuning = {
            AggressionBias = 0,
            EconPressureBias = 0,
        },
    }
    aiBrain.OvermindRuntime.BuildFingerprint = BuildFingerprint
    aiBrain.OvermindRuntime.Randomization = BuildRandomizationProfile(aiBrain)
    aiBrain.OvermindRuntime.FeatureFlags = {
        StrictACULeash = true,
        QueueInvariant = true,
        RadarDeadline = true,
        SecondaryBaseHardGate = true,
        BomberHarass = true,
        MexDefense = true,
        RuntimeContracts = true,
        SubsystemContracts = true,
        IntelModel = true,
        ForceDirector = true,
        ProductionDirector = true,
        TaskDrivenCombat = true,
        FactoryResume = true,
        ZoneGraph = true,
        ConfirmedScoutFreshness = true,
        ProductionPolicyCutover = true,
        WeightedRoleSupply = true,
        RuntimeModuleUpdateFix = true,
        EngineerFactoryTasks = true,
        StrategicPlanner = true,
        MacroController = true,
    }

    if aiBrain.OvermindCheat and not aiBrain.CheatEnabled then
        AIUtils.SetupCheat(aiBrain, true)
    end

    OvermindMemory.Init(aiBrain)
    if NavUtils and NavUtils.Generate and not ScenarioInfo.OvermindNavPrimed then
        ScenarioInfo.OvermindNavPrimed = true
        ForkThread(function()
            WaitTicks(1)
            pcall(NavUtils.Generate)
        end)
    end
    LOG(string.format('*OVERMIND BUILD A%d version=%s groups=%s',
        aiBrain:GetArmyIndex(),
        BuildFingerprint,
        'ProductionDirector,ForceDirector,StrategicPlanner,TaskDrivenCombat,EngineerFactoryTasks,FactoryResume,SubsystemContracts,FactoryController,RadarFallback,QueueExpansionGuard,BomberHarass,MexDefense,EngineerExpansion,CohortAttack,RuntimeContracts,IntelModel,ZoneGraph,ConfirmedScoutFreshness,ProductionPolicyCutover,WeightedRoleSupply,RuntimeModuleUpdateFix'))
    local randomization = aiBrain.OvermindRuntime.Randomization or {}
    LOG(string.format('*OVERMIND ENTROPY A%d seed=%d input=%d inst=%d cadence=%.3f tickBias=%d keyBias=%.2f',
        aiBrain:GetArmyIndex(),
        randomization.Seed or 0,
        randomization.InputSeed or 0,
        randomization.Instance or aiBrain:GetArmyIndex(),
        randomization.CadenceScale or 1,
        randomization.TickBias or 0,
        randomization.KeyJitterBias or 0))
    LOG(string.format('*OVERMIND SELFTEST A%d fingerprint=%s strictLeash=1 queueInvariant=1 radarDeadline=1 secondBaseGate=1 contracts=1 subsystem=1 intel=1 force=1 prod=1 strat=1 taskcombat=1 engfactasks=1 facresume=1 zgraph=1 scoutconfirm=1 prodcutover=1 weighted=1 runtimefix=1',
        aiBrain:GetArmyIndex(),
        BuildFingerprint))
    ForkThread(OvermindScheduler.Run, aiBrain)
end

function OnDefeat(aiBrain)
    if not aiBrain or not aiBrain.OvermindAI then
        return
    end

    ActiveBrains[aiBrain:GetArmyIndex()] = nil
    aiBrain.OvermindEnabled = false
end

function GetActiveBrains()
    return ActiveBrains
end



