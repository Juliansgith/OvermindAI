if rawget(_G, 'OvermindEconomyBuilderGroupsLoaded') then
    return
end
rawset(_G, 'OvermindEconomyBuilderGroupsLoaded', true)

local UCBC = '/lua/editor/UnitCountBuildConditions.lua'
local MABC = '/lua/editor/MarkerBuildConditions.lua'
local IBC = '/lua/editor/InstantBuildConditions.lua'
local EBC = '/lua/editor/EconomyBuildConditions.lua'
local MIBC = '/lua/editor/MiscBuildConditions.lua'
local TBC = '/lua/editor/ThreatBuildConditions.lua'
local SAI = '/lua/ScenarioPlatoonAI.lua'
local OMBC = '/mods/OvermindAI/lua/editor/OvermindBuildConditions.lua'

BuilderGroup {
    BuilderGroupName = 'OvermindInitialACUBuilders',
    BuildersType = 'EngineerBuilder',
    Builder {
        BuilderName = 'Overmind CDR Initial Anchored',
        PlatoonAddBehaviors = { 'CommanderBehavior' },
        PlatoonTemplate = 'CommanderBuilder',
        Priority = 1200,
        BuilderConditions = {
            { OMBC, 'IsOvermindBrain', {} },
            { OMBC, 'ShouldUseACUBuilders', {} },
            { IBC, 'NotPreBuilt', {} },
        },
        InstantCheck = true,
        BuilderType = 'Any',
        PlatoonAddFunctions = { { SAI, 'BuildOnce' }, },
        BuilderData = {
            Construction = {
                BuildClose = true,
                BuildStructures = {
                    'T1LandFactory',
                },
            },
        },
    },
    Builder {
        BuilderName = 'Overmind CDR Initial PreBuilt Anchored',
        PlatoonAddBehaviors = { 'CommanderBehavior' },
        PlatoonTemplate = 'CommanderBuilder',
        Priority = 1200,
        BuilderConditions = {
            { OMBC, 'IsOvermindBrain', {} },
            { OMBC, 'ShouldUseACUBuilders', {} },
            { IBC, 'PreBuiltBase', {} },
        },
        InstantCheck = true,
        BuilderType = 'Any',
        PlatoonAddFunctions = { { SAI, 'BuildOnce' }, },
        BuilderData = {
            Construction = {
                BuildClose = true,
                BuildStructures = {
                    'T1LandFactory',
                },
            },
        },
    },
}

BuilderGroup {
    BuilderGroupName = 'OvermindOpeningStability',
    BuildersType = 'EngineerBuilder',
    Builder {
        BuilderName = 'Overmind Opening Land Factory 2',
        PlatoonTemplate = 'EngineerBuilder',
        Priority = 1110,
        InstanceCount = 1,
        BuilderConditions = {
            { OMBC, 'IsOvermindBrain', {} },
            { OMBC, 'HasNoUnfinishedFactoriesAtLocation', { 'LocationType', 180, 0 } },
            { OMBC, 'ShouldBuildT1FactoryType', { 'land', 'LocationType' } },
            { UCBC, 'UnitCapCheckLess', { 0.92 } },
        },
        BuilderType = 'Any',
        BuilderData = {
            Construction = {
                BuildStructures = { 'T1LandFactory' },
                Location = 'LocationType',
                AdjacencyCategory = 'ENERGYPRODUCTION',
            },
        },
    },
    Builder {
        BuilderName = 'Overmind Opening Air Factory 1',
        PlatoonTemplate = 'EngineerBuilder',
        Priority = 1095,
        InstanceCount = 1,
        BuilderConditions = {
            { OMBC, 'IsOvermindBrain', {} },
            { OMBC, 'HasNoUnfinishedFactoriesAtLocation', { 'LocationType', 180, 0 } },
            { OMBC, 'ShouldBuildT1FactoryType', { 'air', 'LocationType' } },
            { UCBC, 'UnitCapCheckLess', { 0.92 } },
        },
        BuilderType = 'Any',
        BuilderData = {
            Construction = {
                BuildStructures = { 'T1AirFactory' },
                Location = 'LocationType',
                AdjacencyCategory = 'ENERGYPRODUCTION',
            },
        },
    },
}

BuilderGroup {
    BuilderGroupName = 'OvermindFactoryFloor',
    BuildersType = 'EngineerBuilder',
    Builder {
        BuilderName = 'Overmind Factory Floor Land 3',
        PlatoonTemplate = 'EngineerBuilder',
        Priority = 1102,
        InstanceCount = 1,
        BuilderConditions = {
            { OMBC, 'IsOvermindBrain', {} },
            { OMBC, 'HasNoUnfinishedFactoriesAtLocation', { 'LocationType', 180, 0 } },
            { OMBC, 'ShouldBuildT1FactoryType', { 'land', 'LocationType' } },
            { UCBC, 'UnitCapCheckLess', { 0.95 } },
        },
        BuilderType = 'Any',
        BuilderData = {
            Construction = {
                BuildStructures = { 'T1LandFactory' },
                Location = 'LocationType',
                AdjacencyCategory = 'ENERGYPRODUCTION',
            },
        },
    },
    Builder {
        BuilderName = 'Overmind Factory Floor Air 2',
        PlatoonTemplate = 'EngineerBuilder',
        Priority = 1098,
        InstanceCount = 1,
        BuilderConditions = {
            { OMBC, 'IsOvermindBrain', {} },
            { OMBC, 'HasNoUnfinishedFactoriesAtLocation', { 'LocationType', 180, 0 } },
            { OMBC, 'ShouldBuildT1FactoryType', { 'air', 'LocationType' } },
            { UCBC, 'UnitCapCheckLess', { 0.95 } },
        },
        BuilderType = 'Any',
        BuilderData = {
            Construction = {
                BuildStructures = { 'T1AirFactory' },
                Location = 'LocationType',
                AdjacencyCategory = 'ENERGYPRODUCTION',
            },
        },
    },
}

BuilderGroup {
    BuilderGroupName = 'OvermindFactoryRecoveryFallback',
    BuildersType = 'EngineerBuilder',
    Builder {
        BuilderName = 'Overmind Recovery Land Factory',
        PlatoonTemplate = 'EngineerBuilder',
        Priority = 1140,
        InstanceCount = 1,
        BuilderConditions = {
            { OMBC, 'IsOvermindBrain', {} },
            { OMBC, 'HasNoUnfinishedFactoriesAtLocation', { 'LocationType', 180, 0 } },
            { OMBC, 'ShouldForceFactoryRecovery', {} },
            { OMBC, 'ShouldForceLandFactoryRecovery', {} },
            { OMBC, 'ShouldBuildT1FactoryType', { 'land', 'LocationType' } },
            { UCBC, 'UnitCapCheckLess', { 0.96 } },
        },
        BuilderType = 'Any',
        BuilderData = {
            Construction = {
                BuildStructures = { 'T1LandFactory' },
                Location = 'LocationType',
                AdjacencyCategory = 'ENERGYPRODUCTION',
            },
        },
    },
    Builder {
        BuilderName = 'Overmind Recovery Air Factory',
        PlatoonTemplate = 'EngineerBuilder',
        Priority = 1138,
        InstanceCount = 1,
        BuilderConditions = {
            { OMBC, 'IsOvermindBrain', {} },
            { OMBC, 'HasNoUnfinishedFactoriesAtLocation', { 'LocationType', 180, 0 } },
            { OMBC, 'ShouldForceFactoryRecovery', {} },
            { OMBC, 'ShouldForceAirFactoryRecovery', {} },
            { OMBC, 'ShouldBuildT1FactoryType', { 'air', 'LocationType' } },
            { UCBC, 'UnitCapCheckLess', { 0.96 } },
        },
        BuilderType = 'Any',
        BuilderData = {
            Construction = {
                BuildStructures = { 'T1AirFactory' },
                Location = 'LocationType',
                AdjacencyCategory = 'ENERGYPRODUCTION',
            },
        },
    },
}

BuilderGroup {
    BuilderGroupName = 'OvermindEmergencyFactoryScale',
    BuildersType = 'EngineerBuilder',
    Builder {
        BuilderName = 'Overmind Hard Bootstrap Land 2',
        PlatoonTemplate = 'EngineerBuilder',
        Priority = 1178,
        InstanceCount = 1,
        BuilderConditions = {
            { OMBC, 'IsOvermindBrain', {} },
            { OMBC, 'HasNoUnfinishedFactoriesAtLocation', { 'LocationType', 180, 0 } },
            { OMBC, 'ShouldBuildT1FactoryType', { 'land', 'LocationType' } },
            { UCBC, 'UnitCapCheckLess', { 0.98 } },
        },
        BuilderType = 'Any',
        BuilderData = {
            Construction = {
                BuildClose = true,
                BuildStructures = { 'T1LandFactory' },
                Location = 'LocationType',
                AdjacencyCategory = 'ENERGYPRODUCTION',
            },
        },
    },
    Builder {
        BuilderName = 'Overmind Hard Bootstrap Air 1',
        PlatoonTemplate = 'EngineerBuilder',
        Priority = 1172,
        InstanceCount = 1,
        BuilderConditions = {
            { OMBC, 'IsOvermindBrain', {} },
            { OMBC, 'HasNoUnfinishedFactoriesAtLocation', { 'LocationType', 180, 0 } },
            { OMBC, 'ShouldBuildT1FactoryType', { 'air', 'LocationType' } },
            { UCBC, 'UnitCapCheckLess', { 0.98 } },
        },
        BuilderType = 'Any',
        BuilderData = {
            Construction = {
                BuildClose = true,
                BuildStructures = { 'T1AirFactory' },
                Location = 'LocationType',
                AdjacencyCategory = 'ENERGYPRODUCTION',
            },
        },
    },
    Builder {
        BuilderName = 'Overmind Bomber Watch Air Factory',
        PlatoonTemplate = 'EngineerBuilder',
        Priority = 1174,
        InstanceCount = 1,
        BuilderConditions = {
            { OMBC, 'IsOvermindBrain', {} },
            { OMBC, 'IsBomberWatch', {} },
            { OMBC, 'HasNoUnfinishedFactoriesAtLocation', { 'LocationType', 180, 0 } },
            { OMBC, 'ShouldBuildT1FactoryType', { 'air', 'LocationType' } },
            { UCBC, 'UnitCapCheckLess', { 0.98 } },
        },
        BuilderType = 'Any',
        BuilderData = {
            Construction = {
                BuildClose = true,
                BuildStructures = { 'T1AirFactory' },
                Location = 'LocationType',
                AdjacencyCategory = 'ENERGYPRODUCTION',
            },
        },
    },
    Builder {
        BuilderName = 'Overmind Emergency Factory Scale Land',
        PlatoonTemplate = 'EngineerBuilder',
        Priority = 1160,
        InstanceCount = 1,
        BuilderConditions = {
            { OMBC, 'IsOvermindBrain', {} },
            { OMBC, 'HasNoUnfinishedFactoriesAtLocation', { 'LocationType', 180, 0 } },
            { OMBC, 'ShouldBuildT1FactoryType', { 'land', 'LocationType' } },
            { UCBC, 'UnitCapCheckLess', { 0.97 } },
        },
        BuilderType = 'Any',
        BuilderData = {
            Construction = {
                BuildStructures = { 'T1LandFactory' },
                Location = 'LocationType',
                AdjacencyCategory = 'ENERGYPRODUCTION',
            },
        },
    },
    Builder {
        BuilderName = 'Overmind Emergency Factory Scale Air',
        PlatoonTemplate = 'EngineerBuilder',
        Priority = 1156,
        InstanceCount = 1,
        BuilderConditions = {
            { OMBC, 'IsOvermindBrain', {} },
            { OMBC, 'HasNoUnfinishedFactoriesAtLocation', { 'LocationType', 180, 0 } },
            { OMBC, 'ShouldBuildT1FactoryType', { 'air', 'LocationType' } },
            { UCBC, 'UnitCapCheckLess', { 0.97 } },
        },
        BuilderType = 'Any',
        BuilderData = {
            Construction = {
                BuildStructures = { 'T1AirFactory' },
                Location = 'LocationType',
                AdjacencyCategory = 'ENERGYPRODUCTION',
            },
        },
    },
}

BuilderGroup {
    BuilderGroupName = 'OvermindACUFactoryRecovery',
    BuildersType = 'EngineerBuilder',
    Builder {
        BuilderName = 'Overmind ACU Hard Bootstrap Land',
        PlatoonAddBehaviors = { 'CommanderBehavior' },
        PlatoonTemplate = 'CommanderBuilder',
        Priority = 1184,
        InstanceCount = 1,
        BuilderConditions = {
            { OMBC, 'IsOvermindBrain', {} },
            { OMBC, 'ShouldUseACUBuilders', {} },
            { OMBC, 'HasNoUnfinishedFactoriesAtLocation', { 'LocationType', 180, 0 } },
            { OMBC, 'ShouldBuildT1FactoryType', { 'land', 'LocationType' } },
        },
        BuilderType = 'Any',
        BuilderData = {
            Construction = {
                BuildClose = false,
                BuildStructures = { 'T1LandFactory' },
            },
        },
    },
    Builder {
        BuilderName = 'Overmind ACU Emergency Land Factory',
        PlatoonAddBehaviors = { 'CommanderBehavior' },
        PlatoonTemplate = 'CommanderBuilder',
        Priority = 1170,
        InstanceCount = 1,
        BuilderConditions = {
            { OMBC, 'IsOvermindBrain', {} },
            { OMBC, 'ShouldUseACUBuilders', {} },
            { OMBC, 'HasNoUnfinishedFactoriesAtLocation', { 'LocationType', 180, 0 } },
            { OMBC, 'ShouldBuildT1FactoryType', { 'land', 'LocationType' } },
        },
        BuilderType = 'Any',
        BuilderData = {
            Construction = {
                BuildClose = false,
                BuildStructures = { 'T1LandFactory' },
            },
        },
    },
    Builder {
        BuilderName = 'Overmind ACU Emergency Air Factory',
        PlatoonAddBehaviors = { 'CommanderBehavior' },
        PlatoonTemplate = 'CommanderBuilder',
        Priority = 1164,
        InstanceCount = 1,
        BuilderConditions = {
            { OMBC, 'IsOvermindBrain', {} },
            { OMBC, 'ShouldUseACUBuilders', {} },
            { OMBC, 'HasNoUnfinishedFactoriesAtLocation', { 'LocationType', 180, 0 } },
            { OMBC, 'ShouldBuildT1FactoryType', { 'air', 'LocationType' } },
        },
        BuilderType = 'Any',
        BuilderData = {
            Construction = {
                BuildClose = false,
                BuildStructures = { 'T1AirFactory' },
            },
        },
    },
}

BuilderGroup {
    BuilderGroupName = 'OvermindACUT1DirectorFactoryControl',
    BuildersType = 'EngineerBuilder',
    Builder {
        BuilderName = 'Overmind ACU T1Director Land Factory',
        PlatoonAddBehaviors = { 'CommanderBehavior' },
        PlatoonTemplate = 'CommanderBuilder',
        Priority = 1162,
        InstanceCount = 1,
        BuilderConditions = {
            { OMBC, 'IsOvermindBrain', {} },
            { OMBC, 'ShouldUseACUBuilders', {} },
            { OMBC, 'HasNoUnfinishedFactoriesAtLocation', { 'LocationType', 180, 0 } },
            { OMBC, 'ShouldBuildT1FactoryType', { 'land', 'LocationType' } },
        },
        BuilderType = 'Any',
        BuilderData = {
            Construction = {
                BuildClose = false,
                BuildStructures = { 'T1LandFactory' },
            },
        },
    },
    Builder {
        BuilderName = 'Overmind ACU T1Director Air Factory',
        PlatoonAddBehaviors = { 'CommanderBehavior' },
        PlatoonTemplate = 'CommanderBuilder',
        Priority = 1158,
        InstanceCount = 1,
        BuilderConditions = {
            { OMBC, 'IsOvermindBrain', {} },
            { OMBC, 'ShouldUseACUBuilders', {} },
            { OMBC, 'HasNoUnfinishedFactoriesAtLocation', { 'LocationType', 180, 0 } },
            { OMBC, 'ShouldBuildT1FactoryType', { 'air', 'LocationType' } },
        },
        BuilderType = 'Any',
        BuilderData = {
            Construction = {
                BuildClose = false,
                BuildStructures = { 'T1AirFactory' },
            },
        },
    },
    Builder {
        BuilderName = 'Overmind ACU Guaranteed Radar Floor',
        PlatoonAddBehaviors = { 'CommanderBehavior' },
        PlatoonTemplate = 'CommanderBuilder',
        Priority = 1160,
        InstanceCount = 1,
        BuilderConditions = {
            { OMBC, 'IsOvermindBrain', {} },
            { OMBC, 'ShouldUseACUBuilders', {} },
            { MIBC, 'GreaterThanGameTime', { 110 } },
            { OMBC, 'HasBootstrapPowerFloor', {} },
            { OMBC, 'NeedBaselineRadar', { 1, 160 } },
            { UCBC, 'HaveGreaterThanUnitsWithCategory', { 0, 'FACTORY STRUCTURE' } },
            { UCBC, 'LocationEngineersBuildingLess', { 'LocationType', 2, 'RADAR' } },
            { OMBC, 'HasSafeEnergy', { 0.04, -12 } },
        },
        BuilderType = 'Any',
        BuilderData = {
            Construction = {
                BuildClose = false,
                BuildStructures = { 'T1Radar' },
            },
        },
    },
}

BuilderGroup {
    BuilderGroupName = 'OvermindACUEarlyEconomy',
    BuildersType = 'EngineerBuilder',
    Builder {
        BuilderName = 'Overmind ACU Early Mex Close',
        PlatoonAddBehaviors = { 'CommanderBehavior' },
        PlatoonTemplate = 'CommanderBuilder',
        Priority = 1156,
        InstanceCount = 1,
        BuilderConditions = {
            { OMBC, 'IsOvermindBrain', {} },
            { OMBC, 'ShouldUseACUBuilders', {} },
            { OMBC, 'IsEconomyBootstrap', {} },
            { OMBC, 'HasNoUnfinishedFactoriesAtLocation', { 'LocationType', 180, 0 } },
            { MIBC, 'GreaterThanGameTime', { 42 } },
            { MIBC, 'LessThanGameTime', { 320 } },
            { UCBC, 'FactoryGreaterAtLocation', { 'LocationType', 0, 'LAND' } },
            { OMBC, 'HasSafeEnergy', { 0.02, -18 } },
            { OMBC, 'CanSafelyExpand', { 'LocationType', 220, 0.7, 95, 6 } },
            { MABC, 'CanBuildOnMassLessThanDistance', { 'LocationType', 220, -500, 0.8, 0, 'AntiSurface', 1 } },
        },
        BuilderType = 'Any',
        BuilderData = {
            NeedGuard = false,
            DesiresAssist = false,
            Construction = {
                BuildStructures = { 'T1Resource' },
            },
        },
    },
    Builder {
        BuilderName = 'Overmind ACU Early Power Sustain',
        PlatoonAddBehaviors = { 'CommanderBehavior' },
        PlatoonTemplate = 'CommanderBuilder',
        Priority = 1158,
        InstanceCount = 1,
        BuilderConditions = {
            { OMBC, 'IsOvermindBrain', {} },
            { OMBC, 'ShouldUseACUBuilders', {} },
            { OMBC, 'IsEconomyBootstrap', {} },
            { OMBC, 'HasNoUnfinishedFactoriesAtLocation', { 'LocationType', 180, 0 } },
            { MIBC, 'GreaterThanGameTime', { 40 } },
            { MIBC, 'LessThanGameTime', { 320 } },
            { UCBC, 'FactoryGreaterAtLocation', { 'LocationType', 0, 'LAND' } },
            { OMBC, 'ShouldBuildPower', {} },
        },
        BuilderType = 'Any',
        BuilderData = {
            Construction = {
                BuildClose = false,
                AdjacencyCategory = 'FACTORY',
                BuildStructures = { 'T1EnergyProduction' },
            },
        },
    },
}

BuilderGroup {
    BuilderGroupName = 'OvermindT1DirectorFactoryControl',
    BuildersType = 'EngineerBuilder',
    Builder {
        BuilderName = 'Overmind T1Director Land Factory Floor',
        PlatoonTemplate = 'EngineerBuilder',
        Priority = 1148,
        InstanceCount = 1,
        BuilderConditions = {
            { OMBC, 'IsOvermindBrain', {} },
            { OMBC, 'HasNoUnfinishedFactoriesAtLocation', { 'LocationType', 180, 0 } },
            { OMBC, 'ShouldBuildT1FactoryType', { 'land', 'LocationType' } },
            { UCBC, 'UnitCapCheckLess', { 0.97 } },
        },
        BuilderType = 'Any',
        BuilderData = {
            Construction = {
                BuildStructures = { 'T1LandFactory' },
                Location = 'LocationType',
                AdjacencyCategory = 'ENERGYPRODUCTION',
            },
        },
    },
    Builder {
        BuilderName = 'Overmind T1Director Air Factory Floor',
        PlatoonTemplate = 'EngineerBuilder',
        Priority = 1142,
        InstanceCount = 1,
        BuilderConditions = {
            { OMBC, 'IsOvermindBrain', {} },
            { OMBC, 'HasNoUnfinishedFactoriesAtLocation', { 'LocationType', 180, 0 } },
            { OMBC, 'ShouldBuildT1FactoryType', { 'air', 'LocationType' } },
            { UCBC, 'UnitCapCheckLess', { 0.97 } },
        },
        BuilderType = 'Any',
        BuilderData = {
            Construction = {
                BuildStructures = { 'T1AirFactory' },
                Location = 'LocationType',
                AdjacencyCategory = 'ENERGYPRODUCTION',
            },
        },
    },
    Builder {
        BuilderName = 'Overmind T1Director Sea Factory Floor',
        PlatoonTemplate = 'EngineerBuilder',
        Priority = 1136,
        InstanceCount = 1,
        BuilderConditions = {
            { OMBC, 'IsOvermindBrain', {} },
            { OMBC, 'HasNoUnfinishedFactoriesAtLocation', { 'LocationType', 180, 0 } },
            { OMBC, 'IsT1NavalActive', {} },
            { OMBC, 'ShouldBuildT1FactoryType', { 'sea', 'LocationType' } },
            { UCBC, 'UnitCapCheckLess', { 0.97 } },
        },
        BuilderType = 'Any',
        BuilderData = {
            Construction = {
                BuildStructures = { 'T1SeaFactory' },
                Location = 'LocationType',
            },
        },
    },
}

BuilderGroup {
    BuilderGroupName = 'OvermindT1DirectorProduction',
    BuildersType = 'FactoryBuilder',
    Builder {
        BuilderName = 'Overmind Engineer Rebuild Emergency',
        PlatoonTemplate = 'T1BuildEngineer',
        Priority = 1068,
        BuilderConditions = {
            { OMBC, 'IsOvermindBrain', {} },
            { OMBC, 'ShouldEmergencyRebuildEngineers', { 'LocationType', 4, 2 } },
            { UCBC, 'LocationFactoriesBuildingLess', { 'LocationType', 2, categories.ENGINEER * categories.MOBILE } },
            { OMBC, 'CanRunFactoryProduction', { 'land' } },
        },
        BuilderType = 'Land',
    },
    Builder {
        BuilderName = 'Overmind Bomber Panic Engineer Rebuild',
        PlatoonTemplate = 'T1BuildEngineer',
        Priority = 1062,
        BuilderConditions = {
            { OMBC, 'IsOvermindBrain', {} },
            { OMBC, 'IsBomberPanic', {} },
            { OMBC, 'ShouldBuildFactoryEngineer', { 'LocationType', 1.0, 6 } },
            { UCBC, 'LocationFactoriesBuildingLess', { 'LocationType', 2, categories.ENGINEER * categories.MOBILE } },
            { OMBC, 'CanRunFactoryProduction', { 'land' } },
        },
        BuilderType = 'Land',
    },
    Builder {
        BuilderName = 'Overmind T1Director Land Engineer Opener',
        PlatoonTemplate = 'T1BuildEngineer',
        Priority = 1034,
        BuilderConditions = {
            { OMBC, 'IsOvermindBrain', {} },
            { OMBC, 'ShouldBuildFactoryEngineer', { 'LocationType', 1.1, 7 } },
            { UCBC, 'LocationFactoriesBuildingLess', { 'LocationType', 2, categories.ENGINEER * categories.MOBILE } },
            { OMBC, 'CanRunFactoryProduction', { 'land' } },
        },
        BuilderType = 'Land',
    },
    Builder {
        BuilderName = 'Overmind T1Director Land Tank',
        PlatoonTemplate = 'T1LandDFTank',
        Priority = 1018,
        BuilderConditions = {
            { OMBC, 'IsOvermindBrain', {} },
            { OMBC, 'ShouldBuildT1LandRole', { 'tank' } },
            { UCBC, 'LocationFactoriesBuildingLess', { 'LocationType', 8, categories.MOBILE * categories.LAND * categories.DIRECTFIRE * categories.TECH1 } },
            { OMBC, 'CanRunFactoryProduction', { 'land' } },
        },
        BuilderType = 'Land',
    },
    Builder {
        BuilderName = 'Overmind T1Director Land AA',
        PlatoonTemplate = 'T1LandAA',
        Priority = 1010,
        BuilderConditions = {
            { OMBC, 'IsOvermindBrain', {} },
            { OMBC, 'ShouldBuildT1LandRole', { 'aa' } },
            { UCBC, 'LocationFactoriesBuildingLess', { 'LocationType', 6, categories.MOBILE * categories.LAND * categories.ANTIAIR * categories.TECH1 } },
            { OMBC, 'CanRunFactoryProduction', { 'land' } },
        },
        BuilderType = 'Land',
    },
    Builder {
        BuilderName = 'Overmind T1Director Land Indirect',
        PlatoonTemplate = 'T1LandArtillery',
        Priority = 1012,
        BuilderConditions = {
            { OMBC, 'IsOvermindBrain', {} },
            { OMBC, 'ShouldBuildT1LandRole', { 'indirect' } },
            { UCBC, 'LocationFactoriesBuildingLess', { 'LocationType', 5, categories.MOBILE * categories.LAND * categories.INDIRECTFIRE * categories.TECH1 } },
            { OMBC, 'CanRunFactoryProduction', { 'land' } },
        },
        BuilderType = 'Land',
    },
    Builder {
        BuilderName = 'Overmind T1Director Land Scout',
        PlatoonTemplate = 'T1LandScout',
        Priority = 996,
        BuilderConditions = {
            { OMBC, 'IsOvermindBrain', {} },
            { OMBC, 'ShouldBuildT1LandRole', { 'scout' } },
            { UCBC, 'LocationFactoriesBuildingLess', { 'LocationType', 2, categories.MOBILE * categories.LAND * categories.SCOUT * categories.TECH1 } },
            { OMBC, 'CanRunFactoryProduction', { 'land' } },
        },
        BuilderType = 'Land',
    },
    Builder {
        BuilderName = 'Overmind T1Director Air Fighter',
        PlatoonTemplate = 'T1AirFighter',
        Priority = 1020,
        BuilderConditions = {
            { OMBC, 'IsOvermindBrain', {} },
            { OMBC, 'ShouldBuildT1AirRole', { 'fighter' } },
            { UCBC, 'LocationFactoriesBuildingLess', { 'LocationType', 8, categories.MOBILE * categories.AIR * categories.ANTIAIR * categories.TECH1 } },
            { OMBC, 'CanRunFactoryProduction', { 'air' } },
        },
        BuilderType = 'Air',
    },
    Builder {
        BuilderName = 'Overmind T1Director Air Bomber',
        PlatoonTemplate = 'T1AirBomber',
        Priority = 1004,
        BuilderConditions = {
            { OMBC, 'IsOvermindBrain', {} },
            { OMBC, 'ShouldBuildT1AirRole', { 'bomber' } },
            { UCBC, 'LocationFactoriesBuildingLess', { 'LocationType', 6, categories.MOBILE * categories.AIR * categories.BOMBER * categories.TECH1 } },
            { OMBC, 'CanRunFactoryProduction', { 'air' } },
        },
        BuilderType = 'Air',
    },
    Builder {
        BuilderName = 'Overmind T1Director Air Scout',
        PlatoonTemplate = 'T1AirScout',
        Priority = 998,
        BuilderConditions = {
            { OMBC, 'IsOvermindBrain', {} },
            { OMBC, 'ShouldBuildT1AirRole', { 'scout' } },
            { UCBC, 'LocationFactoriesBuildingLess', { 'LocationType', 2, categories.MOBILE * categories.AIR * categories.SCOUT * categories.TECH1 } },
            { OMBC, 'CanRunFactoryProduction', { 'air' } },
        },
        BuilderType = 'Air',
    },
    Builder {
        BuilderName = 'Overmind T1Director Sea Frigate',
        PlatoonTemplate = 'T1SeaFrigate',
        Priority = 1010,
        BuilderConditions = {
            { OMBC, 'IsOvermindBrain', {} },
            { OMBC, 'IsT1NavalActive', {} },
            { OMBC, 'ShouldBuildT1NavalRole', { 'frigate' } },
            { UCBC, 'LocationFactoriesBuildingLess', { 'LocationType', 4, categories.MOBILE * categories.NAVAL * categories.FRIGATE * categories.TECH1 } },
            { OMBC, 'CanRunFactoryProduction', { 'sea' } },
        },
        BuilderType = 'Sea',
    },
    Builder {
        BuilderName = 'Overmind T1Director Sea Sub',
        PlatoonTemplate = 'T1SeaSub',
        Priority = 1008,
        BuilderConditions = {
            { OMBC, 'IsOvermindBrain', {} },
            { OMBC, 'IsT1NavalActive', {} },
            { OMBC, 'ShouldBuildT1NavalRole', { 'sub' } },
            { UCBC, 'LocationFactoriesBuildingLess', { 'LocationType', 4, categories.MOBILE * categories.NAVAL * categories.SUBMERSIBLE * categories.TECH1 } },
            { OMBC, 'CanRunFactoryProduction', { 'sea' } },
        },
        BuilderType = 'Sea',
    },
    Builder {
        BuilderName = 'Overmind T1Director Sea AA',
        PlatoonTemplate = 'T1SeaAntiAir',
        Priority = 1014,
        BuilderConditions = {
            { OMBC, 'IsOvermindBrain', {} },
            { OMBC, 'IsT1NavalActive', {} },
            { OMBC, 'ShouldBuildT1NavalRole', { 'aa' } },
            { UCBC, 'LocationFactoriesBuildingLess', { 'LocationType', 4, categories.MOBILE * categories.NAVAL * categories.ANTIAIR * categories.TECH1 } },
            { OMBC, 'CanRunFactoryProduction', { 'sea' } },
        },
        BuilderType = 'Sea',
    },
}

BuilderGroup {
    BuilderGroupName = 'OvermindT1DirectorStructures',
    BuildersType = 'EngineerBuilder',
    Builder {
        BuilderName = 'Overmind Guaranteed Radar Floor',
        PlatoonTemplate = 'EngineerBuilder',
        Priority = 1144,
        InstanceCount = 1,
        BuilderConditions = {
            { OMBC, 'IsOvermindBrain', {} },
            { MIBC, 'GreaterThanGameTime', { 135 } },
            { OMBC, 'NeedBaselineRadar', { 1, 180 } },
            { UCBC, 'HaveGreaterThanUnitsWithCategory', { 0, 'FACTORY STRUCTURE' } },
            { UCBC, 'LocationEngineersBuildingLess', { 'LocationType', 2, 'RADAR' } },
            { OMBC, 'HasSafeEnergy', { 0.04, -12 } },
        },
        BuilderType = 'Any',
        BuilderData = {
            Construction = {
                BuildClose = false,
                BuildStructures = { 'T1Radar' },
                Location = 'LocationType',
            },
        },
    },
    Builder {
        BuilderName = 'Overmind T1Director Radar',
        PlatoonTemplate = 'EngineerBuilder',
        Priority = 1096,
        InstanceCount = 1,
        BuilderConditions = {
            { OMBC, 'IsOvermindBrain', {} },
            { MIBC, 'GreaterThanGameTime', { 220 } },
            { OMBC, 'ShouldBuildT1StructureRole', { 'radar' } },
            { UCBC, 'LocationEngineersBuildingLess', { 'LocationType', 1, 'RADAR' } },
            { OMBC, 'HasSafeEnergy', { 0.1, -8 } },
        },
        BuilderType = 'Any',
        BuilderData = {
            Construction = {
                BuildClose = false,
                BuildStructures = { 'T1Radar' },
                Location = 'LocationType',
            },
        },
    },
    Builder {
        BuilderName = 'Overmind Coverage Radar Expansion',
        PlatoonTemplate = 'EngineerBuilder',
        Priority = 1088,
        InstanceCount = 1,
        BuilderConditions = {
            { OMBC, 'IsOvermindBrain', {} },
            { MIBC, 'GreaterThanGameTime', { 620 } },
            { OMBC, 'ShouldBuildCoverageRadar', { 2 } },
            { OMBC, 'CanSafelyExpand', { 'LocationType', 680, 1.1, 90, 8 } },
            { UCBC, 'LocationEngineersBuildingLess', { 'LocationType', 2, 'RADAR' } },
            { OMBC, 'HasSafeEnergy', { 0.16, 4 } },
        },
        BuilderType = 'Any',
        BuilderData = {
            Construction = {
                BuildClose = false,
                BuildStructures = { 'T1Radar' },
                Location = 'LocationType',
            },
        },
    },
    Builder {
        BuilderName = 'Overmind T1Director PD',
        PlatoonTemplate = 'EngineerBuilder',
        Priority = 1068,
        InstanceCount = 1,
        BuilderConditions = {
            { OMBC, 'IsOvermindBrain', {} },
            { OMBC, 'ShouldBuildT1StructureRole', { 'pd' } },
            { UCBC, 'LocationEngineersBuildingLess', { 'LocationType', 1, 'DEFENSE DIRECTFIRE' } },
            { OMBC, 'HasSafeEnergy', { 0.01, -24 } },
        },
        BuilderType = 'Any',
        BuilderData = {
            Construction = {
                BuildClose = true,
                BuildStructures = { 'T1GroundDefense' },
                Location = 'LocationType',
            },
        },
    },
    Builder {
        BuilderName = 'Overmind T1Director Base AA',
        PlatoonTemplate = 'EngineerBuilder',
        Priority = 1072,
        InstanceCount = 1,
        BuilderConditions = {
            { OMBC, 'IsOvermindBrain', {} },
            { OMBC, 'ShouldBuildT1StructureRole', { 'aa' } },
            { UCBC, 'LocationEngineersBuildingLess', { 'LocationType', 1, 'DEFENSE ANTIAIR' } },
            { OMBC, 'HasSafeEnergy', { 0.01, -24 } },
        },
        BuilderType = 'Any',
        BuilderData = {
            Construction = {
                BuildClose = true,
                BuildStructures = { 'T1AADefense' },
                Location = 'LocationType',
            },
        },
    },
    Builder {
        BuilderName = 'Overmind Bomber Panic Base AA Floor',
        PlatoonTemplate = 'EngineerBuilder',
        Priority = 1118,
        InstanceCount = 1,
        BuilderConditions = {
            { OMBC, 'IsOvermindBrain', {} },
            { OMBC, 'IsBomberPanic', {} },
            { UCBC, 'UnitsLessAtLocation', { 'LocationType', 3, 'DEFENSE ANTIAIR TECH1 STRUCTURE' } },
            { UCBC, 'LocationEngineersBuildingLess', { 'LocationType', 2, 'DEFENSE ANTIAIR' } },
            { OMBC, 'HasSafeEnergy', { 0.001, -32 } },
        },
        BuilderType = 'Any',
        BuilderData = {
            Construction = {
                BuildClose = true,
                BuildStructures = { 'T1AADefense' },
                Location = 'LocationType',
            },
        },
    },
    Builder {
        BuilderName = 'Overmind T1Director Sonar',
        PlatoonTemplate = 'EngineerBuilder',
        Priority = 1055,
        InstanceCount = 1,
        BuilderConditions = {
            { OMBC, 'IsOvermindBrain', {} },
            { OMBC, 'IsT1NavalActive', {} },
            { OMBC, 'ShouldBuildT1StructureRole', { 'sonar' } },
            { UCBC, 'LocationEngineersBuildingLess', { 'LocationType', 1, 'SONAR' } },
            { OMBC, 'HasSafeEnergy', { 0.02, -20 } },
        },
        BuilderType = 'Any',
        BuilderData = {
            Construction = {
                BuildStructures = { 'T1Sonar' },
                Location = 'LocationType',
            },
        },
    },
    Builder {
        BuilderName = 'Overmind T1Director Naval Defense',
        PlatoonTemplate = 'EngineerBuilder',
        Priority = 1060,
        InstanceCount = 1,
        BuilderConditions = {
            { OMBC, 'IsOvermindBrain', {} },
            { OMBC, 'IsT1NavalActive', {} },
            { OMBC, 'ShouldBuildT1StructureRole', { 'navaldef' } },
            { UCBC, 'LocationEngineersBuildingLess', { 'LocationType', 1, 'DEFENSE NAVAL' } },
            { OMBC, 'HasSafeEnergy', { 0.02, -20 } },
        },
        BuilderType = 'Any',
        BuilderData = {
            Construction = {
                BuildStructures = { 'T1NavalDefense' },
                Location = 'LocationType',
            },
        },
    },
}

BuilderGroup {
    BuilderGroupName = 'OvermindScoutFactoryPressure',
    BuildersType = 'FactoryBuilder',
    Builder {
        BuilderName = 'Overmind T1 Air Scout Pressure',
        PlatoonTemplate = 'T1AirScout',
        Priority = 925,
        BuilderConditions = {
            { OMBC, 'IsOvermindBrain', {} },
            { UCBC, 'HaveLessThanUnitsWithCategory', { 4, categories.SCOUT * categories.AIR } },
            { UCBC, 'LocationFactoriesBuildingLess', { 'LocationType', 2, categories.SCOUT * categories.AIR } },
            { OMBC, 'CanRunFactoryProduction', { 'air' } },
        },
        BuilderType = 'Air',
    },
    Builder {
        BuilderName = 'Overmind T1 Land Scout Pressure',
        PlatoonTemplate = 'T1LandScout',
        Priority = 920,
        BuilderConditions = {
            { OMBC, 'IsOvermindBrain', {} },
            { UCBC, 'HaveLessThanUnitsWithCategory', { 3, categories.SCOUT * categories.LAND } },
            { UCBC, 'LocationFactoriesBuildingLess', { 'LocationType', 2, categories.SCOUT * categories.LAND } },
            { OMBC, 'CanRunFactoryProduction', { 'land' } },
            { IBC, 'BrainNotLowPowerMode', {} },
        },
        BuilderType = 'Land',
    },
}

BuilderGroup {
    BuilderGroupName = 'OvermindScoutFactoryRecovery',
    BuildersType = 'FactoryBuilder',
    Builder {
        BuilderName = 'Overmind Recovery Air Scout',
        PlatoonTemplate = 'T1AirScout',
        Priority = 980,
        BuilderConditions = {
            { OMBC, 'IsOvermindBrain', {} },
            { OMBC, 'ShouldForceScoutRecovery', {} },
            { UCBC, 'LocationFactoriesBuildingLess', { 'LocationType', 2, categories.SCOUT * categories.AIR } },
            { UCBC, 'HaveLessThanUnitsWithCategory', { 4, categories.SCOUT * categories.AIR } },
            { OMBC, 'CanRunFactoryProduction', { 'air' } },
        },
        BuilderType = 'Air',
    },
    Builder {
        BuilderName = 'Overmind Recovery Land Scout',
        PlatoonTemplate = 'T1LandScout',
        Priority = 970,
        BuilderConditions = {
            { OMBC, 'IsOvermindBrain', {} },
            { OMBC, 'ShouldForceScoutRecovery', {} },
            { UCBC, 'LocationFactoriesBuildingLess', { 'LocationType', 2, categories.SCOUT * categories.LAND } },
            { UCBC, 'HaveLessThanUnitsWithCategory', { 3, categories.SCOUT * categories.LAND } },
            { OMBC, 'CanRunFactoryProduction', { 'land' } },
        },
        BuilderType = 'Land',
    },
}

BuilderGroup {
    BuilderGroupName = 'OvermindFactoryHeartbeatProduction',
    BuildersType = 'FactoryBuilder',
    Builder {
        BuilderName = 'Overmind Deadlock Break Engineer',
        PlatoonTemplate = 'T1BuildEngineer',
        Priority = 1128,
        BuilderConditions = {
            { OMBC, 'IsOvermindBrain', {} },
            { OMBC, 'ShouldUseLegacyFactoryProduction', { 'deadlock' } },
            { OMBC, 'ShouldFactoryDeadlockBreak', { 25 } },
            { UCBC, 'LocationFactoriesBuildingLess', { 'LocationType', 2, categories.ENGINEER * categories.MOBILE } },
        },
        BuilderType = 'Land',
    },
    Builder {
        BuilderName = 'Overmind Deadlock Break Tank',
        PlatoonTemplate = 'T1LandDFTank',
        Priority = 1124,
        BuilderConditions = {
            { OMBC, 'IsOvermindBrain', {} },
            { OMBC, 'ShouldUseLegacyFactoryProduction', { 'deadlock' } },
            { OMBC, 'ShouldFactoryDeadlockBreak', { 25 } },
            { UCBC, 'LocationFactoriesBuildingLess', { 'LocationType', 2, categories.MOBILE * categories.LAND * categories.DIRECTFIRE * categories.TECH1 } },
        },
        BuilderType = 'Land',
    },
    Builder {
        BuilderName = 'Overmind Deadlock Break Scout',
        PlatoonTemplate = 'T1LandScout',
        Priority = 1122,
        BuilderConditions = {
            { OMBC, 'IsOvermindBrain', {} },
            { OMBC, 'ShouldUseLegacyFactoryProduction', { 'deadlock' } },
            { OMBC, 'ShouldFactoryDeadlockBreak', { 25 } },
            { UCBC, 'LocationFactoriesBuildingLess', { 'LocationType', 1, categories.MOBILE * categories.LAND * categories.SCOUT * categories.TECH1 } },
        },
        BuilderType = 'Land',
    },
    Builder {
        BuilderName = 'Overmind Bomber Panic Land AA Floor',
        PlatoonTemplate = 'T1LandAA',
        Priority = 1132,
        BuilderConditions = {
            { OMBC, 'IsOvermindBrain', {} },
            { OMBC, 'ShouldUseLegacyFactoryProduction', { 'recovery' } },
            { OMBC, 'IsBomberPanic', {} },
            { UCBC, 'LocationFactoriesBuildingLess', { 'LocationType', 4, categories.MOBILE * categories.LAND * categories.ANTIAIR * categories.TECH1 } },
        },
        BuilderType = 'Land',
    },
    Builder {
        BuilderName = 'Overmind Baseline Land AA Mix',
        PlatoonTemplate = 'T1LandAA',
        Priority = 946,
        BuilderConditions = {
            { OMBC, 'IsOvermindBrain', {} },
            { OMBC, 'ShouldUseLegacyFactoryProduction', { 'recovery' } },
            { UCBC, 'HaveGreaterThanUnitsWithCategory', { 10, categories.MOBILE * categories.LAND - categories.ENGINEER - categories.SCOUT - categories.COMMAND } },
            { UCBC, 'HaveLessThanUnitsWithCategory', { 3, categories.MOBILE * categories.LAND * categories.ANTIAIR } },
            { UCBC, 'LocationFactoriesBuildingLess', { 'LocationType', 1, categories.MOBILE * categories.LAND * categories.ANTIAIR } },
            { EBC, 'GreaterThanEconEfficiencyOverTime', { 0.5, 0.6 } },
        },
        BuilderType = 'Land',
    },
    Builder {
        BuilderName = 'Overmind Baseline Fighter Mix',
        PlatoonTemplate = 'T1AirFighter',
        Priority = 944,
        BuilderConditions = {
            { OMBC, 'IsOvermindBrain', {} },
            { OMBC, 'ShouldUseLegacyFactoryProduction', { 'recovery' } },
            { UCBC, 'FactoryGreaterAtLocation', { 'LocationType', 0, 'AIR' } },
            { UCBC, 'HaveLessThanUnitsWithCategory', { 4, categories.MOBILE * categories.AIR * categories.ANTIAIR } },
            { UCBC, 'LocationFactoriesBuildingLess', { 'LocationType', 1, categories.MOBILE * categories.AIR * categories.ANTIAIR } },
            { EBC, 'GreaterThanEconEfficiencyOverTime', { 0.5, 0.6 } },
        },
        BuilderType = 'Air',
    },
    Builder {
        BuilderName = 'Overmind Harass Response Land AA',
        PlatoonTemplate = 'T1LandAA',
        Priority = 1036,
        BuilderConditions = {
            { OMBC, 'IsOvermindBrain', {} },
            { OMBC, 'ShouldUseLegacyFactoryProduction', { 'recovery' } },
            { OMBC, 'IsUnderAirHarass', { 1 } },
            { UCBC, 'LocationFactoriesBuildingLess', { 'LocationType', 3, categories.MOBILE * categories.LAND * categories.ANTIAIR } },
            { EBC, 'GreaterThanEconEfficiencyOverTime', { 0.32, 0.42 } },
        },
        BuilderType = 'Land',
    },
    Builder {
        BuilderName = 'Overmind Harass Response Land Tank',
        PlatoonTemplate = 'T1LandDFTank',
        Priority = 1018,
        BuilderConditions = {
            { OMBC, 'IsOvermindBrain', {} },
            { OMBC, 'ShouldUseLegacyFactoryProduction', { 'recovery' } },
            { OMBC, 'IsUnderLandHarass', { 1 } },
            { UCBC, 'LocationFactoriesBuildingLess', { 'LocationType', 3, categories.MOBILE * categories.LAND - categories.ENGINEER - categories.SCOUT - categories.COMMAND } },
            { EBC, 'GreaterThanEconEfficiencyOverTime', { 0.52, 0.62 } },
        },
        BuilderType = 'Land',
    },
    Builder {
        BuilderName = 'Overmind Harass Response Fighter',
        PlatoonTemplate = 'T1AirFighter',
        Priority = 1042,
        BuilderConditions = {
            { OMBC, 'IsOvermindBrain', {} },
            { OMBC, 'ShouldUseLegacyFactoryProduction', { 'recovery' } },
            { OMBC, 'IsUnderAirHarass', { 1 } },
            { UCBC, 'LocationFactoriesBuildingLess', { 'LocationType', 3, categories.MOBILE * categories.AIR * categories.ANTIAIR } },
            { EBC, 'GreaterThanEconEfficiencyOverTime', { 0.34, 0.44 } },
        },
        BuilderType = 'Air',
    },
    Builder {
        BuilderName = 'Overmind Bomber Intercept Fighter Burst',
        PlatoonTemplate = 'T1AirFighter',
        Priority = 1048,
        BuilderConditions = {
            { OMBC, 'IsOvermindBrain', {} },
            { OMBC, 'ShouldUseLegacyFactoryProduction', { 'recovery' } },
            { OMBC, 'IsUnderBomberHarass', { 1 } },
            { UCBC, 'LocationFactoriesBuildingLess', { 'LocationType', 4, categories.MOBILE * categories.AIR * categories.ANTIAIR } },
            { EBC, 'GreaterThanEconEfficiencyOverTime', { 0.28, 0.38 } },
        },
        BuilderType = 'Air',
    },
    Builder {
        BuilderName = 'Overmind Doctrine Engineer Sustain',
        PlatoonTemplate = 'T1BuildEngineer',
        Priority = 940,
        BuilderConditions = {
            { OMBC, 'IsOvermindBrain', {} },
            { OMBC, 'ShouldUseLegacyFactoryProduction', { 'recovery' } },
            { OMBC, 'ShouldBuildFactoryEngineer', { 'LocationType', 1.2, 6 } },
            { UCBC, 'LocationFactoriesBuildingLess', { 'LocationType', 1, categories.ENGINEER * categories.MOBILE } },
            { EBC, 'GreaterThanEconEfficiencyOverTime', { 0.65, 0.8 } },
        },
        BuilderType = 'Land',
    },
    Builder {
        BuilderName = 'Overmind Heartbeat Engineer Burst',
        PlatoonTemplate = 'T1BuildEngineer',
        Priority = 955,
        BuilderConditions = {
            { OMBC, 'IsOvermindBrain', {} },
            { OMBC, 'ShouldUseLegacyFactoryProduction', { 'recovery' } },
            { OMBC, 'NeedFactoryHeartbeatProduction', { 0.25, 1, 40 } },
            { UCBC, 'LocationFactoriesBuildingLess', { 'LocationType', 1, categories.ENGINEER * categories.MOBILE } },
            { EBC, 'GreaterThanEconEfficiencyOverTime', { 0.55, 0.7 } },
        },
        BuilderType = 'Land',
    },
    Builder {
        BuilderName = 'Overmind Doctrine Land Tank',
        PlatoonTemplate = 'T1LandDFTank',
        Priority = 935,
        BuilderConditions = {
            { OMBC, 'IsOvermindBrain', {} },
            { OMBC, 'ShouldUseLegacyFactoryProduction', { 'recovery' } },
            { OMBC, 'ShouldBuildLandDoctrine', { 'tank' } },
            { UCBC, 'LocationFactoriesBuildingLess', { 'LocationType', 1, categories.MOBILE * categories.LAND - categories.ENGINEER - categories.SCOUT - categories.COMMAND } },
            { EBC, 'GreaterThanEconEfficiencyOverTime', { 0.65, 0.8 } },
        },
        BuilderType = 'Land',
    },
    Builder {
        BuilderName = 'Overmind Doctrine Land AA',
        PlatoonTemplate = 'T1LandAA',
        Priority = 938,
        BuilderConditions = {
            { OMBC, 'IsOvermindBrain', {} },
            { OMBC, 'ShouldUseLegacyFactoryProduction', { 'recovery' } },
            { OMBC, 'ShouldBuildLandDoctrine', { 'aa' } },
            { UCBC, 'LocationFactoriesBuildingLess', { 'LocationType', 1, categories.MOBILE * categories.LAND * categories.ANTIAIR } },
            { EBC, 'GreaterThanEconEfficiencyOverTime', { 0.62, 0.78 } },
        },
        BuilderType = 'Land',
    },
    Builder {
        BuilderName = 'Overmind Doctrine Land Artillery',
        PlatoonTemplate = 'T1LandArtillery',
        Priority = 932,
        BuilderConditions = {
            { OMBC, 'IsOvermindBrain', {} },
            { OMBC, 'ShouldUseLegacyFactoryProduction', { 'recovery' } },
            { OMBC, 'ShouldBuildLandDoctrine', { 'indirect' } },
            { UCBC, 'LocationFactoriesBuildingLess', { 'LocationType', 1, categories.MOBILE * categories.LAND * categories.INDIRECTFIRE } },
            { EBC, 'GreaterThanEconEfficiencyOverTime', { 0.68, 0.85 } },
        },
        BuilderType = 'Land',
    },
    Builder {
        BuilderName = 'Overmind Doctrine Air Fighter',
        PlatoonTemplate = 'T1AirFighter',
        Priority = 934,
        BuilderConditions = {
            { OMBC, 'IsOvermindBrain', {} },
            { OMBC, 'ShouldUseLegacyFactoryProduction', { 'recovery' } },
            { OMBC, 'ShouldBuildAirDoctrine', { 'fighter' } },
            { UCBC, 'LocationFactoriesBuildingLess', { 'LocationType', 1, categories.MOBILE * categories.AIR * categories.ANTIAIR } },
            { EBC, 'GreaterThanEconEfficiencyOverTime', { 0.62, 0.8 } },
        },
        BuilderType = 'Air',
    },
    Builder {
        BuilderName = 'Overmind Doctrine Air Bomber',
        PlatoonTemplate = 'T1AirBomber',
        Priority = 930,
        BuilderConditions = {
            { OMBC, 'IsOvermindBrain', {} },
            { OMBC, 'ShouldUseLegacyFactoryProduction', { 'recovery' } },
            { OMBC, 'ShouldBuildAirDoctrine', { 'bomber' } },
            { UCBC, 'LocationFactoriesBuildingLess', { 'LocationType', 1, categories.MOBILE * categories.AIR * categories.BOMBER } },
            { EBC, 'GreaterThanEconEfficiencyOverTime', { 0.65, 0.84 } },
        },
        BuilderType = 'Air',
    },
}

BuilderGroup {
    BuilderGroupName = 'OvermindEngineerMassBuildersHighPri',
    BuildersType = 'EngineerBuilder',
    Builder {
        BuilderName = 'Overmind Bootstrap Resource Engineer Close',
        PlatoonTemplate = 'EngineerBuilder',
        Priority = 1142,
        InstanceCount = 1,
        BuilderConditions = {
            { OMBC, 'IsOvermindBrain', {} },
            { OMBC, 'IsEconomyBootstrap', {} },
            { OMBC, 'HasBaseEngineerCoverage', { 'LocationType', 2, 85 } },
            { OMBC, 'HasSafeEnergy', { 0.03, -16 } },
            { UCBC, 'EngineerLessAtLocation', { 'LocationType', 3, 'ENGINEER TECH2, ENGINEER TECH3' } },
            { OMBC, 'CanSafelyExpand', { 'LocationType', 260, 0.7, 95, 7 } },
            { MABC, 'CanBuildOnMassLessThanDistance', { 'LocationType', 260, -500, 0.85, 0, 'AntiSurface', 1 } },
        },
        BuilderType = 'Any',
        BuilderData = {
            NeedGuard = true,
            DesiresAssist = false,
            Construction = {
                BuildStructures = { 'T1Resource' },
            },
        },
    },
    Builder {
        BuilderName = 'Overmind T1 Resource Engineer Close',
        PlatoonTemplate = 'EngineerBuilder',
        Priority = 1125,
        InstanceCount = 1,
        BuilderConditions = {
            { OMBC, 'IsOvermindBrain', {} },
            { OMBC, 'HasSafeEnergy', { 0.05, -8 } },
            { OMBC, 'HasEngineerReserve', { 'LocationType', 4 } },
            { OMBC, 'HasBaseEngineerCoverage', { 'LocationType', 3, 85 } },
            { UCBC, 'EngineerLessAtLocation', { 'LocationType', 4, 'ENGINEER TECH2, ENGINEER TECH3' } },
            { OMBC, 'CanSafelyExpand', { 'LocationType', 260, 0.5, 95, 6 } },
            { MABC, 'CanBuildOnMassLessThanDistance', { 'LocationType', 220, -500, 0.6, 0, 'AntiSurface', 1 } },
        },
        BuilderType = 'Any',
        BuilderData = {
            NeedGuard = true,
            DesiresAssist = false,
            Construction = {
                BuildStructures = { 'T1Resource' },
            },
        },
    },
    Builder {
        BuilderName = 'Overmind T1 Resource Engineer Mid',
        PlatoonTemplate = 'EngineerBuilder',
        Priority = 1075,
        InstanceCount = 1,
        BuilderConditions = {
            { OMBC, 'IsOvermindBrain', {} },
            { OMBC, 'HasSafeEnergy', { 0.05, -8 } },
            { OMBC, 'HasEngineerReserve', { 'LocationType', 5 } },
            { OMBC, 'HasBaseEngineerCoverage', { 'LocationType', 4, 90 } },
            { UCBC, 'EngineerLessAtLocation', { 'LocationType', 4, 'ENGINEER TECH2, ENGINEER TECH3' } },
            { OMBC, 'CanSafelyExpand', { 'LocationType', 450, 0.75, 100, 7 } },
            { MABC, 'CanBuildOnMassLessThanDistance', { 'LocationType', 420, -500, 0.85, 0, 'AntiSurface', 1 } },
        },
        BuilderType = 'Any',
        BuilderData = {
            NeedGuard = true,
            DesiresAssist = false,
            Construction = {
                BuildStructures = { 'T1Resource' },
            },
        },
    },
    Builder {
        BuilderName = 'Overmind T2 Resource Engineer',
        PlatoonTemplate = 'T2EngineerBuilder',
        Priority = 1025,
        InstanceCount = 2,
        BuilderConditions = {
            { OMBC, 'IsOvermindBrain', {} },
            { OMBC, 'HasSafeEnergy', { 0.1, -4 } },
            { OMBC, 'HasBaseEngineerCoverage', { 'LocationType', 2, 80 } },
            { OMBC, 'CanSafelyExpand', { 'LocationType', 850, 1.1, 85, 8 } },
            { MABC, 'CanBuildOnMassLessThanDistance', { 'LocationType', 900, -500, 1.2, 0, 'AntiSurface', 1 } },
        },
        BuilderType = 'Any',
        BuilderData = {
            DesiresAssist = false,
            Construction = {
                BuildStructures = { 'T2Resource' },
            },
        },
    },
    Builder {
        BuilderName = 'Overmind T3 Resource Engineer',
        PlatoonTemplate = 'T3EngineerBuilder',
        Priority = 1010,
        BuilderConditions = {
            { OMBC, 'IsOvermindBrain', {} },
            { OMBC, 'HasSafeEnergy', { 0.25, 5 } },
            { OMBC, 'CanSafelyExpand', { 'LocationType', 920, 1.25, 85, 9 } },
            { MABC, 'CanBuildOnMassLessThanDistance', { 'LocationType', 950, -500, 1.4, 0, 'AntiSurface', 1 } },
        },
        BuilderType = 'Any',
        BuilderData = {
            DesiresAssist = false,
            Construction = {
                BuildStructures = { 'T3Resource' },
            },
        },
    },
    Builder {
        BuilderName = 'Overmind T3 Mass Fab Overflow',
        PlatoonTemplate = 'T3EngineerBuilder',
        Priority = 880,
        BuilderConditions = {
            { OMBC, 'IsOvermindBrain', {} },
            { UCBC, 'HaveLessThanUnitsInCategoryBeingBuilt', { 1, 'MASSFABRICATION' } },
            { UCBC, 'HaveLessThanUnitsWithCategory', { 6, 'MASSFABRICATION' } },
            { UCBC, 'HaveGreaterThanUnitsWithCategory', { 1, 'ENERGYPRODUCTION TECH3' } },
            { UCBC, 'HaveGreaterThanUnitsWithCategory', { 3, 'MASSEXTRACTION TECH3' } },
            { OMBC, 'ShouldBuildMassFab', {} },
            { EBC, 'GreaterThanEconEfficiencyOverTime', { 0.95, 1.12 } },
            { IBC, 'BrainNotLowPowerMode', {} },
        },
        BuilderType = 'Any',
        BuilderData = {
            Construction = {
                BuildClose = true,
                AdjacencyCategory = 'ENERGYPRODUCTION',
                BuildStructures = { 'T3MassCreation' },
            },
        },
    },
}

BuilderGroup {
    BuilderGroupName = 'OvermindEngineerMassBuildersLowerPri',
    BuildersType = 'EngineerBuilder',
    Builder {
        BuilderName = 'Overmind T1 Resource Engineer Far',
        PlatoonTemplate = 'EngineerBuilder',
        Priority = 930,
        InstanceCount = 1,
        BuilderConditions = {
            { OMBC, 'IsOvermindBrain', {} },
            { OMBC, 'HasSafeEnergy', { 0.12, -2 } },
            { OMBC, 'ShouldDoFarExpansion', { 'LocationType', 330, 0.24, 0.95, 20, 3 } },
            { OMBC, 'CanSafelyExpand', { 'LocationType', 760, 0.95, 95, 8 } },
            { MABC, 'CanBuildOnMassLessThanDistance', { 'LocationType', 820, -500, 1.2, 0, 'AntiSurface', 1 } },
        },
        BuilderType = 'Any',
        BuilderData = {
            NeedGuard = true,
            DesiresAssist = false,
            Construction = {
                BuildStructures = { 'T1Resource' },
            },
        },
    },
    Builder {
        BuilderName = 'Overmind T2 Resource Engineer Far',
        PlatoonTemplate = 'T2EngineerBuilder',
        Priority = 900,
        InstanceCount = 1,
        BuilderConditions = {
            { OMBC, 'IsOvermindBrain', {} },
            { OMBC, 'HasSafeEnergy', { 0.25, 0 } },
            { OMBC, 'ShouldDoFarExpansion', { 'LocationType', 420, 0.3, 0.98, 24, 3 } },
            { OMBC, 'CanSafelyExpand', { 'LocationType', 920, 1.15, 95, 9 } },
            { MABC, 'CanBuildOnMassLessThanDistance', { 'LocationType', 980, -500, 1.5, 0, 'AntiSurface', 1 } },
        },
        BuilderType = 'Any',
        BuilderData = {
            DesiresAssist = false,
            Construction = {
                BuildStructures = { 'T2Resource' },
            },
        },
    },
}

BuilderGroup {
    BuilderGroupName = 'OvermindEngineerEnergyBuilders',
    BuildersType = 'EngineerBuilder',
    Builder {
        BuilderName = 'Overmind Bootstrap T1 Power',
        PlatoonTemplate = 'EngineerBuilder',
        Priority = 1150,
        InstanceCount = 3,
        BuilderConditions = {
            { OMBC, 'IsOvermindBrain', {} },
            { OMBC, 'IsEconomyBootstrap', {} },
            { OMBC, 'ShouldBuildPower', {} },
        },
        BuilderType = 'Any',
        BuilderData = {
            Construction = {
                BuildClose = false,
                AdjacencyCategory = 'FACTORY',
                BuildStructures = { 'T1EnergyProduction' },
            },
        },
    },
    Builder {
        BuilderName = 'Overmind T1 Power Emergency',
        PlatoonTemplate = 'EngineerBuilder',
        Priority = 1080,
        InstanceCount = 1,
        BuilderConditions = {
            { OMBC, 'IsOvermindBrain', {} },
            { OMBC, 'ShouldBuildPower', {} },
            { EBC, 'LessThanEconStorageRatio', { 1.0, 0.55 } },
            { EBC, 'LessThanEconEfficiencyOverTime', { 2.0, 1.08 } },
        },
        BuilderType = 'Any',
        BuilderData = {
            Construction = {
                BuildClose = false,
                AdjacencyCategory = 'FACTORY',
                BuildStructures = { 'T1EnergyProduction' },
            },
        },
    },
    Builder {
        BuilderName = 'Overmind First T2 Power Spike',
        PlatoonTemplate = 'T2EngineerBuilder',
        Priority = 1095,
        InstanceCount = 1,
        BuilderConditions = {
            { OMBC, 'IsOvermindBrain', {} },
            { OMBC, 'ShouldPrioritizeFirstTech2Power', {} },
        },
        BuilderType = 'Any',
        BuilderData = {
            Construction = {
                BuildClose = false,
                BuildStructures = { 'T2EnergyProduction' },
            },
        },
    },
    Builder {
        BuilderName = 'Overmind T2 Power Sustain',
        PlatoonTemplate = 'T2EngineerBuilder',
        Priority = 1025,
        InstanceCount = 1,
        BuilderConditions = {
            { OMBC, 'IsOvermindBrain', {} },
            { OMBC, 'ShouldBuildPower', {} },
            { EBC, 'LessThanEconStorageRatio', { 1.0, 0.65 } },
            { EBC, 'LessThanEconEfficiencyOverTime', { 2.0, 1.12 } },
        },
        BuilderType = 'Any',
        BuilderData = {
            Construction = {
                BuildClose = false,
                BuildStructures = { 'T2EnergyProduction' },
            },
        },
    },
    Builder {
        BuilderName = 'Overmind T3 Power Scale',
        PlatoonTemplate = 'T3EngineerBuilder',
        Priority = 1000,
        InstanceCount = 1,
        BuilderConditions = {
            { OMBC, 'IsOvermindBrain', {} },
            { OMBC, 'ShouldBuildPower', {} },
            { EBC, 'LessThanEconStorageRatio', { 1.0, 0.75 } },
            { EBC, 'LessThanEconEfficiencyOverTime', { 2.0, 1.2 } },
            { EBC, 'GreaterThanEconIncome', { 5, 120 } },
        },
        BuilderType = 'Any',
        BuilderData = {
            Construction = {
                BuildClose = false,
                BuildStructures = { 'T3EnergyProduction' },
            },
        },
    },
}

BuilderGroup {
    BuilderGroupName = 'OvermindEngineerReclaimPressure',
    BuildersType = 'EngineerBuilder',
    Builder {
        BuilderName = 'Overmind T1 Reclaim Pressure',
        PlatoonTemplate = 'EngineerBuilder',
        PlatoonAIPlan = 'ReclaimAI',
        Priority = 960,
        InstanceCount = 1,
        BuilderConditions = {
            { OMBC, 'IsOvermindBrain', {} },
            { OMBC, 'IsMassStarved', { 0.48, -0.05, 3.8 } },
            { OMBC, 'ShouldRunReclaimPressure', { 'LocationType', 300, 320 } },
            { OMBC, 'HasEngineerReserve', { 'LocationType', 4 } },
            { OMBC, 'HasBaseEngineerCoverage', { 'LocationType', 3, 80 } },
            { OMBC, 'CanReclaimSafely', { 'LocationType', 1.0, 0.95, 8 } },
            { MIBC, 'ReclaimablesInArea', { 'LocationType' } },
        },
        BuilderData = {
            LocationType = 'LocationType',
            ReclaimTime = 45,
        },
        BuilderType = 'Any',
    },
    Builder {
        BuilderName = 'Overmind T2 Reclaim Pressure',
        PlatoonTemplate = 'T2EngineerBuilder',
        PlatoonAIPlan = 'ReclaimAI',
        Priority = 940,
        InstanceCount = 1,
        BuilderConditions = {
            { OMBC, 'IsOvermindBrain', {} },
            { OMBC, 'IsMassStarved', { 0.52, -0.03, 4.6 } },
            { OMBC, 'ShouldRunReclaimPressure', { 'LocationType', 360, 380 } },
            { OMBC, 'HasEngineerReserve', { 'LocationType', 4 } },
            { OMBC, 'HasBaseEngineerCoverage', { 'LocationType', 3, 80 } },
            { OMBC, 'CanReclaimSafely', { 'LocationType', 1.05, 0.98, 8 } },
            { MIBC, 'ReclaimablesInArea', { 'LocationType' } },
        },
        BuilderData = {
            LocationType = 'LocationType',
            ReclaimTime = 45,
        },
        BuilderType = 'Any',
    },
    Builder {
        BuilderName = 'Overmind T3 Reclaim Pressure',
        PlatoonTemplate = 'T3EngineerBuilder',
        PlatoonAIPlan = 'ReclaimAI',
        Priority = 920,
        InstanceCount = 1,
        BuilderConditions = {
            { OMBC, 'IsOvermindBrain', {} },
            { OMBC, 'IsMassStarved', { 0.56, -0.01, 5.8 } },
            { OMBC, 'ShouldRunReclaimPressure', { 'LocationType', 420, 450 } },
            { OMBC, 'HasEngineerReserve', { 'LocationType', 4 } },
            { OMBC, 'HasBaseEngineerCoverage', { 'LocationType', 3, 80 } },
            { OMBC, 'CanReclaimSafely', { 'LocationType', 1.1, 1.0, 9 } },
            { MIBC, 'ReclaimablesInArea', { 'LocationType' } },
        },
        BuilderData = {
            LocationType = 'LocationType',
            ReclaimTime = 45,
        },
        BuilderType = 'Any',
    },
}

BuilderGroup {
    BuilderGroupName = 'OvermindEngineerEscortPlatoons',
    BuildersType = 'PlatoonFormBuilder',
    Builder {
        BuilderName = 'Overmind T1 Engineer Guard',
        PlatoonTemplate = 'StateMachineSmallAttackPlatoon',
        Priority = 910,
        InstanceCount = 3,
        BuilderData = {
            StateMachine = 'AIPlatoonAdaptiveGuardBehavior',
            NeverGuardBases = true,
            LocationType = 'LocationType',
        },
        BuilderConditions = {
            { OMBC, 'IsOvermindBrain', {} },
            { MIBC, 'IsIsland', { false } },
            { UCBC, 'EngineersNeedGuard', { 'LocationType' } },
            { UCBC, 'HaveGreaterThanUnitsWithCategory', { 6, categories.MOBILE * categories.LAND - categories.ENGINEER - categories.SCOUT - categories.COMMAND } },
            { UCBC, 'PoolLessAtLocation', { 'LocationType', 3, categories.MOBILE * categories.LAND - categories.ENGINEER - categories.SCOUT - categories.COMMAND } },
        },
        BuilderType = 'Any',
    },
}

BuilderGroup {
    BuilderGroupName = 'OvermindEmergencyBaseDefenses',
    BuildersType = 'EngineerBuilder',
    Builder {
        BuilderName = 'Overmind Guaranteed First AA',
        PlatoonTemplate = 'EngineerBuilder',
        Priority = 1110,
        InstanceCount = 1,
        BuilderConditions = {
            { OMBC, 'IsOvermindBrain', {} },
            { MIBC, 'GreaterThanGameTime', { 140 } },
            { UCBC, 'HaveGreaterThanUnitsWithCategory', { 0, 'FACTORY STRUCTURE' } },
            { OMBC, 'ShouldBuildT1StructureRole', { 'aa' } },
            { UCBC, 'UnitsLessAtLocation', { 'LocationType', 1, 'DEFENSE ANTIAIR TECH1' } },
            { UCBC, 'LocationEngineersBuildingLess', { 'LocationType', 1, 'DEFENSE ANTIAIR' } },
            { OMBC, 'HasSafeEnergy', { 0.005, -28 } },
        },
        BuilderType = 'Any',
        BuilderData = {
            Construction = {
                BuildClose = true,
                BuildStructures = { 'T1AADefense' },
                Location = 'LocationType',
            },
        },
    },
    Builder {
        BuilderName = 'Overmind T1 Emergency Base Defense',
        PlatoonTemplate = 'EngineerBuilder',
        Priority = 1060,
        InstanceCount = 1,
        BuilderConditions = {
            { OMBC, 'IsOvermindBrain', {} },
            { UCBC, 'HaveGreaterThanUnitsWithCategory', { 0, 'FACTORY STRUCTURE' } },
            { OMBC, 'ShouldBuildT1StructureRole', { 'pd' } },
            { UCBC, 'UnitsLessAtLocation', { 'LocationType', 2, 'DEFENSE TECH1 STRUCTURE' } },
            { OMBC, 'HasSafeEnergy', { 0.005, -28 } },
            { UCBC, 'LocationEngineersBuildingLess', { 'LocationType', 1, 'DEFENSE' } },
        },
        BuilderType = 'Any',
        BuilderData = {
            Construction = {
                BuildClose = true,
                BuildStructures = { 'T1GroundDefense' },
                Location = 'LocationType',
            },
        },
    },
    Builder {
        BuilderName = 'Overmind Recovery Base Defense',
        PlatoonTemplate = 'EngineerBuilder',
        Priority = 1075,
        InstanceCount = 1,
        BuilderConditions = {
            { OMBC, 'IsOvermindBrain', {} },
            { OMBC, 'ShouldForceDefenseRecovery', {} },
            { UCBC, 'HaveGreaterThanUnitsWithCategory', { 0, 'FACTORY STRUCTURE' } },
            { UCBC, 'LocationEngineersBuildingLess', { 'LocationType', 1, 'DEFENSE' } },
            { OMBC, 'HasSafeEnergy', { 0.005, -30 } },
        },
        BuilderType = 'Any',
        BuilderData = {
            Construction = {
                BuildClose = true,
                BuildStructures = { 'T1GroundDefense' },
                Location = 'LocationType',
            },
        },
    },
    Builder {
        BuilderName = 'Overmind Harass Response Base AA',
        PlatoonTemplate = 'EngineerBuilder',
        Priority = 1092,
        InstanceCount = 1,
        BuilderConditions = {
            { OMBC, 'IsOvermindBrain', {} },
            { OMBC, 'IsUnderAirHarass', { 1 } },
            { UCBC, 'LocationEngineersBuildingLess', { 'LocationType', 1, 'DEFENSE ANTIAIR' } },
            { UCBC, 'UnitsLessAtLocation', { 'LocationType', 10, 'DEFENSE ANTIAIR TECH1 STRUCTURE' } },
            { OMBC, 'HasSafeEnergy', { 0.01, -24 } },
        },
        BuilderType = 'Any',
        BuilderData = {
            Construction = {
                BuildClose = true,
                BuildStructures = { 'T1AADefense' },
                Location = 'LocationType',
            },
        },
    },
    Builder {
        BuilderName = 'Overmind Bomber Harass Emergency AA',
        PlatoonTemplate = 'EngineerBuilder',
        Priority = 1100,
        InstanceCount = 1,
        BuilderConditions = {
            { OMBC, 'IsOvermindBrain', {} },
            { OMBC, 'IsUnderBomberHarass', { 1 } },
            { UCBC, 'LocationEngineersBuildingLess', { 'LocationType', 2, 'DEFENSE ANTIAIR' } },
            { UCBC, 'UnitsLessAtLocation', { 'LocationType', 14, 'DEFENSE ANTIAIR TECH1 STRUCTURE' } },
            { OMBC, 'HasSafeEnergy', { 0.005, -28 } },
        },
        BuilderType = 'Any',
        BuilderData = {
            Construction = {
                BuildClose = true,
                BuildStructures = { 'T1AADefense' },
                Location = 'LocationType',
            },
        },
    },
}

BuilderGroup {
    BuilderGroupName = 'OvermindOpeningBaseSecurity',
    BuildersType = 'EngineerBuilder',
    Builder {
        BuilderName = 'Overmind Opening First PD',
        PlatoonTemplate = 'EngineerBuilder',
        Priority = 1070,
        InstanceCount = 1,
        BuilderConditions = {
            { OMBC, 'IsOvermindBrain', {} },
            { MIBC, 'GreaterThanGameTime', { 170 } },
            { MIBC, 'LessThanGameTime', { 900 } },
            { UCBC, 'HaveGreaterThanUnitsWithCategory', { 0, 'FACTORY STRUCTURE' } },
            { OMBC, 'ShouldBuildT1StructureRole', { 'pd' } },
            { UCBC, 'UnitsLessAtLocation', { 'LocationType', 1, 'DEFENSE DIRECTFIRE TECH1' } },
            { OMBC, 'HasSafeEnergy', { 0.02, -20 } },
        },
        BuilderType = 'Any',
        BuilderData = {
            Construction = {
                BuildClose = true,
                BuildStructures = { 'T1GroundDefense' },
                Location = 'LocationType',
            },
        },
    },
    Builder {
        BuilderName = 'Overmind Opening First AA',
        PlatoonTemplate = 'EngineerBuilder',
        Priority = 1068,
        InstanceCount = 1,
        BuilderConditions = {
            { OMBC, 'IsOvermindBrain', {} },
            { MIBC, 'GreaterThanGameTime', { 160 } },
            { MIBC, 'LessThanGameTime', { 900 } },
            { UCBC, 'HaveGreaterThanUnitsWithCategory', { 0, 'FACTORY STRUCTURE' } },
            { OMBC, 'ShouldBuildT1StructureRole', { 'aa' } },
            { UCBC, 'UnitsLessAtLocation', { 'LocationType', 1, 'DEFENSE ANTIAIR TECH1' } },
            { OMBC, 'HasSafeEnergy', { 0.02, -20 } },
        },
        BuilderType = 'Any',
        BuilderData = {
            Construction = {
                BuildClose = true,
                BuildStructures = { 'T1AADefense' },
                Location = 'LocationType',
            },
        },
    },
}

BuilderGroup {
    BuilderGroupName = 'OvermindThreatBaseDefenses',
    BuildersType = 'EngineerBuilder',
    Builder {
        BuilderName = 'Overmind T1 AA Threat Response',
        PlatoonTemplate = 'EngineerBuilder',
        Priority = 1045,
        InstanceCount = 1,
        BuilderConditions = {
            { OMBC, 'IsOvermindBrain', {} },
            { TBC, 'EnemyThreatGreaterThanValueAtBase', { 'LocationType', 2, 'Air', 6 } },
            { UCBC, 'UnitsLessAtLocation', { 'LocationType', 5, 'DEFENSE ANTIAIR' } },
            { OMBC, 'HasSafeEnergy', { 0.1, -8 } },
            { UCBC, 'LocationEngineersBuildingLess', { 'LocationType', 1, 'DEFENSE' } },
        },
        BuilderType = 'Any',
        BuilderData = {
            Construction = {
                BuildClose = true,
                BuildStructures = { 'T1AADefense' },
                Location = 'LocationType',
            },
        },
    },
    Builder {
        BuilderName = 'Overmind T1 PD Threat Response',
        PlatoonTemplate = 'EngineerBuilder',
        Priority = 1040,
        InstanceCount = 1,
        BuilderConditions = {
            { OMBC, 'IsOvermindBrain', {} },
            { TBC, 'EnemyThreatGreaterThanValueAtBase', { 'LocationType', 3, 'Land', 6 } },
            { UCBC, 'UnitsLessAtLocation', { 'LocationType', 5, 'DEFENSE DIRECTFIRE' } },
            { OMBC, 'HasSafeEnergy', { 0.1, -8 } },
            { UCBC, 'LocationEngineersBuildingLess', { 'LocationType', 1, 'DEFENSE' } },
        },
        BuilderType = 'Any',
        BuilderData = {
            Construction = {
                BuildClose = true,
                BuildStructures = { 'T1GroundDefense' },
                Location = 'LocationType',
            },
        },
    },
}

BuilderGroup {
    BuilderGroupName = 'OvermindEngineerEnergyBuildersExpansions',
    BuildersType = 'EngineerBuilder',
    Builder {
        BuilderName = 'Overmind Expansion T1 Power',
        PlatoonTemplate = 'EngineerBuilder',
        Priority = 960,
        InstanceCount = 1,
        BuilderConditions = {
            { OMBC, 'IsOvermindBrain', {} },
            { OMBC, 'ShouldBuildPower', {} },
            { EBC, 'LessThanEconStorageRatio', { 1.0, 0.6 } },
            { EBC, 'LessThanEconEfficiencyOverTime', { 2.0, 1.1 } },
        },
        BuilderType = 'Any',
        BuilderData = {
            Construction = {
                Location = 'LocationType',
                BuildClose = false,
                BuildStructures = { 'T1EnergyProduction' },
            },
        },
    },
    Builder {
        BuilderName = 'Overmind Expansion T2 Power',
        PlatoonTemplate = 'T2EngineerBuilder',
        Priority = 940,
        BuilderConditions = {
            { OMBC, 'IsOvermindBrain', {} },
            { OMBC, 'ShouldBuildPower', {} },
            { EBC, 'LessThanEconStorageRatio', { 1.0, 0.7 } },
            { EBC, 'GreaterThanEconIncome', { 3, 70 } },
        },
        BuilderType = 'Any',
        BuilderData = {
            Construction = {
                Location = 'LocationType',
                BuildClose = false,
                BuildStructures = { 'T2EnergyProduction' },
            },
        },
    },
}

BuilderGroup {
    BuilderGroupName = 'OvermindTimeExemptExtractorUpgrades',
    BuildersType = 'PlatoonFormBuilder',
    Builder {
        BuilderName = 'Overmind T1 Mex Upgrade Local',
        PlatoonTemplate = 'T1MassExtractorUpgrade',
        InstanceCount = 1,
        Priority = 390,
        BuilderConditions = {
            { OMBC, 'IsOvermindBrain', {} },
            { IBC, 'BrainNotLowPowerMode', {} },
            { OMBC, 'ShouldUpgradeExtractors', {} },
            { OMBC, 'ShouldUpgradeLocalExtractors', { 'tech2', 320 } },
            { OMBC, 'UnderExtractorUpgradeCap', { 'tech2' } },
        },
        FormRadius = 320,
        BuilderType = 'Any',
    },
    Builder {
        BuilderName = 'Overmind T1 Mex Upgrade Safe Remote',
        PlatoonTemplate = 'T1MassExtractorUpgrade',
        InstanceCount = 1,
        Priority = 305,
        BuilderConditions = {
            { OMBC, 'IsOvermindBrain', {} },
            { OMBC, 'ShouldUpgradeExtractors', {} },
            { OMBC, 'ShouldUpgradeRemoteExtractors', { 'tech2', 380 } },
            { OMBC, 'UnderExtractorUpgradeCap', { 'tech2' } },
        },
        FormRadius = 10000,
        BuilderType = 'Any',
    },
    Builder {
        BuilderName = 'Overmind T2 Mex Upgrade Local',
        PlatoonTemplate = 'T2MassExtractorUpgrade',
        InstanceCount = 1,
        Priority = 330,
        BuilderConditions = {
            { OMBC, 'IsOvermindBrain', {} },
            { IBC, 'BrainNotLowPowerMode', {} },
            { OMBC, 'ShouldUpgradeExtractors', {} },
            { OMBC, 'ShouldUpgradeLocalExtractors', { 'tech3', 340 } },
            { OMBC, 'UnderExtractorUpgradeCap', { 'tech3' } },
        },
        FormRadius = 340,
        BuilderType = 'Any',
    },
    Builder {
        BuilderName = 'Overmind T2 Mex Upgrade Safe Remote',
        PlatoonTemplate = 'T2MassExtractorUpgrade',
        InstanceCount = 1,
        Priority = 255,
        BuilderConditions = {
            { OMBC, 'IsOvermindBrain', {} },
            { OMBC, 'ShouldUpgradeExtractors', {} },
            { OMBC, 'ShouldUpgradeRemoteExtractors', { 'tech3', 420 } },
            { OMBC, 'UnderExtractorUpgradeCap', { 'tech3' } },
        },
        FormRadius = 10000,
        BuilderType = 'Any',
    },
}

BuilderGroup {
    BuilderGroupName = 'OvermindEngineerFactoryConstruction',
    BuildersType = 'EngineerBuilder',
    Builder {
        BuilderName = 'Overmind T1 Land Factory',
        PlatoonTemplate = 'EngineerBuilder',
        Priority = 1008,
        BuilderConditions = {
            { OMBC, 'IsOvermindBrain', {} },
            { IBC, 'BrainNotLowPowerMode', {} },
            { OMBC, 'HasNoUnfinishedFactoriesAtLocation', { 'LocationType', 180, 0 } },
            { UCBC, 'FactoryCapCheck', { 'LocationType', 'Land' } },
            { UCBC, 'UnitCapCheckLess', { 0.92 } },
            { OMBC, 'ShouldAddLandFactory', { 'LocationType' } },
        },
        BuilderType = 'Any',
        BuilderData = {
            Construction = {
                BuildClose = false,
                BuildStructures = { 'T1LandFactory' },
                Location = 'LocationType',
                AdjacencyCategory = 'ENERGYPRODUCTION',
            },
        },
    },
    Builder {
        BuilderName = 'Overmind T1 Air Factory',
        PlatoonTemplate = 'EngineerBuilder',
        Priority = 1002,
        BuilderConditions = {
            { OMBC, 'IsOvermindBrain', {} },
            { IBC, 'BrainNotLowPowerMode', {} },
            { OMBC, 'HasNoUnfinishedFactoriesAtLocation', { 'LocationType', 180, 0 } },
            { UCBC, 'FactoryCapCheck', { 'LocationType', 'Air' } },
            { UCBC, 'UnitCapCheckLess', { 0.92 } },
            { OMBC, 'ShouldAddAirFactory', { 'LocationType' } },
        },
        BuilderType = 'Any',
        BuilderData = {
            Construction = {
                BuildClose = false,
                BuildStructures = { 'T1AirFactory' },
                Location = 'LocationType',
                AdjacencyCategory = 'ENERGYPRODUCTION',
            },
        },
    },
    Builder {
        BuilderName = 'Overmind T2 Land Factory',
        PlatoonTemplate = 'T2EngineerBuilder',
        Priority = 980,
        BuilderConditions = {
            { OMBC, 'IsOvermindBrain', {} },
            { IBC, 'BrainNotLowPowerMode', {} },
            { OMBC, 'HasNoUnfinishedFactoriesAtLocation', { 'LocationType', 180, 0 } },
            { UCBC, 'FactoryCapCheck', { 'LocationType', 'Land' } },
            { UCBC, 'FactoryLessAtLocation', { 'LocationType', 5, 'LAND' } },
            { UCBC, 'UnitCapCheckLess', { 0.92 } },
            { OMBC, 'ShouldAddLandFactory', { 'LocationType' } },
        },
        BuilderType = 'Any',
        BuilderData = {
            Construction = {
                BuildClose = false,
                BuildStructures = { 'T1LandFactory' },
                Location = 'LocationType',
                AdjacencyCategory = 'ENERGYPRODUCTION',
            },
        },
    },
    Builder {
        BuilderName = 'Overmind T2 Air Factory',
        PlatoonTemplate = 'T2EngineerBuilder',
        Priority = 975,
        BuilderConditions = {
            { OMBC, 'IsOvermindBrain', {} },
            { IBC, 'BrainNotLowPowerMode', {} },
            { OMBC, 'HasNoUnfinishedFactoriesAtLocation', { 'LocationType', 180, 0 } },
            { UCBC, 'FactoryCapCheck', { 'LocationType', 'Air' } },
            { UCBC, 'FactoryLessAtLocation', { 'LocationType', 5, 'AIR' } },
            { UCBC, 'UnitCapCheckLess', { 0.92 } },
            { OMBC, 'ShouldAddAirFactory', { 'LocationType' } },
        },
        BuilderType = 'Any',
        BuilderData = {
            Construction = {
                BuildClose = false,
                BuildStructures = { 'T1AirFactory' },
                Location = 'LocationType',
                AdjacencyCategory = 'ENERGYPRODUCTION',
            },
        },
    },
}
