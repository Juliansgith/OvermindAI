local Module = {
    Name = 'EnemyClusterTracker',
    StateSlice = 'EnemyClusterTracker',
}

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

local function TableCount(t)
    return t and table.getn(t) or 0
end

local function GetRecentMemoryThreat(aiBrain, pos, radius, now)
    local memory = aiBrain and aiBrain.OvermindMemory or false
    local hotspots = memory and memory.RiskHotspots or false
    if not hotspots or not pos then
        return 0, 0
    end

    local total = 0
    local hits = 0
    local maxAge = 90
    for _, hotspot in hotspots do
        if hotspot and hotspot.Pos and ((hotspot.Reason == 'enemy') or (hotspot.Reason == 'threat')) then
            local age = now - (hotspot.Time or 0)
            if age <= maxAge then
                local dist = Distance2D(hotspot.Pos, pos)
                if dist <= radius then
                    local freshness = Clamp(1 - (age / maxAge), 0, 1)
                    local distFactor = Clamp(1 - (dist / radius), 0, 1)
                    total = total + ((hotspot.Score or 0) * (0.45 + (freshness * 0.55)) * (0.4 + (distFactor * 0.6)))
                    hits = hits + 1
                end
            end
        end
    end

    return total, hits
end

local function BuildNodeEvidence(aiBrain, node, now)
    local confirmedLand = node.EnemyLand or 0
    local confirmedAir = node.EnemyAir or 0
    local confirmedThreat = (confirmedLand * 1.0) + (confirmedAir * 0.85)
    local memoryThreat, memoryHits = GetRecentMemoryThreat(aiBrain, node.Pos, 96, now)
    local hasMemoryEvidence = memoryThreat >= 1.15 and memoryHits >= 2

    local operationalThreat = 0
    if confirmedThreat > 0 or hasMemoryEvidence then
        operationalThreat = confirmedThreat
            + (memoryThreat * 0.66)
            + (math.min(4.0, node.Threat or 0) * 0.10)
            + (math.min(3.0, node.FirebaseDanger or node.StructureThreat or 0) * 0.10)
    end

    local contactConfidence = 0
    if operationalThreat > 0 then
        local memoryWeight = math.min(1, memoryHits / 3)
        contactConfidence = Clamp(((confirmedThreat * 0.95) + (memoryThreat * (0.38 + (0.18 * memoryWeight)))) / math.max(1, operationalThreat), 0, 1)
    end

    return {
        ConfirmedLand = confirmedLand,
        ConfirmedAir = confirmedAir,
        ConfirmedThreat = confirmedThreat,
        MemoryThreat = memoryThreat,
        MemoryHits = memoryHits,
        OperationalThreat = operationalThreat,
        ContactConfidence = contactConfidence,
    }
end

local function IsHotNode(aiBrain, node, now)
    if not node then
        return false, false
    end

    local evidence = BuildNodeEvidence(aiBrain, node, now)
    local hot = evidence.ConfirmedThreat >= 0.9
        or (evidence.MemoryThreat >= 2.25 and evidence.MemoryHits >= 3 and evidence.OperationalThreat >= 3.1 and evidence.ContactConfidence >= 0.42)

    return hot, evidence
end

local function MergeClassification(current, nextClass)
    if nextClass == 'rear' or nextClass == 'core' then
        return 'rear'
    end
    if current == 'rear' then
        return current
    end
    if nextClass == 'contested' then
        return 'contested'
    end
    if current == 'contested' then
        return current
    end
    if nextClass == 'front' then
        return 'front'
    end
    if current == 'front' then
        return current
    end
    return nextClass or current or 'enemy_side'
end

local function FindPreviousCluster(previous, center)
    if not previous or not center then
        return false
    end

    local best = false
    local bestDist = 999999
    for _, cluster in previous do
        if cluster and cluster.Pos then
            local dist = Distance2D(cluster.Pos, center)
            if dist < 120 and dist < bestDist then
                best = cluster
                bestDist = dist
            end
        end
    end
    return best
end

local function BuildStagePos(ownPos, clusterPos, homeDistance)
    if not ownPos or not clusterPos then
        return clusterPos or ownPos
    end
    local t = 0.68
    if (homeDistance or 999) < 170 then
        t = 0.56
    elseif (homeDistance or 999) > 260 then
        t = 0.76
    end
    return {
        (ownPos[1] or 0) + (((clusterPos[1] or 0) - (ownPos[1] or 0)) * t),
        0,
        (ownPos[3] or 0) + (((clusterPos[3] or 0) - (ownPos[3] or 0)) * t),
    }
end

local function BuildClusters(aiBrain, runtime, now)
    local graph = runtime.ZoneGraph or {}
    local nodes = graph.Nodes or {}
    local byKey = graph.ByKey or {}
    local ownPos = graph.OwnMainPos or runtime.OwnMainPos
    local enemyPos = graph.EnemyMainPos or runtime.PrimaryEnemyPos
    local previous = ((runtime.EnemyClusterTracker or {}).Clusters) or {}
    local visited = {}
    local clusters = {}

    for _, seed in nodes do
        local seedHot = false
        local seedEvidence = false
        if seed and seed.Key and not visited[seed.Key] then
            seedHot, seedEvidence = IsHotNode(aiBrain, seed, now)
        end
        if seed and seed.Key and not visited[seed.Key] and seedHot then
            local queue = { seed }
            local head = 1
            local members = {}
            local evidenceByKey = {
                [seed.Key] = seedEvidence,
            }
            visited[seed.Key] = true

            while queue[head] do
                local node = queue[head]
                head = head + 1
                table.insert(members, node)

                for _, edge in node.Edges or {} do
                    local other = edge and byKey[edge.Key] or false
                    local otherHot = false
                    local otherEvidence = false
                    if other and other.Key and not visited[other.Key] then
                        otherHot, otherEvidence = IsHotNode(aiBrain, other, now)
                    end
                    if other and other.Key and not visited[other.Key] and otherHot then
                        if Distance2D(node.Pos, other.Pos) <= 215 then
                            visited[other.Key] = true
                            evidenceByKey[other.Key] = otherEvidence
                            table.insert(queue, other)
                        end
                    end
                end
            end

            local sx = 0
            local sz = 0
            local totalWeight = 0
            local totalThreat = 0
            local totalLand = 0
            local totalAir = 0
            local totalConfirmedThreat = 0
            local totalMemoryThreat = 0
            local totalMemoryHits = 0
            local confirmedNodes = 0
            local evidenceNodes = 0
            local class = 'enemy_side'
            local nearestHome = 999999
            local nearestEnemy = 999999

            for _, node in members do
                local evidence = evidenceByKey[node.Key] or BuildNodeEvidence(aiBrain, node, now)
                local weight = math.max(1, evidence.OperationalThreat)
                sx = sx + ((node.Pos[1] or 0) * weight)
                sz = sz + ((node.Pos[3] or 0) * weight)
                totalWeight = totalWeight + weight
                totalThreat = totalThreat + evidence.OperationalThreat
                totalLand = totalLand + evidence.ConfirmedLand
                totalAir = totalAir + evidence.ConfirmedAir
                totalConfirmedThreat = totalConfirmedThreat + evidence.ConfirmedThreat
                totalMemoryThreat = totalMemoryThreat + evidence.MemoryThreat
                totalMemoryHits = totalMemoryHits + (evidence.MemoryHits or 0)
                if evidence.ConfirmedThreat > 0 then
                    confirmedNodes = confirmedNodes + 1
                end
                if evidence.OperationalThreat > 0 then
                    evidenceNodes = evidenceNodes + 1
                end
                class = MergeClassification(class, node.Classification)
                nearestHome = math.min(nearestHome, node.GraphDistHome or (ownPos and Distance2D(ownPos, node.Pos) or 999999))
                nearestEnemy = math.min(nearestEnemy, node.GraphDistEnemy or (enemyPos and Distance2D(enemyPos, node.Pos) or 999999))
            end

            local center = {
                sx / math.max(1, totalWeight),
                0,
                sz / math.max(1, totalWeight),
            }
            local prev = FindPreviousCluster(previous, center)
            local closing = prev and ((prev.HomeDistance or nearestHome) - nearestHome) or 0
            local stagePos = BuildStagePos(ownPos, center, nearestHome)
            local approachPressure = Clamp((totalThreat / math.max(5, totalWeight * 0.9)) * ((nearestHome < 180) and 1.1 or ((nearestHome < 280) and 0.85 or 0.55)), 0, 1.5)
            local confirmedUnits = totalLand + totalAir
            local contactConfidence = Clamp(((totalConfirmedThreat * 0.88) + (totalMemoryThreat * 0.62)) / math.max(1, totalThreat), 0, 1)
            local approaching = closing >= 10
                or (nearestHome < 210 and totalThreat >= 5 and contactConfidence >= 0.42)
                or ((class == 'front' or class == 'contested' or class == 'rear') and totalThreat >= 6 and (confirmedUnits > 0 or totalMemoryThreat >= 1.2))

            table.insert(clusters, {
                Key = string.format('cluster_%d', table.getn(clusters) + 1),
                Nodes = members,
                Pos = center,
                StagePos = stagePos,
                Classification = class,
                TotalThreat = totalThreat,
                ConfirmedThreat = totalConfirmedThreat,
                MemoryThreat = totalMemoryThreat,
                MemoryHits = totalMemoryHits,
                ConfirmedUnits = confirmedUnits,
                ConfirmedNodes = confirmedNodes,
                EvidenceNodes = evidenceNodes,
                EnemyLand = totalLand,
                EnemyAir = totalAir,
                HomeDistance = nearestHome,
                EnemyDistance = nearestEnemy,
                Closing = closing,
                Approaching = approaching and true or false,
                ApproachPressure = approachPressure,
                ContactConfidence = contactConfidence,
                UpdatedAt = now,
            })
        end
    end

    table.sort(clusters, function(a, b)
        return (a.TotalThreat or 0) > (b.TotalThreat or 0)
    end)

    return clusters
end

local function PickApproachCluster(clusters)
    local best = false
    local bestScore = -999999
    for _, cluster in clusters do
        if cluster
            and cluster.Classification ~= 'enemy_side'
            and (
                ((cluster.ConfirmedUnits or 0) > 0 and (cluster.ContactConfidence or 0) >= 0.28)
                or ((cluster.MemoryThreat or 0) >= 3.2 and (cluster.MemoryHits or 0) >= 4 and (cluster.HomeDistance or 999) < 150 and (cluster.ContactConfidence or 0) >= 0.42)
            ) then
            local score = (cluster.TotalThreat or 0) * 1.1
                + ((cluster.Approaching and 1) or 0) * 4
                + (((cluster.HomeDistance or 999) < 180) and 4 or 0)
                + (((cluster.Classification == 'rear') and 1) or 0) * 5
                + (((cluster.Classification == 'contested') and 1) or 0) * 2
                + ((cluster.ContactConfidence or 0) * 3.5)
                - ((cluster.HomeDistance or 999) * 0.018)
            if score > bestScore then
                best = cluster
                bestScore = score
            end
        end
    end
    return best
end

function Module.Update(aiBrain, now)
    local runtime = aiBrain.OvermindRuntime or {}
    aiBrain.OvermindRuntime = runtime
    runtime.EnemyClusterTracker = runtime.EnemyClusterTracker or {
        Clusters = {},
        LastLogTime = -999,
    }

    local state = runtime.EnemyClusterTracker
    local graph = runtime.ZoneGraph or {}
    if not graph.StaticBuilt or TableCount(graph.Nodes or {}) <= 0 then
        state.Clusters = {}
        state.ApproachCluster = false
        state.LargestCluster = false
        return
    end

    local clusters = BuildClusters(aiBrain, runtime, now)
    state.Clusters = clusters
    state.ClusterCount = table.getn(clusters)
    state.LargestCluster = clusters[1] or false
    state.ApproachCluster = PickApproachCluster(clusters)
    state.LastUpdate = now

    if state.LargestCluster
        and (
            ((state.LargestCluster.ConfirmedUnits or 0) > 0)
            or (((state.LargestCluster.MemoryThreat or 0) >= 2.1) and ((state.LargestCluster.MemoryHits or 0) >= 3))
        ) then
        runtime.LastEnemyContactTime = now
    end

    if now - (state.LastLogTime or -999) >= 20 then
        state.LastLogTime = now
        local approach = state.ApproachCluster or {}
        LOG(string.format('*OVERMIND CLUSTER A%d t=%.1f count=%d largest=%.1f/%d/%d conf=%.2f approach=%d:%.1f:%.0f:%s:%.2f:%d',
            aiBrain:GetArmyIndex(),
            now,
            state.ClusterCount or 0,
            (state.LargestCluster and state.LargestCluster.TotalThreat) or 0,
            (state.LargestCluster and state.LargestCluster.EnemyLand) or 0,
            (state.LargestCluster and state.LargestCluster.EnemyAir) or 0,
            (state.LargestCluster and state.LargestCluster.ContactConfidence) or 0,
            state.ApproachCluster and 1 or 0,
            (approach.TotalThreat or 0),
            (approach.HomeDistance or 999),
            (approach.Classification or 'none'),
            (approach.ContactConfidence or 0),
            (approach.ConfirmedUnits or 0)))
    end
end

function Update(aiBrain, now)
    return Module.Update(aiBrain, now)
end

return Module
