local AIUtils = import('/lua/ai/AIUtilities.lua')
import('/mods/OvermindAI/lua/AI/Overmind/BuilderGroupsEconomy.lua')

local function IsOvermindPersonality(personality)
    if not personality then
        return false
    end

    return string.find(string.lower(personality), 'overmind') ~= nil
end

BaseBuilderTemplate {
    BaseTemplateName = 'OvermindMain',
    Builders = {
        -- Economy and production scaling
        'T1BalancedUpgradeBuilders',
        'T2BalancedUpgradeBuilders',
        'EngineerFactoryBuilders',
        'T1EngineerBuilders',
        'T2EngineerBuilders',
        'T3EngineerBuilders',
        'OvermindOpeningStability',
        'OvermindFactoryFloor',
        'OvermindFactoryRecoveryFallback',
        'OvermindEmergencyFactoryScale',
        'OvermindACUFactoryRecovery',
        'OvermindACUT1DirectorFactoryControl',
        'OvermindT1DirectorFactoryControl',
        'OvermindEngineerFactoryConstruction',
        'OvermindT1DirectorProduction',
        'OvermindScoutFactoryPressure',
        'OvermindScoutFactoryRecovery',
        'OvermindFactoryHeartbeatProduction',
        'EngineeringSupportBuilder',
        'OvermindEngineerEnergyBuilders',
        'OvermindEngineerMassBuildersHighPri',
        'OvermindEngineerReclaimPressure',
        'OvermindT1DirectorStructures',
        'OvermindOpeningBaseSecurity',
        'OvermindEmergencyBaseDefenses',
        'OvermindThreatBaseDefenses',
        'OvermindTimeExemptExtractorUpgrades',

        -- Commander and expansion
        'OvermindInitialACUBuilders',
        'ACUUpgrades',
        'T1ACUDefenses',
        'T2ACUDefenses',
        'T2ACUShields',
        'T3ACUShields',
        'T3ACUNukeDefenses',
        'EngineerExpansionBuildersFull',
        'EngineerExpansionBuildersSmall',
        'EngineerFirebaseBuilders',

        -- Defensive backbone
        'T1BaseDefenses',
        'T2BaseDefenses',
        'T3BaseDefenses',
        'T1LightDefenses',
        'T2LightDefenses',
        'T3LightDefenses',
        'T1DefensivePoints',
        'T2DefensivePoints',
        'T3DefensivePoints',
        'T1PerimeterDefenses',
        'T2PerimeterDefenses',
        'T3PerimeterDefenses',
        'T2Shields',
        'ShieldUpgrades',
        'T3Shields',
        'T2ArtilleryFormBuilders',
        'T3ArtilleryGroup',
        'ExperimentalArtillery',
        'T3NukeDefenses',
        'T3NukeDefenseBehaviors',
        'NukeBuildersEngineerBuilders',
        'NukeFormBuilders',
        'MiscDefensesEngineerBuilders',

        -- Naval handling
        'NavalExpansionBuilders',
        'T1SeaFactoryBuilders',
        'T2SeaFactoryBuilders',
        'T3SeaFactoryBuilders',
        'FrequentSeaAttackFormBuilders',
        'MassHunterSeaFormBuilders',

        -- Land pressure
        'T1LandFactoryBuilders',
        'T2LandFactoryBuilders',
        'T3LandFactoryBuilders',
        'FrequentLandAttackFormBuilders',
        'BigLandAttackFormBuilders',
        'OvermindEngineerEscortPlatoons',
        'MassHunterLandFormBuilders',
        'MiscLandFormBuilders',
        'UnitCapLandAttackFormBuilders',
        'T1LandAA',
        'T2LandAA',
        'T1ReactionDF',
        'T2ReactionDF',
        'T3ReactionDF',

        -- Air control
        'T1AirFactoryBuilders',
        'T2AirFactoryBuilders',
        'T3AirFactoryBuilders',
        'FrequentAirAttackFormBuilders',
        'MassHunterAirFormBuilders',
        'ACUHunterAirFormBuilders',
        'TransportFactoryBuilders',
        'T1AntiAirBuilders',
        'T2AntiAirBuilders',
        'T3AntiAirBuilders',
        'BaseGuardAirFormBuilders',
        'UnitCapAirAttackFormBuilders',

        -- Late game closers
        'MobileLandExperimentalEngineers',
        'MobileLandExperimentalForm',
        'MobileAirExperimentalEngineers',
        'MobileAirExperimentalForm',
        'SatelliteExperimentalEngineers',
        'SatelliteExperimentalForm',
    },
    NonCheatBuilders = {
        'AirScoutFactoryBuilders',
        'AirScoutFormBuilders',
        'LandScoutFactoryBuilders',
        'LandScoutFormBuilders',
        'RadarEngineerBuilders',
        'RadarUpgradeBuildersMain',
        'CounterIntelBuilders',
        'AeonOpticsEngineerBuilders',
        'CybranOpticsEngineerBuilders',
        'SonarEngineerBuilders',
        'SonarUpgradeBuilders',
    },
    BaseSettings = {
        EngineerCount = {
            Tech1 = 18,
            Tech2 = 12,
            Tech3 = 12,
            SCU = 6,
        },
        FactoryCount = {
            Land = 6,
            Air = 5,
            Sea = 1,
            Gate = 2,
        },
        MassToFactoryValues = {
            T1Value = 7,
            T2Value = 18,
            T3Value = 27,
        },
    },
    ExpansionFunction = function(aiBrain, location, markerType)
        return 0
    end,
    FirstBaseFunction = function(aiBrain)
        local setup = ScenarioInfo.ArmySetup[aiBrain.Name]
        local per = setup and setup.AIPersonality or nil
        if not per then
            return 1, 'overmind'
        end

        if IsOvermindPersonality(per) then
            local mapSizeX, mapSizeZ = GetMapSize()
            if mapSizeX <= 512 and mapSizeZ <= 512 then
                return 320, 'overmind'
            elseif mapSizeX <= 1024 and mapSizeZ <= 1024 then
                return 340, 'overmind'
            else
                return 360, 'overmind'
            end
        end

        if per == 'random' then
            return Random(1, 20), 'overmind'
        end

        return 1, 'overmind'
    end,
}

BaseBuilderTemplate {
    BaseTemplateName = 'OvermindExpansion',
    Builders = {
        'T2BalancedUpgradeBuildersExpansion',
        'EngineerFactoryBuilders',
        'T1EngineerBuilders',
        'T2EngineerBuilders',
        'T3EngineerBuilders',
        'OvermindFactoryFloor',
        'OvermindFactoryRecoveryFallback',
        'OvermindEmergencyFactoryScale',
        'OvermindT1DirectorFactoryControl',
        'OvermindEngineerFactoryConstruction',
        'OvermindT1DirectorProduction',
        'OvermindScoutFactoryPressure',
        'OvermindScoutFactoryRecovery',
        'OvermindFactoryHeartbeatProduction',
        'LandInitialFactoryConstruction',
        'OvermindEngineerMassBuildersLowerPri',
        'OvermindEngineerReclaimPressure',
        'OvermindT1DirectorStructures',
        'OvermindOpeningBaseSecurity',
        'OvermindEmergencyBaseDefenses',
        'OvermindThreatBaseDefenses',
        'OvermindEngineerEnergyBuildersExpansions',
        'EngineerExpansionBuildersFull',
        'EngineerExpansionBuildersSmall',
        'T1LightDefenses',
        'T2LightDefenses',
        'T3LightDefenses',
        'T2MissileDefenses',
        'T3NukeDefenses',
        'T3NukeDefenseBehaviors',
        'NavalExpansionBuilders',
        'T1LandFactoryBuilders',
        'T2LandFactoryBuilders',
        'T3LandFactoryBuilders',
        'FrequentLandAttackFormBuilders',
        'OvermindEngineerEscortPlatoons',
        'MassHunterLandFormBuilders',
        'MiscLandFormBuilders',
        'T1AirFactoryBuilders',
        'T2AirFactoryBuilders',
        'T3AirFactoryBuilders',
        'FrequentAirAttackFormBuilders',
        'MassHunterAirFormBuilders',
        'T1AntiAirBuilders',
        'T2AntiAirBuilders',
        'T3AntiAirBuilders',
        'BaseGuardAirFormBuilders',
        'MobileLandExperimentalEngineers',
        'MobileLandExperimentalForm',
        'MobileAirExperimentalEngineers',
        'MobileAirExperimentalForm',
    },
    NonCheatBuilders = {
        'AirScoutFactoryBuilders',
        'AirScoutFormBuilders',
        'LandScoutFactoryBuilders',
        'LandScoutFormBuilders',
        'RadarEngineerBuilders',
        'RadarUpgradeBuildersExpansion',
        'CounterIntelBuilders',
    },
    BaseSettings = {
        EngineerCount = {
            Tech1 = 14,
            Tech2 = 10,
            Tech3 = 10,
            SCU = 2,
        },
        FactoryCount = {
            Land = 4,
            Air = 3,
            Sea = 1,
            Gate = 1,
        },
        MassToFactoryValues = {
            T1Value = 7,
            T2Value = 18,
            T3Value = 27,
        },
    },
    ExpansionFunction = function(aiBrain, location, markerType)
        if markerType ~= 'Start Location' then
            return 0
        end

        local setup = ScenarioInfo.ArmySetup[aiBrain.Name]
        local personality = setup and setup.AIPersonality or nil
        if not IsOvermindPersonality(personality) then
            return 0
        end

        local now = GetGameTimeSeconds()
        if now < 1080 then
            return 0
        end

        local econ = AIUtils.AIGetEconomyNumbers(aiBrain)
        local runtime = aiBrain.OvermindRuntime or {}
        local recovery = runtime.Recovery or {}
        local ctrl = runtime.FactoryController or {}
        local queueBlocked = recovery.FactoryQueueExpansionBlocked
            or (((recovery.FactoryQueueDeficitRatio or 0) >= 0.34) and ((recovery.FactoryQueueStarvationTime or 0) >= 12))
        if queueBlocked then
            return 0
        end

        local facCount = aiBrain:GetCurrentUnits(categories.FACTORY * categories.STRUCTURE) or 0
        if facCount < 6 then
            return 0
        end
        if (econ.MassIncome or 0) < 9.0 or (econ.EnergyIncome or 0) < 260 then
            return 0
        end
        if (econ.MassStorageRatio or 0) < 0.38 or (econ.EnergyStorageRatio or 0) < 0.42 then
            return 0
        end
        if (econ.MassTrend or 0) < 0.24 or (econ.EnergyTrend or 0) < 18 then
            return 0
        end
        if (recovery.FactoryQueueDeficitRatio or 1) > 0.14 or (recovery.FactoryQueueStarvationTime or 999) > 5 then
            return 0
        end
        if (recovery.FactoryQueueUptime or 0) < 0.82 then
            return 0
        end
        if (ctrl.LastIdleCount or 0) > 2 then
            return 0
        end
        if runtime.ZoneModel and (runtime.ZoneModel.MapControl or 0) < 0.42 then
            return 0
        end
        if runtime.OpponentModel and (runtime.OpponentModel.RelativePower or 0) < 1.02 then
            return 0
        end

        local threatDistance = AIUtils.GetThreatDistance(aiBrain, location, 10)
        if not threatDistance then
            return 120
        elseif threatDistance > 900 then
            return 110
        elseif threatDistance > 450 then
            return 95
        elseif threatDistance > 225 then
            return 75
        end

        return 45
    end,
}

BaseBuilderTemplate {
    BaseTemplateName = 'OvermindNavalExpansion',
    Builders = {
        'T1SlowUpgradeBuilders',
        'T2SlowUpgradeBuilders',
        'EngineerFactoryBuilders',
        'T1EngineerBuilders',
        'T2EngineerBuilders',
        'T3EngineerBuilders',
        'OvermindFactoryFloor',
        'OvermindFactoryRecoveryFallback',
        'OvermindEmergencyFactoryScale',
        'OvermindT1DirectorFactoryControl',
        'EngineerNavalFactoryBuilder',
        'OvermindT1DirectorProduction',
        'OvermindScoutFactoryPressure',
        'OvermindScoutFactoryRecovery',
        'OvermindFactoryHeartbeatProduction',
        'OvermindEngineerMassBuildersLowerPri',
        'OvermindEngineerReclaimPressure',
        'OvermindT1DirectorStructures',
        'OvermindOpeningBaseSecurity',
        'OvermindEmergencyBaseDefenses',
        'OvermindThreatBaseDefenses',
        'T1SeaFactoryBuilders',
        'T2SeaFactoryBuilders',
        'T3SeaFactoryBuilders',
        'FrequentSeaAttackFormBuilders',
        'MassHunterSeaFormBuilders',
    },
    NonCheatBuilders = {
        'SonarEngineerBuilders',
        'SonarUpgradeBuilders',
    },
    BaseSettings = {
        EngineerCount = {
            Tech1 = 4,
            Tech2 = 3,
            Tech3 = 3,
            SCU = 0,
        },
        FactoryCount = {
            Land = 0,
            Air = 1,
            Sea = 3,
            Gate = 0,
        },
        MassToFactoryValues = {
            T1Value = 5.5,
            T2Value = 14,
            T3Value = 21,
        },
    },
    ExpansionFunction = function(aiBrain, location, markerType)
        if markerType ~= 'Naval Area' then
            return 0
        end

        local setup = ScenarioInfo.ArmySetup[aiBrain.Name]
        local personality = setup and setup.AIPersonality or nil
        if not IsOvermindPersonality(personality) then
            return 0
        end

        local mapSizeX, mapSizeZ = GetMapSize()
        if mapSizeX >= 1024 and mapSizeZ >= 1024 then
            return 95
        elseif mapSizeX >= 512 and mapSizeZ >= 512 then
            return 75
        end

        return 55
    end,
}

