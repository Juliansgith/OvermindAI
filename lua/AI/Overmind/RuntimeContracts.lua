local AIUtils = import('/lua/ai/aiutilities.lua')

local DeclaredStateInitializers = {
    EcoState = function()
        return {}
    end,
    RuntimeContracts = function()
        return {
            LastLogTime = -999,
        }
    end,
    ZoneGraph = function()
        return {
            Nodes = {},
            ByKey = {},
            LastLogTime = -999,
        }
    end,
    ZoneModel = function()
        return {}
    end,
    ReconState = function()
        return {
            LastVisit = {},
            LastIntent = {},
            PendingScoutTargets = {},
            PendingByKey = {},
        }
    end,
    IntelModel = function()
        return {
            Zones = {},
            LastLogTime = -999,
        }
    end,
    EnemyClusterTracker = function()
        return {
            Clusters = {},
            ClusterCount = 0,
            LastLogTime = -999,
        }
    end,
    OpponentModel = function()
        return {
            Theaters = {},
            Trends = {},
            Confidence = {},
            Confirmed = {},
            Inferred = {},
            LastLogTime = -999,
        }
    end,
    StrategicPlanner = function()
        return {
            Directive = 'stabilize',
            PrimaryTheater = 'Front',
            GoalBiases = {},
            TheaterScores = {},
            DirectiveScores = {},
            Signals = {},
            LastDirectiveSwitch = -999,
            LastTheaterSwitch = -999,
            LastLogTime = -999,
        }
    end,
    ForceDirector = function()
        return {
            Assignments = {},
            Groups = {},
            TaskGroups = {},
            TaskExecution = {},
            Stats = {},
            RoleDemand = {},
            Tasks = {},
            TaskList = {},
            UnitTaskById = {},
            NextTaskId = 1,
            LastLogTime = -999,
        }
    end,
    ProductionDirector = function()
        return {
            Mode = 'stabilize',
            LastModeSwitch = -999,
            LastUpdate = -999,
            TimeHorizon = {
                Emergency = 30,
                Operational = 90,
                Strategic = 240,
            },
            Current = {
                Factories = {},
                Roles = {},
                RoleUnits = {},
                Structures = {},
                DomainUnits = {},
                DomainStrength = {},
                FactoryTask = {},
            },
            DomainBudget = {
                Land = 0.34,
                Air = 0.14,
                Navy = 0.02,
                Intel = 0.14,
                Defense = 0.10,
                Eco = 0.18,
                Tech = 0.08,
            },
            RolePlan = {},
            CapacityPlan = false,
            TechPlan = {},
            StructurePlan = {},
            EmergencyOverrides = {},
            Confidence = {
                Global = 0.3,
                Land = 0.3,
                Air = 0.3,
                Navy = 0.2,
            },
            ConstraintState = {},
            DemandLedger = {},
            OpponentTrend = {
                Land = 0,
                Air = 0,
                Navy = 0,
            },
            OpponentTrends = {
                Land = 0,
                Air = 0,
                Navy = 0,
            },
            PreviousOpponent = {
                Time = 0,
                Land = 0,
                Air = 0,
                Navy = 0,
            },
            NavalActive = false,
            ScoutingDebt = 1,
            ModeScores = {},
            LastLogTime = -999,
        }
    end,
    Recovery = function()
        return {}
    end,
    ACUState = function()
        return {}
    end,
    EngineerState = function()
        return {
            UnfinishedFactoryTask = {
                Active = false,
                BuilderIds = {},
                AssignedBuilders = 0,
                RequiredBuilders = 0,
                Domain = 'none',
                StallTime = 0,
                Fraction = 1,
            },
            UnfinishedStructureTask = {
                Active = false,
                BuilderIds = {},
                AssignedBuilders = 0,
                RequiredBuilders = 0,
                Kind = 'none',
                StallTime = 0,
                Fraction = 1,
                Priority = 0,
                StickyUntil = -999,
            },
            ExpansionReservations = {},
            LastExpansionReservationCleanup = -999,
        }
    end,
    RaidDefense = function()
        return {}
    end,
    RadarState = function()
        return {}
    end,
    BomberHarass = function()
        return {}
    end,
    MexDefense = function()
        return {}
    end,
    FactoryState = function()
        return {}
    end,
    FactoryResume = function()
        return {}
    end,
    FactoryController = function()
        return {}
    end,
    FactoryControlState = function()
        return {}
    end,
    Telemetry = function()
        return {
            Samples = {},
            Window = 90,
            Checkpoints = {},
        }
    end,
}

local RequiredEcoFields = {
    'MassStored',
    'EnergyStored',
    'MassStorageRatio',
    'EnergyStorageRatio',
    'MassTrend',
    'EnergyTrend',
    'MassIncome',
    'EnergyIncome',
    'UnitCount',
    'UnitCap',
    'UnitLoad',
}

local function EnsureRuntime(aiBrain)
    aiBrain.OvermindRuntime = aiBrain.OvermindRuntime or {}
    return aiBrain.OvermindRuntime
end

local function EnsureStateSlice(runtime, sliceName)
    if not sliceName then
        return false
    end
    if runtime[sliceName] == nil then
        local init = DeclaredStateInitializers[sliceName]
        runtime[sliceName] = init and init() or {}
    end
    return runtime[sliceName]
end

local function EnsureEcoState(aiBrain, runtime)
    local econ = EnsureStateSlice(runtime, 'EcoState')
    local raw = AIUtils.AIGetEconomyNumbers(aiBrain) or {}

    econ.MassStored = econ.MassStored or aiBrain:GetEconomyStored('MASS') or 0
    econ.EnergyStored = econ.EnergyStored or aiBrain:GetEconomyStored('ENERGY') or 0
    econ.MassTrend = econ.MassTrend or raw.MassTrend or aiBrain:GetEconomyTrend('MASS') or 0
    econ.EnergyTrend = econ.EnergyTrend or raw.EnergyTrend or aiBrain:GetEconomyTrend('ENERGY') or 0
    econ.MassIncome = econ.MassIncome or raw.MassIncome or 0
    econ.EnergyIncome = econ.EnergyIncome or raw.EnergyIncome or 0
    econ.MassRequested = econ.MassRequested or raw.MassRequested or 0
    econ.EnergyRequested = econ.EnergyRequested or raw.EnergyRequested or 0

    if econ.MassStorageRatio == nil then
        local storage = raw.MassStorage or 600
        if storage <= 0 then
            storage = 600
        end
        econ.MassStorageRatio = econ.MassStored / storage
    end
    if econ.EnergyStorageRatio == nil then
        local storage = raw.EnergyStorage or 4000
        if storage <= 0 then
            storage = 4000
        end
        econ.EnergyStorageRatio = econ.EnergyStored / storage
    end

    econ.UnitCount = econ.UnitCount or (aiBrain:GetCurrentUnits(categories.ALLUNITS) or 0)
    local cap = 1000
    if GetArmyUnitCap then
        cap = GetArmyUnitCap(aiBrain:GetArmyIndex()) or 1000
    end
    if cap <= 0 then
        cap = 1000
    end
    econ.UnitCap = econ.UnitCap or cap
    econ.UnitLoad = econ.UnitLoad or (econ.UnitCount / econ.UnitCap)
    runtime.EcoState = econ
    return econ
end

function Update(aiBrain, now)
    local runtime = EnsureRuntime(aiBrain)
    local contract = EnsureStateSlice(runtime, 'RuntimeContracts')

    local econ = EnsureEcoState(aiBrain, runtime)
    EnsureStateSlice(runtime, 'ZoneGraph')
    EnsureStateSlice(runtime, 'ZoneModel')
    EnsureStateSlice(runtime, 'ReconState')
    EnsureStateSlice(runtime, 'IntelModel')
    EnsureStateSlice(runtime, 'EnemyClusterTracker')
    EnsureStateSlice(runtime, 'OpponentModel')
    EnsureStateSlice(runtime, 'StrategicPlanner')
    EnsureStateSlice(runtime, 'ForceDirector')
    EnsureStateSlice(runtime, 'ProductionDirector')
    EnsureStateSlice(runtime, 'Recovery')
    EnsureStateSlice(runtime, 'ACUState')
    EnsureStateSlice(runtime, 'EngineerState')
    EnsureStateSlice(runtime, 'RaidDefense')
    EnsureStateSlice(runtime, 'RadarState')
    EnsureStateSlice(runtime, 'BomberHarass')
    EnsureStateSlice(runtime, 'MexDefense')
    EnsureStateSlice(runtime, 'FactoryState')
    EnsureStateSlice(runtime, 'FactoryResume')
    local factoryController = EnsureStateSlice(runtime, 'FactoryController')
    runtime.FactoryController = runtime.FactoryController or factoryController
    runtime.FactoryControlState = runtime.FactoryController
    EnsureStateSlice(runtime, 'Telemetry')

    runtime.ForceManager = runtime.ForceDirector

    local missing = {}
    for _, key in RequiredEcoFields do
        if econ[key] == nil then
            table.insert(missing, key)
        end
    end

    if table.getn(missing) > 0 and now - (contract.LastLogTime or -999) >= 45 then
        contract.LastLogTime = now
        LOG(string.format('*OVERMIND CONTRACT A%d t=%.1f missing=%s',
            aiBrain:GetArmyIndex(),
            now,
            table.concat(missing, ',')))
    end
end
