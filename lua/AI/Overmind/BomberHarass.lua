local AIUtils = import('/lua/ai/aiutilities.lua')
local OvermindMemory = import('/mods/OvermindAI/lua/AI/Overmind/Memory.lua')
local Module = {}

local function Mod(a, b)
    return math.mod(a, b)
end

local BomberCategory = categories.MOBILE * categories.AIR * categories.BOMBER - categories.SCOUT - categories.TRANSPORTATION - categories.COMMAND
local FighterCategory = categories.MOBILE * categories.AIR * categories.ANTIAIR * categories.FIGHTER
local EnemyMexCategory = categories.STRUCTURE * categories.MASSEXTRACTION

local function Distance2D(a, b)
    local dx = (a[1] or 0) - (b[1] or 0)
    local dz = (a[3] or 0) - (b[3] or 0)
    return math.sqrt((dx * dx) + (dz * dz))
end

local function GetMainPos(aiBrain, runtime)
    if runtime and runtime.OwnMainPos then
        return runtime.OwnMainPos
    end
    if aiBrain.BuilderManagers and aiBrain.BuilderManagers.MAIN and aiBrain.BuilderManagers.MAIN.Position then
        return aiBrain.BuilderManagers.MAIN.Position
    end
    local sx, sz = aiBrain:GetArmyStartPos()
    return { sx, 0, sz }
end

local function GetIdleBombers(aiBrain, maxCount)
    local out = {}
    local list = aiBrain:GetListOfUnits(BomberCategory, false, true)
    if not list then
        return out
    end

    for _, bomber in list do
        if bomber and not bomber.Dead then
            local q = bomber.GetCommandQueue and bomber:GetCommandQueue() or false
            local qLen = q and table.getn(q) or 0
            if qLen <= 0 and not bomber:IsUnitState('Building') then
                table.insert(out, bomber)
                if table.getn(out) >= maxCount then
                    break
                end
            end
        end
    end

    return out
end

local function GetIdleFighters(aiBrain, maxCount)
    local out = {}
    local list = aiBrain:GetListOfUnits(FighterCategory, false, true)
    if not list then
        return out
    end

    for _, fighter in list do
        if fighter and not fighter.Dead then
            local q = fighter.GetCommandQueue and fighter:GetCommandQueue() or false
            local qLen = q and table.getn(q) or 0
            if qLen <= 0 and not fighter:IsUnitState('Building') then
                table.insert(out, fighter)
                if table.getn(out) >= maxCount then
                    break
                end
            end
        end
    end

    return out
end

local function ScoreTarget(aiBrain, runtime, pos, homePos, hotspots)
    local enemyMex = aiBrain:GetNumUnitsAroundPoint(EnemyMexCategory, pos, 22, 'Enemy') or 0
    if enemyMex <= 0 then
        return -99999
    end

    local staticThreat = aiBrain:GetThreatAtPosition(pos, 1, true, 'StructuresNotMex') or 0
    local airThreat = aiBrain:GetThreatAtPosition(pos, 1, true, 'Air') or 0
    local aaThreat = aiBrain:GetThreatAtPosition(pos, 1, true, 'AntiAir') or 0
    local risk = OvermindMemory.GetExpansionRisk(aiBrain, pos, 84) or 0

    local minSightDist = 340
    if hotspots then
        for _, hotspot in hotspots do
            if hotspot and hotspot.Pos then
                local d = Distance2D(pos, hotspot.Pos)
                if d < minSightDist then
                    minSightDist = d
                end
            end
        end
    end

    local sightBonus = math.min(3.5, minSightDist / 180)
    if minSightDist < 70 then
        sightBonus = sightBonus - 2
    end

    local homeDist = Distance2D(homePos, pos)
    local mobilityBonus = math.min(2.1, homeDist / 390)

    local score = (enemyMex * 9.8)
        - (staticThreat * 0.95)
        - (airThreat * 0.65)
        - (aaThreat * 1.95)
        - (risk * 1.35)
        + sightBonus
        + mobilityBonus

    if aaThreat <= 0.5 and staticThreat <= 0.75 then
        score = score + 3.5
    elseif aaThreat <= 1.5 and staticThreat <= 1.5 then
        score = score + 1.5
    end

    local raid = runtime and runtime.RaidDefense or {}
    if raid and raid.LastThreatMexPos and Distance2D(pos, raid.LastThreatMexPos) < 92 then
        score = score - 1.6
    end

    return score
end

local function ScoreClusterTarget(aiBrain, runtime, cluster, homePos)
    if not cluster or not cluster.Pos then
        return -99999
    end
    if (cluster.ConfirmedUnits or 0) <= 0 then
        return -99999
    end

    local pos = cluster.Pos
    local staticThreat = aiBrain:GetThreatAtPosition(pos, 1, true, 'StructuresNotMex') or 0
    local airThreat = aiBrain:GetThreatAtPosition(pos, 1, true, 'Air') or 0
    local aaThreat = aiBrain:GetThreatAtPosition(pos, 1, true, 'AntiAir') or 0
    local risk = OvermindMemory.GetExpansionRisk(aiBrain, pos, 72) or 0
    local homeDist = Distance2D(homePos, pos)

    local score = ((cluster.TotalThreat or 0) * 1.45)
        + ((cluster.ConfirmedUnits or 0) * 0.8)
        + (((cluster.HomeDistance or 999) < 190) and 1.8 or 0)
        - (aaThreat * 1.45)
        - (airThreat * 0.9)
        - (staticThreat * 0.35)
        - (risk * 0.9)
        + math.min(2.2, homeDist / 260)

    return score
end

local function BuildWaypoint(homePos, targetPos, variant)
    if not homePos or not targetPos then
        return targetPos
    end
    local t = 0.58
    local mid = {
        homePos[1] + ((targetPos[1] - homePos[1]) * t),
        0,
        homePos[3] + ((targetPos[3] - homePos[3]) * t),
    }
    local dx = (targetPos[1] or 0) - (homePos[1] or 0)
    local dz = (targetPos[3] or 0) - (homePos[3] or 0)
    local mag = math.sqrt((dx * dx) + (dz * dz))
    if mag < 0.001 then
        return mid
    end
    local nx = -dz / mag
    local nz = dx / mag
    local side = (Mod((variant or 1), 2) == 0) and -1 or 1
    local offset = 18
    return {
        (mid[1] or 0) + (nx * offset * side),
        0,
        (mid[3] or 0) + (nz * offset * side),
    }
end

local function ChooseTargets(aiBrain, runtime, desiredTargets)
    local homePos = GetMainPos(aiBrain, runtime)
    local massMarkers = AIUtils.AIGetMarkerLocations(aiBrain, 'Mass')
    if not massMarkers or table.getn(massMarkers) <= 0 then
        return {}
    end

    local memory = aiBrain.OvermindMemory or {}
    local hotspots = memory.RiskHotspots or {}
    local scored = {}
    local opp = runtime and runtime.OpponentModel or {}
    local clusterState = runtime and runtime.EnemyClusterTracker or {}
    local counterWindow = (opp.CounterAirWindow == true)
        or ((opp.T2Push == true or opp.IndirectHeavy == true) and (opp.LowAirThreat == true))

    if counterWindow then
        for _, cluster in { clusterState.ApproachCluster, clusterState.LargestCluster } do
            if cluster and cluster.Pos then
                local score = ScoreClusterTarget(aiBrain, runtime, cluster, homePos)
                if score > 2.2 then
                    table.insert(scored, { Pos = cluster.Pos, Score = score })
                end
            end
        end
    end

    for _, marker in massMarkers do
        local pos = marker and marker.Position
        if pos then
            local score = ScoreTarget(aiBrain, runtime, pos, homePos, hotspots)
            if score > 0.5 then
                table.insert(scored, { Pos = pos, Score = score })
            end
        end
    end

    table.sort(scored, function(a, b)
        return (a.Score or -999) > (b.Score or -999)
    end)

    local targets = {}
    for _, item in scored do
        local okay = true
        for _, chosen in targets do
            if Distance2D(item.Pos, chosen) < 52 then
                okay = false
                break
            end
        end
        if okay then
            table.insert(targets, item.Pos)
            if table.getn(targets) >= desiredTargets then
                break
            end
        end
    end

    if table.getn(targets) <= 0 and runtime and runtime.ZoneModel and runtime.ZoneModel.BestRaidPos then
        table.insert(targets, runtime.ZoneModel.BestRaidPos)
    end

    return targets
end

function Module.Update(aiBrain, now)
    local runtime = aiBrain.OvermindRuntime
    if not runtime then
        return
    end

    local state = runtime.BomberHarass or {
        NextTry = -999,
        LastLog = -999,
        LastVariant = 0,
    }
    runtime.BomberHarass = state

    if now < (state.NextTry or -999) then
        return
    end

    if now < 170 then
        state.NextTry = now + 8
        return
    end

    local raid = runtime.RaidDefense or {}
    if raid.UnderAirHarass and (raid.LastAirEnemyCount or 0) >= 2 then
        state.NextTry = now + 8
        return
    end

    local totalBombers = aiBrain:GetCurrentUnits(BomberCategory) or 0
    if totalBombers < 1 then
        state.NextTry = now + 8
        return
    end

    local idle = GetIdleBombers(aiBrain, 6)
    if table.getn(idle) <= 0 then
        state.NextTry = now + 6
        return
    end

    local idleFighters = GetIdleFighters(aiBrain, 8)

    local targets = ChooseTargets(aiBrain, runtime, 4)
    if table.getn(targets) <= 0 then
        state.NextTry = now + 8
        return
    end

    local assigned = 0
    local fighterCount = table.getn(idleFighters)
    local bomberGroupSize = (totalBombers >= 4) and 2 or 1
    local fighterGroupSize = (fighterCount >= 6 and bomberGroupSize >= 2) and 3 or ((fighterCount >= 2) and 2 or 0)
    local maxGroups = math.min(2, math.floor(table.getn(idle) / bomberGroupSize))
    if maxGroups <= 0 and table.getn(idle) > 0 then
        maxGroups = 1
        bomberGroupSize = 1
    end
    if fighterGroupSize > 0 then
        maxGroups = math.min(maxGroups, math.max(1, math.floor(fighterCount / fighterGroupSize)))
    end
    if maxGroups <= 0 then
        state.NextTry = now + 6
        return
    end

    local homePos = GetMainPos(aiBrain, runtime)
    local bomberIndex = 1
    local fighterIndex = 1
    for groupIndex = 1, maxGroups do
        local target = targets[Mod((groupIndex - 1), table.getn(targets)) + 1]
        if target then
            local targetAA = aiBrain:GetThreatAtPosition(target, 1, true, 'AntiAir') or 0
            if targetAA < 8 or fighterGroupSize >= 2 then
                local bombers = {}
                for _ = 1, bomberGroupSize do
                    local bomber = idle[bomberIndex]
                    if bomber then
                        table.insert(bombers, bomber)
                        bomberIndex = bomberIndex + 1
                    end
                end
                local escorts = {}
                for _ = 1, fighterGroupSize do
                    local fighter = idleFighters[fighterIndex]
                    if fighter then
                        table.insert(escorts, fighter)
                        fighterIndex = fighterIndex + 1
                    end
                end

                if table.getn(bombers) > 0 then
                    if table.getn(escorts) <= 0 and targetAA >= 3 then
                        state.NextTry = now + 5
                        return
                    end
                    if IssueClearCommands then
                        IssueClearCommands(bombers)
                        if table.getn(escorts) > 0 then
                            IssueClearCommands(escorts)
                        end
                    end
                    state.LastVariant = (state.LastVariant or 0) + 1
                    local waypoint = BuildWaypoint(homePos, target, state.LastVariant)
                    if waypoint and IssueMove then
                        IssueMove(bombers, waypoint)
                        if table.getn(escorts) > 0 then
                            IssueMove(escorts, waypoint)
                        end
                    end
                    if IssueAggressiveMove then
                        IssueAggressiveMove(bombers, target)
                        if table.getn(escorts) > 0 then
                            IssueAggressiveMove(escorts, target)
                        end
                    elseif IssueMove then
                        IssueMove(bombers, target)
                        if table.getn(escorts) > 0 then
                            IssueMove(escorts, target)
                        end
                    end
                    assigned = assigned + table.getn(bombers)
                end
            end
        end
    end

    if assigned > 0 and now - (state.LastLog or -999) >= 16 then
        state.LastLog = now
        LOG(string.format('*OVERMIND BOMBHARASS A%d t=%.1f assigned=%d groups=%d escorts=%d targets=%d',
            aiBrain:GetArmyIndex(),
            now,
            assigned,
            maxGroups,
            fighterGroupSize,
            table.getn(targets)))
    end

    state.NextTry = now + 6
end

-- FAF import exposes globals from the file environment.
-- Keep a global Update symbol for scheduler compatibility.
function Update(aiBrain, now)
    return Module.Update(aiBrain, now)
end
BomberHarassUpdate = Module.Update

return Module
