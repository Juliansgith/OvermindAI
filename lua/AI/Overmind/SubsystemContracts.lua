local OvermindMemory = import('/mods/OvermindAI/lua/AI/Overmind/Memory.lua')
local OvermindEconomy = import('/mods/OvermindAI/lua/AI/Overmind/Economy.lua')
local OvermindRuntimeContracts = import('/mods/OvermindAI/lua/AI/Overmind/RuntimeContracts.lua')
local OvermindCombat = import('/mods/OvermindAI/lua/AI/Overmind/Combat.lua')
local OvermindCombatExecution = import('/mods/OvermindAI/lua/AI/Overmind/CombatExecution.lua')
local OvermindBudget = import('/mods/OvermindAI/lua/AI/Overmind/Budget.lua')
local OvermindZoneGraph = import('/mods/OvermindAI/lua/AI/Overmind/ZoneGraph.lua')
local OvermindZoneModel = import('/mods/OvermindAI/lua/AI/Overmind/ZoneModel.lua')
local OvermindIntelModel = import('/mods/OvermindAI/lua/AI/Overmind/IntelModel.lua')
local OvermindEnemyClusterTracker = import('/mods/OvermindAI/lua/AI/Overmind/EnemyClusterTracker.lua')
local OvermindOpponentModel = import('/mods/OvermindAI/lua/AI/Overmind/OpponentModel.lua')
local OvermindStrategicPlanner = import('/mods/OvermindAI/lua/AI/Overmind/StrategicPlanner.lua')
local OvermindGoalSelector = import('/mods/OvermindAI/lua/AI/Overmind/GoalSelector.lua')
local OvermindEconomyOptimizer = import('/mods/OvermindAI/lua/AI/Overmind/EconomyOptimizer.lua')
local OvermindTactical = import('/mods/OvermindAI/lua/AI/Overmind/Tactical.lua')
local OvermindTelemetry = import('/mods/OvermindAI/lua/AI/Overmind/Telemetry.lua')
local OvermindWatchdog = import('/mods/OvermindAI/lua/AI/Overmind/Watchdog.lua')
local OvermindScoutManager = import('/mods/OvermindAI/lua/AI/Overmind/ScoutManager.lua')
local OvermindEngineerDirector = import('/mods/OvermindAI/lua/AI/Overmind/EngineerDirector.lua')
local OvermindACURole = import('/mods/OvermindAI/lua/AI/Overmind/ACURole.lua')
local OvermindFactoryHeartbeat = import('/mods/OvermindAI/lua/AI/Overmind/FactoryHeartbeat.lua')
local OvermindFactoryResume = import('/mods/OvermindAI/lua/AI/Overmind/FactoryResume.lua')
local OvermindRaidDefense = import('/mods/OvermindAI/lua/AI/Overmind/RaidDefense.lua')
local OvermindProductionDirector = import('/mods/OvermindAI/lua/AI/Overmind/ProductionDirector.lua')
local OvermindUpgradeDirector = import('/mods/OvermindAI/lua/AI/Overmind/UpgradeDirector.lua')
local OvermindFactoryController = import('/mods/OvermindAI/lua/AI/Overmind/FactoryController.lua')
local OvermindRadarFallback = import('/mods/OvermindAI/lua/AI/Overmind/RadarFallback.lua')
local OvermindBomberHarass = import('/mods/OvermindAI/lua/AI/Overmind/BomberHarass.lua')
local OvermindMexDefense = import('/mods/OvermindAI/lua/AI/Overmind/MexDefense.lua')
local OvermindForceDirector = import('/mods/OvermindAI/lua/AI/Overmind/ForceDirector.lua')

local function ResolveModuleFn(moduleRef, fieldName)
    if type(moduleRef) ~= 'table' then
        return false, 'module-not-table'
    end

    local fn = rawget(moduleRef, fieldName)
    if type(fn) == 'function' then
        return fn, false
    end

    local nested = rawget(moduleRef, 'Module')
    if type(nested) == 'table' then
        local nestedRaw = rawget(nested, fieldName)
        if type(nestedRaw) == 'function' then
            return nestedRaw, false
        end
    end

    return false, 'field-not-function:' .. tostring(fieldName)
end

local function BuildAction(spec)
    local fn, err = ResolveModuleFn(spec.ModuleRef, spec.Method or 'Update')
    return {
        Name = spec.Name,
        Label = spec.Label or spec.Name,
        Group = spec.Group,
        Method = spec.Method or 'Update',
        StateSlice = spec.StateSlice or false,
        Inputs = spec.Inputs or {},
        Outputs = spec.Outputs or {},
        CompatibilityOnly = spec.CompatibilityOnly and true or false,
        ModuleRef = spec.ModuleRef,
        Fn = fn,
        ResolveError = err,
    }
end

local ActionGroups = {
    always = {
        BuildAction({
            Name = 'MemoryWindow',
            Label = 'memory',
            Group = 'always',
            Method = 'UpdateWindow',
            ModuleRef = OvermindMemory,
            Inputs = { 'OvermindMemory' },
            Outputs = { 'OvermindMemory' },
        }),
        BuildAction({
            Name = 'Economy',
            Label = 'economy',
            Group = 'always',
            StateSlice = 'EcoState',
            ModuleRef = OvermindEconomy,
            Outputs = { 'EcoState', 'Aggression', 'SpendPressure', 'CombatMomentum', 'EconomicMomentum' },
        }),
        BuildAction({
            Name = 'RuntimeContracts',
            Label = 'runtime-contracts',
            Group = 'always',
            StateSlice = 'RuntimeContracts',
            ModuleRef = OvermindRuntimeContracts,
            Inputs = { 'EcoState' },
            Outputs = { 'RuntimeContracts', 'ForceDirector', 'ProductionDirector' },
        }),
    },
    strategic = {
        BuildAction({ Name = 'ZoneGraph', Label = 'zone-graph', Group = 'strategic', StateSlice = 'ZoneGraph', ModuleRef = OvermindZoneGraph, Outputs = { 'ZoneGraph' } }),
        BuildAction({ Name = 'ZoneModel', Label = 'zones', Group = 'strategic', StateSlice = 'ZoneModel', ModuleRef = OvermindZoneModel, Inputs = { 'ZoneGraph' }, Outputs = { 'ZoneModel' } }),
        BuildAction({ Name = 'IntelModel', Label = 'intel-model', Group = 'strategic', StateSlice = 'IntelModel', ModuleRef = OvermindIntelModel, Inputs = { 'ZoneGraph', 'ReconState' }, Outputs = { 'IntelModel', 'PrimaryEnemyPos', 'LastEnemyContactTime' } }),
        BuildAction({ Name = 'EnemyClusterTracker', Label = 'enemy-clusters', Group = 'strategic', StateSlice = 'EnemyClusterTracker', ModuleRef = OvermindEnemyClusterTracker, Inputs = { 'ZoneGraph', 'IntelModel' }, Outputs = { 'EnemyClusterTracker', 'LastEnemyContactTime' } }),
        BuildAction({ Name = 'OpponentModel', Label = 'opponent-model', Group = 'strategic', StateSlice = 'OpponentModel', ModuleRef = OvermindOpponentModel, Inputs = { 'ZoneGraph', 'IntelModel', 'EnemyClusterTracker' }, Outputs = { 'OpponentModel' } }),
        BuildAction({ Name = 'StrategicPlanner', Label = 'strategic-planner', Group = 'strategic', StateSlice = 'StrategicPlanner', ModuleRef = OvermindStrategicPlanner, Inputs = { 'ZoneGraph', 'IntelModel', 'EnemyClusterTracker', 'OpponentModel', 'EcoState', 'Recovery', 'RaidDefense', 'ForceDirector' }, Outputs = { 'StrategicPlanner' } }),
        BuildAction({ Name = 'GoalSelector', Label = 'goal-selector', Group = 'strategic', ModuleRef = OvermindGoalSelector, Inputs = { 'ZoneGraph', 'IntelModel', 'EnemyClusterTracker', 'OpponentModel', 'StrategicPlanner', 'EcoState', 'Recovery', 'ForceDirector' }, Outputs = { 'StrategyGoal', 'StrategyGoalScore', 'StrategyUtilities', 'GoalAggressionModifier', 'GoalConfidence', 'StrategyFocusPos', 'StrategyFocusZoneKey', 'StrategyFocusReason', 'StrategySignals' } }),
        BuildAction({ Name = 'EconomyPolicy', Label = 'economy-policy', Group = 'strategic', Method = 'UpdatePolicy', ModuleRef = OvermindEconomyOptimizer, Inputs = { 'EcoState', 'OpponentModel', 'StrategicPlanner', 'ZoneGraph', 'IntelModel', 'Recovery' }, Outputs = { 'EcoPolicy', 'MacroPhase' } }),
        BuildAction({ Name = 'CombatRefresh', Label = 'combat-refresh', Group = 'strategic', Method = 'RefreshStrategicState', ModuleRef = OvermindCombat, Inputs = { 'ForceDirector', 'IntelModel', 'ZoneGraph', 'OpponentModel' }, Outputs = { 'CombatState' } }),
        BuildAction({ Name = 'Watchdog', Label = 'watchdog', Group = 'strategic', ModuleRef = OvermindWatchdog, Inputs = { 'Recovery', 'EcoState', 'ProductionDirector' }, Outputs = { 'Recovery' } }),
        BuildAction({ Name = 'ProductionDirector', Label = 'production-director', Group = 'strategic', StateSlice = 'ProductionDirector', ModuleRef = OvermindProductionDirector, Inputs = { 'EcoState', 'EcoPolicy', 'StrategicPlanner', 'ForceDirector', 'IntelModel', 'ZoneGraph', 'ZoneModel', 'EnemyClusterTracker', 'OpponentModel', 'Recovery', 'ACUState', 'EngineerState' }, Outputs = { 'ProductionDirector' } }),
    },
    tactical = {
        BuildAction({ Name = 'Tactical', Label = 'tactical', Group = 'tactical', ModuleRef = OvermindTactical, Outputs = { 'LastTacticalUpdate' } }),
        BuildAction({ Name = 'CombatPressure', Label = 'combat-pressure', Group = 'tactical', Method = 'RunPressureCycle', ModuleRef = OvermindCombatExecution, Inputs = { 'ForceDirector', 'StrategyGoal', 'ZoneGraph', 'IntelModel', 'EnemyClusterTracker' }, Outputs = { 'CombatPressureState' } }),
        BuildAction({ Name = 'CommanderSafety', Label = 'acu-safety', Group = 'tactical', Method = 'EnforceCommanderSafety', ModuleRef = OvermindCombat, Inputs = { 'ACUState', 'RaidDefense', 'IntelModel' }, Outputs = { 'ACUState', 'LastAcuDistanceFromBase' } }),
    },
    ['macro-control'] = {
        BuildAction({ Name = 'ForceDirector', Label = 'force-director', Group = 'macro-control', StateSlice = 'ForceDirector', ModuleRef = OvermindForceDirector, Inputs = { 'IntelModel', 'EnemyClusterTracker', 'RaidDefense', 'StrategicPlanner', 'ZoneModel' }, Outputs = { 'ForceDirector', 'ForceManager' } }),
        BuildAction({ Name = 'FactoryHeartbeat', Label = 'factory-heartbeat', Group = 'macro-control', ModuleRef = OvermindFactoryHeartbeat, Outputs = { 'FactoryState' } }),
        BuildAction({ Name = 'FactoryResume', Label = 'factory-resume', Group = 'macro-control', StateSlice = 'FactoryResume', ModuleRef = OvermindFactoryResume, Inputs = { 'Recovery', 'ZoneModel', 'EngineerState' }, Outputs = { 'FactoryResume' } }),
        BuildAction({ Name = 'RaidDefense', Label = 'raid-defense', Group = 'macro-control', StateSlice = 'RaidDefense', ModuleRef = OvermindRaidDefense, Inputs = { 'IntelModel', 'ZoneModel' }, Outputs = { 'RaidDefense' } }),
        BuildAction({ Name = 'UpgradeDirector', Label = 'upgrade-director', Group = 'macro-control', StateSlice = 'UpgradeDirector', ModuleRef = OvermindUpgradeDirector, Inputs = { 'ProductionDirector', 'StrategicPlanner', 'ZoneGraph', 'ZoneModel', 'IntelModel', 'Recovery', 'EngineerState' }, Outputs = { 'UpgradeDirector' } }),
        BuildAction({ Name = 'EngineerDirector', Label = 'engineer-director', Group = 'macro-control', StateSlice = 'EngineerState', ModuleRef = OvermindEngineerDirector, Inputs = { 'ZoneGraph', 'IntelModel', 'Recovery' }, Outputs = { 'EngineerState' } }),
        BuildAction({ Name = 'ScoutDirector', Label = 'scout-director', Group = 'macro-control', StateSlice = 'ReconState', ModuleRef = OvermindScoutManager, Inputs = { 'ZoneGraph', 'IntelModel', 'Recovery' }, Outputs = { 'ReconState' } }),
        BuildAction({ Name = 'ACURole', Label = 'acu-role', Group = 'macro-control', StateSlice = 'ACUState', ModuleRef = OvermindACURole, Inputs = { 'IntelModel', 'ForceDirector', 'ZoneGraph' }, Outputs = { 'ACUState', 'ACURole' } }),
        BuildAction({ Name = 'RadarFallback', Label = 'radar-fallback', Group = 'macro-control', StateSlice = 'RadarState', ModuleRef = OvermindRadarFallback, Inputs = { 'ProductionDirector', 'IntelModel', 'ZoneGraph', 'RaidDefense' }, Outputs = { 'RadarState', 'RadarFallback' } }),
        BuildAction({ Name = 'BomberHarass', Label = 'bomber-harass', Group = 'macro-control', StateSlice = 'BomberHarass', ModuleRef = OvermindBomberHarass, Inputs = { 'IntelModel', 'ForceDirector', 'OpponentModel' }, Outputs = { 'BomberHarass' } }),
        BuildAction({ Name = 'MexDefense', Label = 'mex-defense', Group = 'macro-control', StateSlice = 'MexDefense', ModuleRef = OvermindMexDefense, Inputs = { 'ProductionDirector', 'RaidDefense', 'EcoState' }, Outputs = { 'MexDefense' } }),
    },
    ['factory-control'] = {
        BuildAction({ Name = 'FactoryController', Label = 'factory-controller', Group = 'factory-control', StateSlice = 'FactoryController', ModuleRef = OvermindFactoryController, Inputs = { 'ProductionDirector', 'UpgradeDirector', 'ForceDirector', 'EcoPolicy', 'Recovery' }, Outputs = { 'FactoryController', 'Recovery' } }),
    },
    telemetry = {
        BuildAction({ Name = 'TelemetryCapture', Label = 'telemetry-capture', Group = 'telemetry', Method = 'Capture', StateSlice = 'Telemetry', ModuleRef = OvermindTelemetry, Inputs = { 'EcoState', 'ProductionDirector', 'ForceDirector', 'StrategicPlanner', 'IntelModel', 'EnemyClusterTracker', 'ZoneGraph', 'RaidDefense' }, Outputs = { 'Telemetry', 'LastTelemetry' } }),
        BuildAction({ Name = 'TelemetryTune', Label = 'telemetry-tune', Group = 'telemetry', Method = 'Tune', StateSlice = 'Telemetry', ModuleRef = OvermindTelemetry, Inputs = { 'Telemetry' }, Outputs = { 'Tuning' } }),
    },
}

local GroupOrder = {
    'always',
    'strategic',
    'tactical',
    'macro-control',
    'factory-control',
    'telemetry',
}

function GetGroup(name)
    return ActionGroups[name] or {}
end

function GetGroups()
    return ActionGroups
end

function GetGroupOrder()
    return GroupOrder
end

function Invoke(action, aiBrain, now)
    if type(action) ~= 'table' then
        return false, 'action-not-table'
    end
    if type(action.Fn) ~= 'function' then
        return false, action.ResolveError or 'missing-function'
    end
    return pcall(action.Fn, aiBrain, now)
end
