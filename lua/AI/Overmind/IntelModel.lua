local AIUtils = import('/lua/ai/aiutilities.lua')
local OvermindMemory = import('/mods/OvermindAI/lua/AI/Overmind/Memory.lua')

local LandCombatCategory = categories.MOBILE * categories.LAND - categories.ENGINEER - categories.SCOUT - categories.COMMAND
local LandAACategory = LandCombatCategory * categories.ANTIAIR
local AirCombatCategory = categories.MOBILE * categories.AIR - categories.SCOUT - categories.TRANSPORTATION - categories.COMMAND
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

local function LerpPos(a, b, t)
    if not a then
        return b
    end
    if not b then
        return a
    end

    local clamped = Clamp(t or 0.5, 0, 1)
    return {
        (a[1] or 0) + (((b[1] or 0) - (a[1] or 0)) * clamped),
        0,
        (a[3] or 0) + (((b[3] or 0) - (a[3] or 0)) * clamped),
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

local function AddCandidate(candidates, key, role, pos, baseScore)
    if not pos then
        return
    end

    for _, existing in candidates do
        if existing and existing.Pos and Distance2D(existing.Pos, pos) <= 40 then
            if (baseScore or 0) > (existing.BaseScore or -999999) then
                existing.Key = key
                existing.Role = role
                existing.Pos = pos
                existing.BaseScore = baseScore or 0
            end
            return
        end
    end

    table.insert(candidates, {
        Key = key,
        Role = role,
        Pos = pos,
        BaseScore = baseScore or 0,
    })
end

local function MarkerKey(marker, prefix, index)
    if marker and marker.Name then
        return prefix .. '_' .. string.gsub(string.lower(marker.Name), '[^%w_]+', '_')
    end
    return prefix .. '_' .. tostring(index or 0)
end

local function ScoreExpansionMarker(aiBrain, ownPos, enemyPos, marker)
    local pos = marker.Position
    local threat = aiBrain:GetThreatAtPosition(pos, 1, true, 'AntiSurface') or 0
    local enemyLand = aiBrain:GetNumUnitsAroundPoint(LandCombatCategory, pos, 50, 'Enemy') or 0
    local enemyMex = aiBrain:GetNumUnitsAroundPoint(MexCategory, pos, 30, 'Enemy') or 0
    local allyMex = aiBrain:GetNumUnitsAroundPoint(MexCategory, pos, 30, 'Ally') or 0
    local risk = OvermindMemory.GetExpansionRisk(aiBrain, pos, 80) or 0
    local routeRisk = OvermindMemory.GetRouteRisk(aiBrain, ownPos, pos, 5, 64) or 0
    local distHome = Distance2D(ownPos, pos)
    local distEnemy = enemyPos and Distance2D(enemyPos, pos) or (distHome + 180)

    local score = 8
    score = score + math.max(0, (distEnemy - distHome) / 85)
    score = score + math.max(0, enemyMex * 0.9)
    score = score - (allyMex * 2.3)
    score = score - (enemyLand * 0.75)
    score = score - (threat * 0.85)
    score = score - (risk * 0.9)
    score = score - (routeRisk * 0.55)
    if distHome > 640 then
        score = score - ((distHome - 640) / 110)
    end
    return score
end

local function ScoreRaidMarker(aiBrain, ownPos, enemyPos, marker)
    local pos = marker.Position
    local threat = aiBrain:GetThreatAtPosition(pos, 1, true, 'AntiSurface') or 0
    local airThreat = aiBrain:GetThreatAtPosition(pos, 1, true, 'Air') or 0
    local enemyMex = aiBrain:GetNumUnitsAroundPoint(MexCategory, pos, 28, 'Enemy') or 0
    local allyLand = aiBrain:GetNumUnitsAroundPoint(LandCombatCategory, pos, 36, 'Ally') or 0
    local enemyLand = aiBrain:GetNumUnitsAroundPoint(LandCombatCategory, pos, 36, 'Enemy') or 0
    local risk = OvermindMemory.GetExpansionRisk(aiBrain, pos, 72) or 0
    local routeRisk = OvermindMemory.GetRouteRisk(aiBrain, ownPos, pos, 4, 60) or 0
    local distHome = Distance2D(ownPos, pos)
    local distEnemy = enemyPos and Distance2D(enemyPos, pos) or math.max(1, distHome * 0.5)

    local score = enemyMex * 5.2
    score = score + math.max(0, (distEnemy < distHome) and 3 or 0)
    score = score - (allyLand * 0.8)
    score = score - (enemyLand * 1.15)
    score = score - (threat * 0.95)
    score = score - (airThreat * 0.4)
    score = score - (risk * 0.75)
    score = score - (routeRisk * 0.65)
    score = score - (distHome / 260)
    return score
end

local function SortDescending(items)
    table.sort(items, function(a, b)
        return (a.Score or 0) > (b.Score or 0)
    end)
end

local function BuildZoneCandidates(aiBrain, runtime, ownPos, enemyPos)
    local candidates = {}
    AddCandidate(candidates, 'home', 'home', ownPos, 999)
    if enemyPos then
        AddCandidate(candidates, 'enemy_main', 'enemy_main', enemyPos, 200)
        AddCandidate(candidates, 'midline', 'frontline', LerpPos(ownPos, enemyPos, 0.5), 120)
        AddCandidate(candidates, 'safe_midline', 'staging', LerpPos(ownPos, enemyPos, 0.36), 100)
    end

    local expansionMarkers = AIUtils.AIGetMarkerLocations(aiBrain, 'Expansion Area') or {}
    local bestExpansion = {}
    for index, marker in expansionMarkers do
        if marker and marker.Position then
            table.insert(bestExpansion, {
                Key = MarkerKey(marker, 'expand', index),
                Pos = marker.Position,
                Score = ScoreExpansionMarker(aiBrain, ownPos, enemyPos, marker),
            })
        end
    end
    SortDescending(bestExpansion)
    local maxExpansion = math.min(4, table.getn(bestExpansion))
    for i = 1, maxExpansion do
        AddCandidate(candidates, bestExpansion[i].Key, 'expansion', bestExpansion[i].Pos, bestExpansion[i].Score)
    end

    local raidMarkers = AIUtils.AIGetMarkerLocations(aiBrain, 'Mass') or {}
    local bestRaid = {}
    for index, marker in raidMarkers do
        if marker and marker.Position then
            local score = ScoreRaidMarker(aiBrain, ownPos, enemyPos, marker)
            if score > 0.6 then
                table.insert(bestRaid, {
                    Key = MarkerKey(marker, 'raid', index),
                    Pos = marker.Position,
                    Score = score,
                })
            end
        end
    end
    SortDescending(bestRaid)
    local maxRaid = math.min(4, table.getn(bestRaid))
    for i = 1, maxRaid do
        AddCandidate(candidates, bestRaid[i].Key, 'raid', bestRaid[i].Pos, bestRaid[i].Score)
    end

    if runtime.ZoneModel then
        if runtime.ZoneModel.BestExpansionPos then
            AddCandidate(candidates, 'legacy_expand', 'expansion', runtime.ZoneModel.BestExpansionPos, runtime.ZoneModel.BestExpansionScore or 0)
        end
        if runtime.ZoneModel.BestRaidPos then
            AddCandidate(candidates, 'legacy_raid', 'raid', runtime.ZoneModel.BestRaidPos, runtime.ZoneModel.BestRaidScore or 0)
        end
    end

    return candidates
end

local function EvaluateZone(aiBrain, runtime, candidate, ownPos, enemyPos, now)
    local key = candidate.Key or 'unknown'
    local role = candidate.Role or 'zone'
    local pos = candidate.Pos
    local ownDist = Distance2D(ownPos, pos)
    local enemyDist = enemyPos and Distance2D(enemyPos, pos) or (ownDist + 200)
    local landThreat = aiBrain:GetThreatAtPosition(pos, 2, true, 'AntiSurface') or 0
    local airThreat = aiBrain:GetThreatAtPosition(pos, 2, true, 'Air') or 0
    local friendlyLand = aiBrain:GetNumUnitsAroundPoint(LandCombatCategory, pos, 56, 'Ally') or 0
    local enemyLand = aiBrain:GetNumUnitsAroundPoint(LandCombatCategory, pos, 56, 'Enemy') or 0
    local friendlyAA = aiBrain:GetNumUnitsAroundPoint(LandAACategory, pos, 56, 'Ally') or 0
    local enemyAir = aiBrain:GetNumUnitsAroundPoint(AirCombatCategory, pos, 72, 'Enemy') or 0
    local allyMex = aiBrain:GetNumUnitsAroundPoint(MexCategory, pos, 32, 'Ally') or 0
    local enemyMex = aiBrain:GetNumUnitsAroundPoint(MexCategory, pos, 32, 'Enemy') or 0
    local allyRadar = aiBrain:GetNumUnitsAroundPoint(RadarCategory, pos, 72, 'Ally') or 0
    local expansionRisk = OvermindMemory.GetExpansionRisk(aiBrain, pos, 82) or 0
    local routeRisk = OvermindMemory.GetRouteRisk(aiBrain, ownPos, pos, 5, 62) or 0
    local lastVisit = (((runtime.ReconState or {}).LastVisit or {})[key]) or -1000
    local intelAge = now - lastVisit
    local freshnessWindow = 140
    if role == 'enemy_main' then
        freshnessWindow = 100
    elseif role == 'frontline' or role == 'raid' then
        freshnessWindow = 120
    end
    local freshness = Clamp(1 - (intelAge / freshnessWindow), 0, 1)

    local class = 'friendly'
    if role == 'home' or ownDist <= 68 then
        class = 'rear'
    elseif enemyLand > (friendlyLand + 1) or enemyDist < (ownDist - 40) then
        class = 'enemy_side'
    elseif math.abs(ownDist - enemyDist) <= 100 or landThreat >= 2.5 or routeRisk >= 4 then
        class = 'front'
    end
    if enemyLand > 0 and friendlyLand > 0 and math.abs(friendlyLand - enemyLand) <= 4 then
        class = 'contested'
    end

    local controlScore = friendlyLand + (allyMex * 1.4) + (allyRadar * 0.6) - (enemyLand * 1.15) - (enemyMex * 0.7) - (landThreat * 1.4)
    local scoutPriority = (1 - freshness) * 110
    local expandPriority = 0
    local raidPriority = 0

    if class == 'front' or class == 'contested' then
        scoutPriority = scoutPriority + 28
    end
    if role == 'enemy_main' then
        scoutPriority = scoutPriority + 24
    elseif role == 'raid' then
        scoutPriority = scoutPriority + 16
    elseif role == 'expansion' then
        scoutPriority = scoutPriority + 10
    end
    scoutPriority = scoutPriority + math.max(0, enemyLand * 2.5) + math.max(0, enemyMex * 3.2) - (allyRadar * 8)

    if role == 'expansion' then
        expandPriority = expandPriority + 32
    end
    if class == 'friendly' or class == 'front' or class == 'contested' then
        expandPriority = expandPriority + math.max(0, (enemyDist - ownDist) / 12)
    end
    expandPriority = expandPriority + (enemyMex * 3.5) - (allyMex * 6)
    expandPriority = expandPriority - (landThreat * 7) - (expansionRisk * 4.5) - (routeRisk * 2.8)

    if role == 'raid' or role == 'enemy_main' then
        raidPriority = raidPriority + 18
    end
    raidPriority = raidPriority + (enemyMex * 9) - (enemyLand * 4.5) - (landThreat * 4.8) - (airThreat * 1.6) - (routeRisk * 3.2)
    if class == 'enemy_side' then
        raidPriority = raidPriority + 8
    elseif class == 'rear' then
        raidPriority = raidPriority - 20
    end

    return {
        Key = key,
        Role = role,
        Pos = pos,
        BaseScore = candidate.BaseScore or 0,
        Classification = class,
        OwnDistance = ownDist,
        EnemyDistance = enemyDist,
        Threat = landThreat,
        AirThreat = airThreat,
        FriendlyLand = friendlyLand,
        FriendlyAA = friendlyAA,
        EnemyLand = enemyLand,
        EnemyAir = enemyAir,
        AllyMex = allyMex,
        EnemyMex = enemyMex,
        RadarCoverage = allyRadar,
        ExpansionRisk = expansionRisk,
        RouteRisk = routeRisk,
        Freshness = freshness,
        LastVisit = lastVisit,
        ControlScore = controlScore,
        ScoutPriority = scoutPriority,
        ExpandPriority = expandPriority,
        RaidPriority = raidPriority,
    }
end

local function PickZoneByScore(zones, fieldName, predicate)
    local best = false
    local bestScore = -999999
    for _, zone in zones do
        if zone and ((not predicate) or predicate(zone)) then
            local score = zone[fieldName] or -999999
            if score > bestScore then
                best = zone
                bestScore = score
            end
        end
    end
    return best
end

function Update(aiBrain, now)
    local runtime = aiBrain.OvermindRuntime or {}
    aiBrain.OvermindRuntime = runtime
    runtime.IntelModel = runtime.IntelModel or {
        Zones = {},
        LastLogTime = -999,
    }

    if runtime.ZoneGraph and runtime.ZoneGraph.StaticBuilt and table.getn(runtime.ZoneGraph.Nodes or {}) > 0 then
        local graph = runtime.ZoneGraph
        local intel = runtime.IntelModel
        local zones = {}
        local friendlyZones = 0
        local enemyZones = 0
        local contestedZones = 0
        local staleZones = 0
        local airThreatZones = 0

        for _, node in graph.Nodes do
            table.insert(zones, node)
            if node.Classification == 'core' or node.Classification == 'rear' then
                friendlyZones = friendlyZones + 1
            elseif node.Classification == 'enemy_side' then
                enemyZones = enemyZones + 1
            elseif node.Classification == 'front' or node.Classification == 'contested' then
                contestedZones = contestedZones + 1
            end
            if (node.Freshness or 0) <= 0.35 then
                staleZones = staleZones + 1
            end
            if (node.AirThreat or 0) > 1.5 or (node.EnemyAir or 0) > 0 then
                airThreatZones = airThreatZones + 1
            end
        end

        intel.OwnMainPos = graph.OwnMainPos
        intel.EnemyMainPos = graph.EnemyMainPos
        intel.Zones = zones
        intel.LastUpdate = now
        intel.BestScoutZoneKey = graph.BestScoutNodeKey or false
        intel.BestScoutPos = graph.BestScoutPos or false
        intel.BestRaidZoneKey = graph.BestRaidNodeKey or false
        intel.BestRaidPos = graph.BestRaidPos or false
        intel.BestExpansionZoneKey = graph.BestExpansionNodeKey or false
        intel.BestExpansionPos = graph.BestExpansionPos or false
        intel.FrontZoneKey = graph.FrontNodeKey or false
        intel.FrontLinePos = graph.FrontLinePos or graph.OwnMainPos
        intel.RearGuardPos = graph.OwnMainPos
        intel.FriendlyZones = friendlyZones
        intel.EnemyZones = enemyZones
        intel.ContestedZones = contestedZones
        intel.StaleZones = staleZones
        intel.AirThreatZones = airThreatZones
        intel.MapControl = graph.MapControl or 0
        runtime.ZoneModel = runtime.ZoneModel or {}
        runtime.ZoneModel.IntelVersion = 41
        runtime.ZoneModel.IntelSource = 'graph'

        if now - (intel.LastLogTime or -999) >= 30 then
            intel.LastLogTime = now
            LOG(string.format('*OVERMIND INTEL A%d t=%.1f graph=1 zones=%d friendly=%d contested=%d stale=%d air=%d scout=%s raid=%s expand=%s',
                aiBrain:GetArmyIndex(),
                now,
                table.getn(zones),
                friendlyZones,
                contestedZones,
                staleZones,
                airThreatZones,
                intel.BestScoutZoneKey or 'none',
                intel.BestRaidZoneKey or 'none',
                intel.BestExpansionZoneKey or 'none'))
        end
        return
    end

    local ownPos = GetMainPos(aiBrain, runtime)
    local enemyPos = GetNearestEnemyBasePosition(aiBrain, ownPos, runtime)
    local candidates = BuildZoneCandidates(aiBrain, runtime, ownPos, enemyPos)
    local zones = {}

    for _, candidate in candidates do
        table.insert(zones, EvaluateZone(aiBrain, runtime, candidate, ownPos, enemyPos, now))
    end

    local intel = runtime.IntelModel
    intel.OwnMainPos = ownPos
    intel.EnemyMainPos = enemyPos
    intel.Zones = zones
    intel.LastUpdate = now

    local bestScout = PickZoneByScore(zones, 'ScoutPriority')
    local bestRaid = PickZoneByScore(zones, 'RaidPriority', function(zone)
        return zone.Classification ~= 'rear'
    end)
    local bestExpand = PickZoneByScore(zones, 'ExpandPriority', function(zone)
        return zone.Classification ~= 'enemy_side'
    end)
    local frontZone = PickZoneByScore(zones, 'ControlScore', function(zone)
        return zone.Classification == 'front' or zone.Classification == 'contested' or zone.Role == 'frontline'
    end)
    local rearZone = PickZoneByScore(zones, 'ControlScore', function(zone)
        return zone.Classification == 'rear' or zone.Role == 'home'
    end)

    intel.BestScoutZoneKey = bestScout and bestScout.Key or false
    intel.BestScoutPos = bestScout and bestScout.Pos or false
    intel.BestRaidZoneKey = bestRaid and bestRaid.Key or false
    intel.BestRaidPos = bestRaid and bestRaid.Pos or false
    intel.BestExpansionZoneKey = bestExpand and bestExpand.Key or false
    intel.BestExpansionPos = bestExpand and bestExpand.Pos or false
    intel.FrontZoneKey = frontZone and frontZone.Key or false
    intel.FrontLinePos = frontZone and frontZone.Pos or (enemyPos and LerpPos(ownPos, enemyPos, 0.45) or ownPos)
    intel.RearGuardPos = rearZone and rearZone.Pos or ownPos

    local friendlyZones = 0
    local enemyZones = 0
    local contestedZones = 0
    local staleZones = 0
    local airThreatZones = 0
    for _, zone in zones do
        if zone.Classification == 'rear' or zone.Classification == 'friendly' then
            friendlyZones = friendlyZones + 1
        elseif zone.Classification == 'enemy_side' then
            enemyZones = enemyZones + 1
        elseif zone.Classification == 'front' or zone.Classification == 'contested' then
            contestedZones = contestedZones + 1
        end
        if (zone.Freshness or 0) <= 0.35 then
            staleZones = staleZones + 1
        end
        if (zone.EnemyAir or 0) > 0 or (zone.AirThreat or 0) > 1.5 then
            airThreatZones = airThreatZones + 1
        end
    end

    intel.FriendlyZones = friendlyZones
    intel.EnemyZones = enemyZones
    intel.ContestedZones = contestedZones
    intel.StaleZones = staleZones
    intel.AirThreatZones = airThreatZones
    intel.MapControl = Clamp((friendlyZones + (contestedZones * 0.35) - (enemyZones * 0.2)) / math.max(1, table.getn(zones)), 0, 1.5)

    runtime.ZoneModel = runtime.ZoneModel or {}
    runtime.ZoneModel.Zones = zones
    runtime.ZoneModel.IntelVersion = 41
    runtime.ZoneModel.IntelSource = 'legacy'
    runtime.ZoneModel.FrontLinePos = intel.FrontLinePos
    runtime.ZoneModel.RearGuardPos = intel.RearGuardPos
    runtime.ZoneModel.BestScoutPos = intel.BestScoutPos
    runtime.ZoneModel.BestRaidPos = intel.BestRaidPos or runtime.ZoneModel.BestRaidPos
    runtime.ZoneModel.BestExpansionPos = intel.BestExpansionPos or runtime.ZoneModel.BestExpansionPos
    runtime.ZoneModel.MapControl = Clamp(((runtime.ZoneModel.MapControl or intel.MapControl) + intel.MapControl) * 0.5, 0, 1.5)

    if enemyPos then
        runtime.PrimaryEnemyPos = enemyPos
        OvermindMemory.RecordEnemySighting(aiBrain, enemyPos, math.max(1, enemyZones + contestedZones))
    end

    if now - (intel.LastLogTime or -999) >= 30 then
        intel.LastLogTime = now
        LOG(string.format('*OVERMIND INTEL A%d t=%.1f zones=%d friendly=%d contested=%d stale=%d air=%d scout=%s raid=%s expand=%s',
            aiBrain:GetArmyIndex(),
            now,
            table.getn(zones),
            friendlyZones,
            contestedZones,
            staleZones,
            airThreatZones,
            intel.BestScoutZoneKey or 'none',
            intel.BestRaidZoneKey or 'none',
            intel.BestExpansionZoneKey or 'none'))
    end
end
