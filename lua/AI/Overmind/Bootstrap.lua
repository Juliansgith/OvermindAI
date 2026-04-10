local AIUtils = import('/lua/ai/aiutilities.lua')
local OvermindScheduler = import('/mods/OvermindAI/lua/AI/Overmind/Scheduler.lua')
local OvermindMemory = import('/mods/OvermindAI/lua/AI/Overmind/Memory.lua')

local ActiveBrains = {}
local BuildFingerprint = 'v151-advantage-commit-push'

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



