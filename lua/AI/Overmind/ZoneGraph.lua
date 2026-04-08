local AIUtils = import('/lua/ai/aiutilities.lua')
local OvermindMemory = import('/mods/OvermindAI/lua/AI/Overmind/Memory.lua')

local NavUtils = false
do
    local ok, mod = pcall(import, '/lua/sim/NavUtils.lua')
    if ok and type(mod) == 'table' then
        NavUtils = mod
    end
end

local LandCombatCategory = categories.MOBILE * categories.LAND - categories.ENGINEER - categories.SCOUT - categories.COMMAND
local StructureCategory = categories.STRUCTURE - categories.WALL
local MexCategory = categories.MASSEXTRACTION * categories.STRUCTURE
local RadarCategory = categories.STRUCTURE * categories.RADAR

local function Clamp(v, minV, maxV)
    if v < minV then
        return minV
    end
    if v > maxV then
        return maxV
    end
    return v
end

local function Distance2D(a, b)
    local dx = (a[1] or 0) - (b[1] or 0)
    local dz = (a[3] or 0) - (b[3] or 0)
    return math.sqrt((dx * dx) + (dz * dz))
end

local function CopyPos(pos)
    return { pos[1] or 0, pos[2] or 0, pos[3] or 0 }
end

local function AveragePositions(points)
    local sx = 0
    local sz = 0
    local n = math.max(1, table.getn(points))
    for _, pos in points do
        sx = sx + (pos[1] or 0)
        sz = sz + (pos[3] or 0)
    end
    return {
        sx / n,
        0,
        sz / n,
    }
end

local function GetMainPos(aiBrain, runtime)
    if runtime and runtime.ZoneModel and runtime.ZoneModel.OwnMainPos then
        return runtime.ZoneModel.OwnMainPos
    end
    if aiBrain.BuilderManagers and aiBrain.BuilderManagers.MAIN and aiBrain.BuilderManagers.MAIN.Position then
        return aiBrain.BuilderManagers.MAIN.Position
    end
    local sx, sz = aiBrain:GetArmyStartPos()
    return { sx, 0, sz }
end

local function GetNearestEnemyBasePosition(aiBrain, ownPos, runtime)
    if runtime and runtime.PrimaryEnemyPos then
        return runtime.PrimaryEnemyPos
    end

    local nearestPos = false
    local nearestDist = 100000
    for _, enemyBrain in ArmyBrains do
        local isEnemy = false
        if IsEnemy then
            isEnemy = IsEnemy(enemyBrain:GetArmyIndex(), aiBrain:GetArmyIndex())
        end

        if enemyBrain ~= aiBrain and enemyBrain and not enemyBrain:IsDefeated() and isEnemy then
            local enemyPos = false
            if enemyBrain.BuilderManagers and enemyBrain.BuilderManagers.MAIN and enemyBrain.BuilderManagers.MAIN.Position then
                enemyPos = enemyBrain.BuilderManagers.MAIN.Position
            else
                local sx, sz = enemyBrain:GetArmyStartPos()
                enemyPos = { sx, 0, sz }
            end
            if enemyPos then
                local dist = Distance2D(ownPos, enemyPos)
                if dist < nearestDist then
                    nearestDist = dist
                    nearestPos = enemyPos
                end
            end
        end
    end

    return nearestPos
end

local function EnsureNavGeneration(runtime, now, probePos)
    if not NavUtils then
        return false
    end
    runtime.ZoneGraph = runtime.ZoneGraph or {}
    local graph = runtime.ZoneGraph

    local label = false
    if probePos then
        local okLabel, result = pcall(NavUtils.GetTerrainLabel, 'Land', probePos)
        if okLabel then
            label = result
        end
    end
    if not label and runtime.ZoneModel and runtime.ZoneModel.OwnMainPos then
        local okLabel, result = pcall(NavUtils.GetTerrainLabel, 'Land', runtime.ZoneModel.OwnMainPos)
        if okLabel then
            label = result
        end
    end
    if label then
        graph.NavReady = true
        return true
    end

    if (now - (graph.LastNavGenerateTry or -999)) < 30 then
        return false
    end

    graph.LastNavGenerateTry = now
    if NavUtils.Generate then
        pcall(NavUtils.Generate)
    end
    return false
end

local function GetNavLabel(layer, pos)
    if not NavUtils or not pos then
        return 0
    end
    local ok, label = pcall(NavUtils.GetTerrainLabel, layer, pos)
    if ok and type(label) == 'number' and label > 0 then
        return label
    end
    local ok2, fallback = pcall(NavUtils.GetLabel, layer, pos)
    if ok2 and type(fallback) == 'number' and fallback > 0 then
        return fallback
    end
    return 0
end

local function GetMediumLabels(pos)
    local land = GetNavLabel('Land', pos)
    local hover = GetNavLabel('Hover', pos)
    local water = GetNavLabel('Water', pos)

    local medium = 'unknown'
    if water > 0 and land <= 0 and hover <= 0 then
        medium = 'water'
    elseif land > 0 or hover > 0 then
        medium = 'land'
    end

    return {
        Medium = medium,
        LandLabel = land,
        HoverLabel = hover,
        WaterLabel = water,
    }
end

local function MarkerRecord(key, pos, markerType, value)
    return {
        Key = key,
        Position = pos,
        MarkerType = markerType,
        Value = value or 1,
    }
end

local function CollectMarkerRecords(aiBrain)
    local out = {}
    local expansions = AIUtils.AIGetMarkerLocations(aiBrain, 'Expansion Area') or {}
    for index, marker in expansions do
        if marker and marker.Position then
            table.insert(out, MarkerRecord('exp_' .. tostring(index), marker.Position, 'expansion', 3))
        end
    end

    local masses = AIUtils.AIGetMarkerLocations(aiBrain, 'Mass') or {}
    for index, marker in masses do
        if marker and marker.Position then
            table.insert(out, MarkerRecord('mass_' .. tostring(index), marker.Position, 'mass', 2))
        end
    end

    local naval = AIUtils.AIGetMarkerLocations(aiBrain, 'Naval Area') or {}
    for index, marker in naval do
        if marker and marker.Position then
            table.insert(out, MarkerRecord('nav_' .. tostring(index), marker.Position, 'naval', 2))
        end
    end

    return out
end

local function BuildClusters(records, allowHeuristic)
    local clusters = {}
    local mergeDistance = 110

    for _, record in records do
        local labels = GetMediumLabels(record.Position)
        if labels.Medium == 'unknown' and allowHeuristic then
            labels.Medium = (record.MarkerType == 'naval') and 'water' or 'land'
            labels.Heuristic = 1
        end
        if labels.Medium ~= 'unknown' then
            local matched = false
            for _, cluster in clusters do
                local sameMedium = cluster.Medium == labels.Medium
                local sameLand = true
                local sameWater = true
                if labels.Medium == 'land' and (cluster.LandLabel or 0) > 0 and (labels.LandLabel or 0) > 0 then
                    sameLand = (cluster.LandLabel or 0) == (labels.LandLabel or 0)
                elseif labels.Medium == 'water' and (cluster.WaterLabel or 0) > 0 and (labels.WaterLabel or 0) > 0 then
                    sameWater = (cluster.WaterLabel or 0) == (labels.WaterLabel or 0)
                end
                if sameMedium and ((labels.Medium == 'land' and sameLand) or (labels.Medium == 'water' and sameWater)) then
                    if Distance2D(cluster.Center, record.Position) <= mergeDistance then
                        table.insert(cluster.Positions, record.Position)
                        cluster.TotalValue = cluster.TotalValue + (record.Value or 1)
                        cluster.MarkerCount = cluster.MarkerCount + 1
                        cluster.Heuristic = math.max(cluster.Heuristic or 0, labels.Heuristic or 0)
                        if record.MarkerType == 'mass' then
                            cluster.MassCount = cluster.MassCount + 1
                        elseif record.MarkerType == 'expansion' then
                            cluster.ExpansionCount = cluster.ExpansionCount + 1
                        elseif record.MarkerType == 'naval' then
                            cluster.NavalCount = cluster.NavalCount + 1
                        end
                        cluster.Center = AveragePositions(cluster.Positions)
                        matched = true
                        break
                    end
                end
            end

            if not matched then
                table.insert(clusters, {
                    Medium = labels.Medium,
                    LandLabel = labels.LandLabel,
                    HoverLabel = labels.HoverLabel,
                    WaterLabel = labels.WaterLabel,
                    Positions = { record.Position },
                    Center = CopyPos(record.Position),
                    TotalValue = record.Value or 1,
                    MarkerCount = 1,
                    MassCount = (record.MarkerType == 'mass') and 1 or 0,
                    ExpansionCount = (record.MarkerType == 'expansion') and 1 or 0,
                    NavalCount = (record.MarkerType == 'naval') and 1 or 0,
                    Heuristic = labels.Heuristic or 0,
                })
            end
        end
    end

    return clusters
end

local function SortClusters(clusters)
    table.sort(clusters, function(a, b)
        local av = (a.TotalValue or 0) + ((a.MassCount or 0) * 1.8) + ((a.ExpansionCount or 0) * 1.6)
        local bv = (b.TotalValue or 0) + ((b.MassCount or 0) * 1.8) + ((b.ExpansionCount or 0) * 1.6)
        return av > bv
    end)
end

local function AddNode(nodes, byKey, node)
    nodes[table.getn(nodes) + 1] = node
    byKey[node.Key] = node
end

local function AddSpecialNode(nodes, byKey, key, role, pos)
    if not pos then
        return
    end
    local labels = GetMediumLabels(pos)
    AddNode(nodes, byKey, {
        Key = key,
        Role = role,
        Pos = CopyPos(pos),
        Medium = (labels.Medium ~= 'unknown') and labels.Medium or 'land',
        LandLabel = labels.LandLabel,
        HoverLabel = labels.HoverLabel,
        WaterLabel = labels.WaterLabel,
        TotalValue = (role == 'home') and 999 or 200,
        MarkerCount = 1,
        MassCount = 0,
        ExpansionCount = 0,
        NavalCount = 0,
        Heuristic = (labels.Medium == 'unknown') and 1 or 0,
        Edges = {},
        Index = 0,
    })
end

local function BuildNodes(aiBrain, runtime, allowHeuristic)
    local ownPos = GetMainPos(aiBrain, runtime)
    local enemyPos = GetNearestEnemyBasePosition(aiBrain, ownPos, runtime)
    local nodes = {}
    local byKey = {}

    AddSpecialNode(nodes, byKey, 'home', 'home', ownPos)
    AddSpecialNode(nodes, byKey, 'enemy_main', 'enemy_main', enemyPos)

    local clusters = BuildClusters(CollectMarkerRecords(aiBrain), allowHeuristic)
    SortClusters(clusters)

    local keptLand = 0
    local keptWater = 0
    for index, cluster in clusters do
        local keep = false
        if cluster.Medium == 'land' and keptLand < 14 then
            keep = true
            keptLand = keptLand + 1
        elseif cluster.Medium == 'water' and keptWater < 6 then
            keep = true
            keptWater = keptWater + 1
        end

        if keep then
            local role = 'zone'
            if cluster.ExpansionCount > cluster.MassCount and cluster.ExpansionCount >= 1 then
                role = 'expansion'
            elseif cluster.MassCount >= 1 then
                role = 'mass_cluster'
            elseif cluster.NavalCount >= 1 then
                role = 'naval'
            end

            AddNode(nodes, byKey, {
                Key = string.format('%s_%d', cluster.Medium, index),
                Role = role,
                Pos = cluster.Center,
                Medium = cluster.Medium,
                LandLabel = cluster.LandLabel,
                HoverLabel = cluster.HoverLabel,
                WaterLabel = cluster.WaterLabel,
                TotalValue = cluster.TotalValue,
                MarkerCount = cluster.MarkerCount,
                MassCount = cluster.MassCount,
                ExpansionCount = cluster.ExpansionCount,
                NavalCount = cluster.NavalCount,
                Heuristic = cluster.Heuristic or 0,
                Edges = {},
                Index = 0,
            })
        end
    end

    for index, node in nodes do
        node.Index = index
    end

    return nodes, byKey, ownPos, enemyPos
end

local function MeasureTravelDistance(layer, fromPos, toPos)
    if NavUtils and NavUtils.PathTo then
        local ok, path, _, distance = pcall(NavUtils.PathTo, layer, fromPos, toPos, nil)
        if ok and path and type(distance) == 'number' and distance > 0 then
            return distance, true
        end
    end
    return Distance2D(fromPos, toPos), false
end

local function CanConnect(a, b)
    if not a or not b or a.Key == b.Key then
        return false
    end
    if a.Medium ~= b.Medium then
        return false
    end
    if a.Medium == 'land' then
        if (a.LandLabel or 0) > 0 and (b.LandLabel or 0) > 0 then
            return (a.LandLabel or 0) == (b.LandLabel or 0)
        end
        return true
    elseif a.Medium == 'water' then
        if (a.WaterLabel or 0) > 0 and (b.WaterLabel or 0) > 0 then
            return (a.WaterLabel or 0) == (b.WaterLabel or 0)
        end
        return true
    end
    return false
end

local function TryAddEdge(a, b)
    if not CanConnect(a, b) then
        return false
    end

    local straight = Distance2D(a.Pos, b.Pos)
    local heuristic = ((a.Heuristic or 0) == 1) or ((b.Heuristic or 0) == 1)
    local maxEdgeDistance = (a.Medium == 'water') and (heuristic and 320 or 420) or (heuristic and 220 or 360)
    if straight > maxEdgeDistance and a.Role ~= 'home' and b.Role ~= 'home' and a.Role ~= 'enemy_main' and b.Role ~= 'enemy_main' then
        return false
    end

    local layer = (a.Medium == 'water') and 'Water' or 'Land'
    local travelDistance, exact = MeasureTravelDistance(layer, a.Pos, b.Pos)
    if not exact and straight > maxEdgeDistance then
        return false
    end

    table.insert(a.Edges, {
        To = b.Key,
        Distance = travelDistance,
        Exact = exact and 1 or 0,
    })
    return true
end

local function BuildEdges(nodes)
    for _, node in nodes do
        node.Edges = {}
    end

    for _, node in nodes do
        local candidates = {}
        for _, other in nodes do
            if CanConnect(node, other) then
                table.insert(candidates, {
                    Node = other,
                    Dist = Distance2D(node.Pos, other.Pos),
                })
            end
        end

        table.sort(candidates, function(a, b)
            return (a.Dist or 0) < (b.Dist or 0)
        end)

        local maxNeighbors = (node.Medium == 'water') and (((node.Heuristic or 0) == 1) and 2 or 3) or (((node.Heuristic or 0) == 1) and 3 or 4)
        local count = 0
        for _, entry in candidates do
            if count >= maxNeighbors then
                break
            end
            if TryAddEdge(node, entry.Node) then
                count = count + 1
            end
        end
    end
end

local function Dijkstra(nodes, byKey, sourceKey, edgeCostFn)
    local dist = {}
    local prev = {}
    local hops = {}
    local unvisited = {}

    for _, node in nodes do
        dist[node.Key] = 999999
        hops[node.Key] = 999
        unvisited[node.Key] = true
    end

    if not byKey[sourceKey] then
        return dist, prev, hops
    end

    dist[sourceKey] = 0
    hops[sourceKey] = 0

    while true do
        local bestKey = false
        local bestDist = 999999
        for key, active in unvisited do
            if active and (dist[key] or 999999) < bestDist then
                bestDist = dist[key]
                bestKey = key
            end
        end

        if not bestKey then
            break
        end

        unvisited[bestKey] = nil
        local node = byKey[bestKey]
        for _, edge in node.Edges or {} do
            if unvisited[edge.To] then
                local candidate = (dist[bestKey] or 999999) + (edgeCostFn and edgeCostFn(node, edge, byKey[edge.To]) or edge.Distance)
                if candidate < (dist[edge.To] or 999999) then
                    dist[edge.To] = candidate
                    prev[edge.To] = bestKey
                    hops[edge.To] = (hops[bestKey] or 0) + 1
                end
            end
        end
    end

    return dist, prev, hops
end

local function ReconstructPath(prev, byKey, sourceKey, targetKey)
    if not targetKey or not byKey[targetKey] or not byKey[sourceKey] then
        return {}
    end
    local keys = {}
    local cursor = targetKey
    local guard = 0
    while cursor and guard < 64 do
        table.insert(keys, 1, cursor)
        if cursor == sourceKey then
            break
        end
        cursor = prev[cursor]
        guard = guard + 1
    end
    if table.getn(keys) <= 0 or keys[1] ~= sourceKey then
        return {}
    end
    return keys
end

local function FindNodeByBest(nodes, fieldName, predicate)
    local best = false
    local bestValue = -999999
    for _, node in nodes do
        if node and ((not predicate) or predicate(node)) then
            local value = node[fieldName] or -999999
            if value > bestValue then
                best = node
                bestValue = value
            end
        end
    end
    return best
end

local function EvaluateNodes(aiBrain, runtime, graph, now)
    local nodes = graph.Nodes or {}
    local byKey = graph.ByKey or {}
    local ownPos = graph.OwnMainPos
    local enemyPos = graph.EnemyMainPos
    local recon = ((runtime.ReconState or {}).LastVisit) or {}

    local function DynamicEdgeCost(node, edge, other)
        local risk = OvermindMemory.GetRouteRisk(aiBrain, node.Pos, other.Pos, 3, 58) or 0
        local enemyThreat = aiBrain:GetThreatAtPosition(other.Pos, 1, true, 'AntiSurface') or 0
        return (edge.Distance or 9999) + (risk * 11) + (enemyThreat * 8)
    end

    local homeDist, homePrev, homeHops = Dijkstra(nodes, byKey, 'home', DynamicEdgeCost)
    local enemyDist, enemyPrev, enemyHops = Dijkstra(nodes, byKey, 'enemy_main', DynamicEdgeCost)

    for _, node in nodes do
        local pos = node.Pos
        local localThreat = aiBrain:GetThreatAtPosition(pos, 2, true, 'AntiSurface') or 0
        local airThreat = aiBrain:GetThreatAtPosition(pos, 2, true, 'Air') or 0
        local structureThreat = aiBrain:GetThreatAtPosition(pos, 2, true, 'StructuresNotMex') or 0
        local friendlyLand = aiBrain:GetNumUnitsAroundPoint(LandCombatCategory, pos, 70, 'Ally') or 0
        local enemyLand = aiBrain:GetNumUnitsAroundPoint(LandCombatCategory, pos, 70, 'Enemy') or 0
        local friendlyStructures = aiBrain:GetNumUnitsAroundPoint(StructureCategory, pos, 64, 'Ally') or 0
        local enemyStructures = aiBrain:GetNumUnitsAroundPoint(StructureCategory, pos, 64, 'Enemy') or 0
        local allyMex = aiBrain:GetNumUnitsAroundPoint(MexCategory, pos, 40, 'Ally') or 0
        local enemyMex = aiBrain:GetNumUnitsAroundPoint(MexCategory, pos, 40, 'Enemy') or 0
        local radarCoverage = aiBrain:GetNumUnitsAroundPoint(RadarCategory, pos, 96, 'Ally') or 0
        local expansionRisk = OvermindMemory.GetExpansionRisk(aiBrain, pos, 88) or 0
        local routeRisk = OvermindMemory.GetRouteRisk(aiBrain, ownPos, pos, 5, 64) or 0
        local freshnessAge = now - (recon[node.Key] or -1000)
        local freshnessWindow = (node.Role == 'enemy_main') and 110 or ((node.Role == 'home') and 200 or 145)
        local freshness = Clamp(1 - (freshnessAge / freshnessWindow), 0, 1)
        local distHome = homeDist[node.Key] or 999999
        local distEnemy = enemyDist[node.Key] or 999999
        local hopHome = homeHops[node.Key] or 999
        local hopEnemy = enemyHops[node.Key] or 999
        local reinforcementDepth = Clamp(1 - ((hopHome or 0) / 8), 0, 1)
        local firebaseDanger = structureThreat + (enemyStructures * 0.5)
        local degree = table.getn(node.Edges or {})

        local class = 'rear'
        if node.Key == 'home' then
            class = 'core'
        elseif node.Key == 'enemy_main' then
            class = 'enemy_side'
        elseif distEnemy + 80 < distHome then
            class = 'enemy_side'
        elseif math.abs(distHome - distEnemy) <= 120 or enemyLand > 0 and friendlyLand > 0 then
            class = 'contested'
        elseif distHome + 120 < distEnemy then
            class = (hopHome <= 1 or friendlyStructures >= 3) and 'rear' or 'front'
        else
            class = 'front'
        end

        node.GraphDistHome = distHome
        node.GraphDistEnemy = distEnemy
        node.HopHome = hopHome
        node.HopEnemy = hopEnemy
        node.FriendlyLand = friendlyLand
        node.EnemyLand = enemyLand
        node.FriendlyStructures = friendlyStructures
        node.EnemyStructures = enemyStructures
        node.Threat = localThreat
        node.AirThreat = airThreat
        node.StructureThreat = structureThreat
        node.AllyMex = allyMex
        node.EnemyMex = enemyMex
        node.RadarCoverage = radarCoverage
        node.ExpansionRisk = expansionRisk
        node.RouteRisk = routeRisk
        node.FirebaseDanger = firebaseDanger
        node.Freshness = freshness
        node.Classification = class
        node.ReinforcementDepth = reinforcementDepth
        node.ChokeFactor = ((degree <= 2) and 1 or 0)

        node.RallyValue = math.max(0, (friendlyLand * 0.6) + (reinforcementDepth * 10) - (routeRisk * 0.8) - (localThreat * 2))
        node.ExpansionValue = (node.MassCount * 7) + (node.ExpansionCount * 5) + math.max(0, (distEnemy - distHome) * 0.03)
            - (localThreat * 5.2) - (expansionRisk * 3.4) - (routeRisk * 2.8) - (allyMex * 6)
        node.RaidValue = (enemyMex * 10) + (node.MassCount * 2.5) - (enemyLand * 4.2) - (firebaseDanger * 3.8) - (routeRisk * 2.9)
        node.ScoutValue = ((1 - freshness) * 32) + (enemyMex * 2.5) + ((class == 'contested') and 10 or 0) + ((class == 'enemy_side') and 12 or 0)
            - (routeRisk * 1.4) - (localThreat * 1.6) - (radarCoverage * 1.2)
        if class == 'enemy_side' then
            node.RaidValue = node.RaidValue + 8
        elseif class == 'rear' or class == 'core' then
            node.RaidValue = node.RaidValue - 18
        end
    end

    graph.HomePrev = homePrev
    graph.EnemyPrev = enemyPrev
    graph.HomeDist = homeDist
    graph.EnemyDist = enemyDist
end

local function AssignGraphSelections(aiBrain, runtime, graph)
    local nodes = graph.Nodes or {}
    local byKey = graph.ByKey or {}

    local bestExpansion = FindNodeByBest(nodes, 'ExpansionValue', function(node)
        return node.Medium == 'land' and node.Key ~= 'home' and node.Classification ~= 'enemy_side'
    end)
    local bestRaid = FindNodeByBest(nodes, 'RaidValue', function(node)
        return node.Medium == 'land' and node.Key ~= 'home' and node.Key ~= 'enemy_main'
    end)
    local frontNode = FindNodeByBest(nodes, 'RallyValue', function(node)
        return node.Medium == 'land' and (node.Classification == 'front' or node.Classification == 'contested')
    end)
    if not frontNode then
        frontNode = byKey.enemy_main
    end
    local scoutNode = FindNodeByBest(nodes, 'ScoutValue', function(node)
        return node.Medium == 'land' and node.Key ~= 'home'
    end)
    scoutNode = scoutNode or bestRaid or frontNode or bestExpansion

    graph.BestExpansionNodeKey = bestExpansion and bestExpansion.Key or false
    graph.BestRaidNodeKey = bestRaid and bestRaid.Key or false
    graph.FrontNodeKey = frontNode and frontNode.Key or false
    graph.BestScoutNodeKey = scoutNode and scoutNode.Key or false

    graph.BestExpansionPos = bestExpansion and bestExpansion.Pos or false
    graph.BestRaidPos = bestRaid and bestRaid.Pos or false
    graph.FrontLinePos = frontNode and frontNode.Pos or graph.OwnMainPos
    graph.BestScoutPos = scoutNode and scoutNode.Pos or graph.FrontLinePos

    graph.PathToExpansionKeys = ReconstructPath(graph.HomePrev or {}, graph.ByKey or {}, 'home', graph.BestExpansionNodeKey)
    graph.PathToRaidKeys = ReconstructPath(graph.HomePrev or {}, graph.ByKey or {}, 'home', graph.BestRaidNodeKey)
    graph.PathToFrontKeys = ReconstructPath(graph.HomePrev or {}, graph.ByKey or {}, 'home', graph.FrontNodeKey)
    graph.PathToScoutKeys = ReconstructPath(graph.HomePrev or {}, graph.ByKey or {}, 'home', graph.BestScoutNodeKey)
    graph.PathToEnemyKeys = ReconstructPath(graph.HomePrev or {}, graph.ByKey or {}, 'home', 'enemy_main')

    local function KeysToPositions(keys)
        local positions = {}
        for _, key in keys or {} do
            local node = byKey[key]
            if node and node.Pos then
                table.insert(positions, node.Pos)
            end
        end
        return positions
    end

    graph.PathToExpansion = KeysToPositions(graph.PathToExpansionKeys)
    graph.PathToRaid = KeysToPositions(graph.PathToRaidKeys)
    graph.PathToFront = KeysToPositions(graph.PathToFrontKeys)
    graph.PathToScout = KeysToPositions(graph.PathToScoutKeys)
    graph.PathToEnemy = KeysToPositions(graph.PathToEnemyKeys)
end

function Update(aiBrain, now)
    local runtime = aiBrain.OvermindRuntime or {}
    aiBrain.OvermindRuntime = runtime
    runtime.ZoneGraph = runtime.ZoneGraph or {
        Nodes = {},
        ByKey = {},
        LastLogTime = -999,
    }
    local graph = runtime.ZoneGraph
    graph.OwnMainPos = GetMainPos(aiBrain, runtime)
    graph.EnemyMainPos = GetNearestEnemyBasePosition(aiBrain, graph.OwnMainPos, runtime)

    local navReady = EnsureNavGeneration(runtime, now, graph.OwnMainPos)
    local fallbackReady = now >= 10
    local shouldBuild = false
    if not graph.StaticBuilt then
        shouldBuild = navReady or fallbackReady
    elseif (now - (graph.StaticBuildTime or -999)) >= 180 then
        shouldBuild = true
    elseif navReady and not graph.NavGraphBuilt and (now - (graph.StaticBuildTime or -999)) >= 8 then
        shouldBuild = true
    end

    if shouldBuild then
        local useHeuristic = not navReady
        local nodes, byKey, ownPos, enemyPos = BuildNodes(aiBrain, runtime, useHeuristic)
        graph.Nodes = nodes
        graph.ByKey = byKey
        graph.OwnMainPos = ownPos
        graph.EnemyMainPos = enemyPos
        BuildEdges(graph.Nodes)
        graph.StaticBuilt = true
        graph.StaticBuildTime = now
        graph.NavReady = navReady or graph.NavReady
        graph.NavGraphBuilt = navReady and true or false
        graph.GraphSource = navReady and 'nav' or 'heuristic'
    elseif not graph.StaticBuilt then
        return
    end

    EvaluateNodes(aiBrain, runtime, graph, now)
    AssignGraphSelections(aiBrain, runtime, graph)

    runtime.ZoneModel = runtime.ZoneModel or {}
    runtime.ZoneModel.OwnMainPos = graph.OwnMainPos
    runtime.ZoneModel.BestExpansionPos = graph.BestExpansionPos
    runtime.ZoneModel.BestRaidPos = graph.BestRaidPos
    runtime.ZoneModel.BestScoutPos = graph.BestScoutPos
    runtime.ZoneModel.FrontLinePos = graph.FrontLinePos
    runtime.ZoneModel.GraphVersion = 41
    runtime.ZoneModel.GraphSource = graph.GraphSource or (graph.NavGraphBuilt and 'nav' or 'heuristic')
    runtime.ZoneModel.Zones = graph.Nodes
    runtime.ZoneModel.BestExpansionScore = graph.BestExpansionNodeKey and ((graph.ByKey[graph.BestExpansionNodeKey] and graph.ByKey[graph.BestExpansionNodeKey].ExpansionValue) or 0) or -999999
    runtime.ZoneModel.BestRaidScore = graph.BestRaidNodeKey and ((graph.ByKey[graph.BestRaidNodeKey] and graph.ByKey[graph.BestRaidNodeKey].RaidValue) or 0) or -999999
    runtime.ZoneModel.HomeThreat = (graph.ByKey.home and graph.ByKey.home.Threat) or 0
    runtime.ZoneModel.ExpansionThreat = (graph.BestExpansionNodeKey and graph.ByKey[graph.BestExpansionNodeKey] and graph.ByKey[graph.BestExpansionNodeKey].Threat) or 0

    local friendlyZones = 0
    local contestedZones = 0
    local enemyZones = 0
    local waterZones = 0
    for _, node in graph.Nodes or {} do
        if node.Medium == 'water' then
            waterZones = waterZones + 1
        end
        if node.Classification == 'core' or node.Classification == 'rear' then
            friendlyZones = friendlyZones + 1
        elseif node.Classification == 'front' or node.Classification == 'contested' then
            contestedZones = contestedZones + 1
        elseif node.Classification == 'enemy_side' then
            enemyZones = enemyZones + 1
        end
    end
    graph.FriendlyZones = friendlyZones
    graph.ContestedZones = contestedZones
    graph.EnemyZones = enemyZones
    graph.WaterZones = waterZones
    graph.MapControl = Clamp((friendlyZones + (contestedZones * 0.35) - (enemyZones * 0.2)) / math.max(1, table.getn(graph.Nodes)), 0, 1.5)
    runtime.ZoneModel.MapControl = graph.MapControl
    runtime.ZoneModel.NavMarkerCount = waterZones
    runtime.ZoneModel.LastUpdate = now

    if graph.EnemyMainPos then
        runtime.PrimaryEnemyPos = graph.EnemyMainPos
        OvermindMemory.RecordEnemySighting(aiBrain, graph.EnemyMainPos, math.max(1, enemyZones + contestedZones))
    end

    if now - (graph.LastLogTime or -999) >= 30 then
        graph.LastLogTime = now
        LOG(string.format('*OVERMIND ZGRAPH A%d t=%.1f src=%s nodes=%d friendly=%d contested=%d enemy=%d water=%d nav=%d front=%s raid=%s expand=%s scout=%s',
            aiBrain:GetArmyIndex(),
            now,
            graph.GraphSource or 'unknown',
            table.getn(graph.Nodes or {}),
            friendlyZones,
            contestedZones,
            enemyZones,
            waterZones,
            graph.NavReady and 1 or 0,
            graph.FrontNodeKey or 'none',
            graph.BestRaidNodeKey or 'none',
            graph.BestExpansionNodeKey or 'none',
            graph.BestScoutNodeKey or 'none'))
    end
end
