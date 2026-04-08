local AIUtils = import('/lua/ai/aiutilities.lua')
local OvermindMemory = import('/mods/OvermindAI/lua/AI/Overmind/Memory.lua')

local function Distance2D(a, b)
    local dx = (a[1] or 0) - (b[1] or 0)
    local dz = (a[3] or 0) - (b[3] or 0)
    return math.sqrt((dx * dx) + (dz * dz))
end

local function ScoreExpansionZone(aiBrain, ownPos, marker)
    local pos = marker.Position
    local dist = math.max(1, Distance2D(ownPos, pos))
    local distFactor = math.max(0.15, 1 - (dist / 900))

    local massNearby = aiBrain:GetNumUnitsAroundPoint(categories.MASSEXTRACTION, pos, 36, 'Enemy')
    local freeMass = aiBrain:GetNumUnitsAroundPoint(categories.MASSEXTRACTION, pos, 36, 'Ally')
    local threat = aiBrain:GetThreatAtPosition(pos, 1, true, 'AntiSurface') or 0

    local value = (6 * distFactor) + (massNearby * 1.5) - (freeMass * 0.8) - (threat * 0.35)
    return value
end

local function ScoreRaidZone(aiBrain, ownPos, marker)
    local pos = marker.Position
    local dist = math.max(1, Distance2D(ownPos, pos))
    local enemyMex = aiBrain:GetNumUnitsAroundPoint(categories.MASSEXTRACTION, pos, 28, 'Enemy')
    local enemyDef = aiBrain:GetThreatAtPosition(pos, 1, true, 'StructuresNotMex') or 0
    local risk = OvermindMemory.GetExpansionRisk(aiBrain, pos, 86) or 0
    local score = (enemyMex * 6.4) - (enemyDef * 0.7) - (risk * 1.2) - (dist / 230)
    return score
end

function Update(aiBrain, now)
    aiBrain.OvermindRuntime = aiBrain.OvermindRuntime or {}
    local runtime = aiBrain.OvermindRuntime
    runtime.ZoneModel = runtime.ZoneModel or {}

    if runtime.ZoneGraph and runtime.ZoneGraph.StaticBuilt and table.getn(runtime.ZoneGraph.Nodes or {}) > 0 then
        local graph = runtime.ZoneGraph
        runtime.ZoneModel.OwnMainPos = graph.OwnMainPos
        runtime.ZoneModel.BestExpansionPos = graph.BestExpansionPos
        runtime.ZoneModel.BestRaidPos = graph.BestRaidPos
        runtime.ZoneModel.BestScoutPos = graph.BestScoutPos
        runtime.ZoneModel.FrontLinePos = graph.FrontLinePos
        runtime.ZoneModel.BestExpansionScore = graph.BestExpansionNodeKey and ((graph.ByKey[graph.BestExpansionNodeKey] and graph.ByKey[graph.BestExpansionNodeKey].ExpansionValue) or -99999) or -99999
        runtime.ZoneModel.BestRaidScore = graph.BestRaidNodeKey and ((graph.ByKey[graph.BestRaidNodeKey] and graph.ByKey[graph.BestRaidNodeKey].RaidValue) or -99999) or -99999
        runtime.ZoneModel.HomeThreat = (graph.ByKey.home and graph.ByKey.home.Threat) or 0
        runtime.ZoneModel.ExpansionThreat = (graph.BestExpansionNodeKey and graph.ByKey[graph.BestExpansionNodeKey] and graph.ByKey[graph.BestExpansionNodeKey].Threat) or 0
        runtime.ZoneModel.MapControl = graph.MapControl or runtime.ZoneModel.MapControl or 0
        runtime.ZoneModel.NavMarkerCount = graph.WaterZones or runtime.ZoneModel.NavMarkerCount or 0
        runtime.ZoneModel.Zones = graph.Nodes
        runtime.ZoneModel.LastUpdate = now
        return
    end

    local startX, startZ = aiBrain:GetArmyStartPos()
    local ownPos = { startX, 0, startZ }
    if aiBrain.BuilderManagers and aiBrain.BuilderManagers.MAIN and aiBrain.BuilderManagers.MAIN.Position then
        ownPos = aiBrain.BuilderManagers.MAIN.Position
    end

    local expansionMarkers = AIUtils.AIGetMarkerLocations(aiBrain, 'Expansion Area')
    local massMarkers = AIUtils.AIGetMarkerLocations(aiBrain, 'Mass')
    local navalMarkers = AIUtils.AIGetMarkerLocations(aiBrain, 'Naval Area')

    local bestExpansion = false
    local bestExpansionScore = -99999
    for _, marker in expansionMarkers do
        local score = ScoreExpansionZone(aiBrain, ownPos, marker)
        if score > bestExpansionScore then
            bestExpansionScore = score
            bestExpansion = marker.Position
        end
    end

    local bestRaid = false
    local bestRaidScore = -99999
    for _, marker in massMarkers do
        local score = ScoreRaidZone(aiBrain, ownPos, marker)
        if score > bestRaidScore then
            bestRaidScore = score
            bestRaid = marker.Position
        end
    end

    local homeThreat = aiBrain:GetThreatAtPosition(ownPos, 2, true, 'AntiSurface') or 0
    local expansionThreat = 0
    local raidThreat = 0
    if bestExpansion then
        expansionThreat = aiBrain:GetThreatAtPosition(bestExpansion, 2, true, 'AntiSurface') or 0
    end
    if bestRaid then
        raidThreat = aiBrain:GetThreatAtPosition(bestRaid, 2, true, 'AntiSurface') or 0
    end

    local control = 0
    local massMarkerCount = table.getn(massMarkers)
    if massMarkerCount > 0 then
        local allyMexes = aiBrain:GetCurrentUnits(categories.MASSEXTRACTION) or 0
        control = math.min(1.5, allyMexes / massMarkerCount)
    end

    runtime.ZoneModel.OwnMainPos = ownPos
    runtime.ZoneModel.BestExpansionPos = bestExpansion
    runtime.ZoneModel.BestRaidPos = bestRaid
    runtime.ZoneModel.BestExpansionScore = bestExpansionScore
    runtime.ZoneModel.BestRaidScore = bestRaidScore
    runtime.ZoneModel.HomeThreat = homeThreat
    runtime.ZoneModel.ExpansionThreat = expansionThreat
    runtime.ZoneModel.MapControl = control
    runtime.ZoneModel.NavMarkerCount = table.getn(navalMarkers)
    runtime.ZoneModel.LastUpdate = now

    if bestRaid then
        local enemyMexAtRaid = aiBrain:GetNumUnitsAroundPoint(categories.MASSEXTRACTION * categories.STRUCTURE, bestRaid, 34, 'Enemy') or 0
        if enemyMexAtRaid > 0 then
            OvermindMemory.RecordEnemySighting(aiBrain, bestRaid, enemyMexAtRaid * 0.6)
        end
        if raidThreat > 1.4 then
            OvermindMemory.RecordThreatSpike(aiBrain, bestRaid, raidThreat)
        end
    end

    if bestExpansion and expansionThreat > 1.2 then
        OvermindMemory.RecordThreatSpike(aiBrain, bestExpansion, expansionThreat)
    end
end
