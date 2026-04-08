local OvermindAutoTune = import('/mods/OvermindAI/lua/AI/Overmind/AutoTune.lua')

local function LerpPos(a, b, t)
    if not a then
        return b
    end
    if not b then
        return a
    end

    local clamped = math.max(0, math.min(1, t or 0.5))
    return {
        (a[1] or 0) + (((b[1] or 0) - (a[1] or 0)) * clamped),
        0,
        (a[3] or 0) + (((b[3] or 0) - (a[3] or 0)) * clamped),
    }
end

local function Distance2D(a, b)
    local dx = (a[1] or 0) - (b[1] or 0)
    local dz = (a[3] or 0) - (b[3] or 0)
    return math.sqrt((dx * dx) + (dz * dz))
end

local function GetMainPos(aiBrain, runtime)
    if aiBrain.BuilderManagers and aiBrain.BuilderManagers.MAIN and aiBrain.BuilderManagers.MAIN.Position then
        return aiBrain.BuilderManagers.MAIN.Position
    end
    if runtime and runtime.ZoneModel and runtime.ZoneModel.OwnMainPos then
        return runtime.ZoneModel.OwnMainPos
    end
    local sx, sz = aiBrain:GetArmyStartPos()
    return { sx, 0, sz }
end

local function IsIdle(unit)
    local q = unit.GetCommandQueue and unit:GetCommandQueue() or false
    return (not q) or table.getn(q) == 0
end

local function EnsureReconState(runtime)
    runtime.ReconState = runtime.ReconState or {}
    local recon = runtime.ReconState
    recon.LastVisit = recon.LastVisit or {}
    recon.LastIntent = recon.LastIntent or {}
    recon.PendingScoutTargets = recon.PendingScoutTargets or {}
    recon.PendingByKey = recon.PendingByKey or {}
    return recon
end

local function UpsertTarget(targets, target)
    if not target or not target.Pos then
        return
    end

    local key = target.Key or 'unknown'
    local existing = targets[key]
    if not existing or (target.Bias or 0) > (existing.Bias or 0) then
        targets[key] = target
    end
end

local function GetScoutId(scout)
    if not scout then
        return false
    end
    if scout.GetEntityId then
        return tostring(scout:GetEntityId())
    end
    return tostring(scout)
end

local function GetScoutVisionRadius(scout)
    if not scout or not scout.GetBlueprint then
        return 24
    end
    local bp = scout:GetBlueprint() or {}
    local intel = bp.Intel or {}
    local vision = intel.VisionRadius or intel.OmniRadius or 24
    return math.max(16, vision)
end

local function AdjustPendingCount(recon, keys, delta)
    if not recon or not keys then
        return
    end
    for _, key in keys do
        if key then
            local nextValue = (recon.PendingByKey[key] or 0) + delta
            if nextValue > 0 then
                recon.PendingByKey[key] = nextValue
            else
                recon.PendingByKey[key] = nil
            end
        end
    end
end

local function ClearPendingScout(recon, scoutId)
    if not recon or not scoutId then
        return
    end
    local pending = recon.PendingScoutTargets[scoutId]
    if pending then
        AdjustPendingCount(recon, pending.Keys or {}, -1)
        recon.PendingScoutTargets[scoutId] = nil
    end
end

local function MarkScoutConfirmed(recon, pending, now)
    if not recon or not pending then
        return
    end
    for _, key in pending.Keys or {} do
        if key then
            recon.LastVisit[key] = now
        end
    end
end

local function UpdateScoutConfirmations(runtime, now)
    local recon = EnsureReconState(runtime)
    for scoutId, pending in recon.PendingScoutTargets do
        local scout = pending and pending.Scout or false
        if not scout or scout.Dead then
            ClearPendingScout(recon, scoutId)
        else
            local pos = scout.GetPosition and scout:GetPosition() or false
            local confirmPos = pending.Pos
            local confirmRadius = pending.ConfirmRadius or 24
            local age = now - (pending.OrderedAt or now)
            if pos and confirmPos and Distance2D(pos, confirmPos) <= confirmRadius then
                MarkScoutConfirmed(recon, pending, now)
                ClearPendingScout(recon, scoutId)
            elseif age >= 90 then
                ClearPendingScout(recon, scoutId)
            elseif age >= 8 and IsIdle(scout) and pos and confirmPos and Distance2D(pos, confirmPos) > (confirmRadius * 1.35) then
                ClearPendingScout(recon, scoutId)
            end
        end
    end
end

local function GetReconTargets(runtime, ownPos)
    local targetMap = {}
    local graph = runtime.ZoneGraph or {}
    local zone = runtime.ZoneModel or {}
    local intel = runtime.IntelModel or {}

    if graph.PathToScout and table.getn(graph.PathToScout) > 1 then
        local pathKeys = graph.PathToScoutKeys or {}
        for index, pos in graph.PathToScout do
            if index > 1 and pos then
                local node = graph.ByKey and graph.ByKey[pathKeys[index]] or false
                local nodeKey = node and node.Key or pathKeys[index] or string.format('graph_scout_%d', index)
                UpsertTarget(targetMap, {
                    Key = nodeKey,
                    Pos = pos,
                    Bias = 52 - (index * 5),
                    Role = node and node.Role or 'graph_scout',
                    Classification = node and node.Classification or 'unknown',
                    IsGraphTarget = true,
                    NodeKey = nodeKey,
                })
            end
        end
    end
    if graph.BestScoutPos then
        local scoutNode = graph.ByKey and graph.BestScoutNodeKey and graph.ByKey[graph.BestScoutNodeKey] or false
        UpsertTarget(targetMap, {
            Key = graph.BestScoutNodeKey or 'graph_best_scout',
            Pos = graph.BestScoutPos,
            Bias = 58,
            Role = scoutNode and scoutNode.Role or 'graph_scout',
            Classification = scoutNode and scoutNode.Classification or 'unknown',
            IsGraphTarget = true,
            NodeKey = graph.BestScoutNodeKey or false,
        })
    end

    if intel.Zones and table.getn(intel.Zones) > 0 then
        for _, item in intel.Zones do
            if item and item.Pos then
                UpsertTarget(targetMap, {
                    Key = item.Key or item.Role or 'zone',
                    Pos = item.Pos,
                    Bias = item.ScoutValue or item.ScoutPriority or 0,
                    Role = item.Role or 'zone',
                    Classification = item.Classification or 'unknown',
                    IsGraphTarget = item.Key and true or false,
                    NodeKey = item.Key or false,
                })
            end
        end
    end
    if runtime.PrimaryEnemyPos then
        UpsertTarget(targetMap, { Key = 'enemy_main', Pos = runtime.PrimaryEnemyPos, Bias = 44, Role = 'enemy_main', Classification = 'enemy_side' })
    end
    if zone.BestRaidPos then
        UpsertTarget(targetMap, { Key = 'raid_lane', Pos = zone.BestRaidPos, Bias = 28, Role = 'raid', Classification = 'front' })
    end
    if zone.BestExpansionPos then
        UpsertTarget(targetMap, { Key = 'expansion_lane', Pos = zone.BestExpansionPos, Bias = 24, Role = 'expansion', Classification = 'front' })
    end
    if runtime.PrimaryEnemyPos then
        UpsertTarget(targetMap, { Key = 'midline', Pos = LerpPos(ownPos, runtime.PrimaryEnemyPos, 0.55), Bias = 16, Role = 'transit', Classification = 'front' })
    end

    local targets = {}
    for _, target in targetMap do
        table.insert(targets, target)
    end

    table.sort(targets, function(a, b)
        return (a.Bias or 0) > (b.Bias or 0)
    end)
    return targets
end

local function PickTarget(runtime, targets, now, lostContact)
    local recon = EnsureReconState(runtime)
    local best = false
    local bestScore = -999999

    for _, target in targets do
        local key = target.Key or 'unknown'
        local last = recon.LastVisit[key] or -1000
        local lastIntent = recon.LastIntent[key] or -1000
        local pendingCount = recon.PendingByKey[key] or 0
        local staleness = now - last
        local score = staleness + (target.Bias or 0)
        score = score - (pendingCount * 90)
        if pendingCount > 0 then
            score = score - math.max(0, 40 - (now - lastIntent))
        end
        if lostContact and (key == 'enemy_main' or target.Role == 'enemy_main') then
            score = score + 160
        end
        if key == 'raid_lane' or target.Role == 'raid' then
            score = score + 30
        end
        if target.Classification == 'front' or target.Classification == 'contested' then
            score = score + 18
        elseif target.Classification == 'rear' then
            score = score - 12
        end
        if score > bestScore then
            best = target
            bestScore = score
        end
    end

    return best
end

local function OrderScout(scout, ownPos, target)
    if not scout or scout.Dead or not target then
        return false, false
    end

    local targetPos = target.Pos or target
    if not targetPos then
        return false, false
    end

    local confirmRadius = math.max(18, GetScoutVisionRadius(scout) * 0.85)
    local confirmPos = targetPos

    if EntityCategoryContains(categories.AIR * categories.SCOUT, scout) then
        if IssueMove then
            IssueMove({ scout }, LerpPos(ownPos, targetPos, 0.6))
            IssueMove({ scout }, targetPos)
            return true, {
                Pos = confirmPos,
                ConfirmRadius = confirmRadius,
            }
        end
    else
        local issuedPos = LerpPos(ownPos, targetPos, 0.42)
        if target.IsGraphTarget or target.NodeKey then
            issuedPos = targetPos
        else
            confirmPos = issuedPos
        end
        if IssueMove then
            IssueMove({ scout }, issuedPos)
            return true, {
                Pos = confirmPos,
                ConfirmRadius = confirmRadius,
            }
        end
        if IssueAggressiveMove then
            IssueAggressiveMove({ scout }, issuedPos)
            return true, {
                Pos = confirmPos,
                ConfirmRadius = confirmRadius,
            }
        end
    end

    return false, false
end

function Update(aiBrain, now)
    local runtime = aiBrain.OvermindRuntime
    if not runtime then
        return
    end
    local recon = EnsureReconState(runtime)
    UpdateScoutConfirmations(runtime, now)
    local tune = OvermindAutoTune.GetConfig(aiBrain)
    local recovery = runtime.Recovery or {}

    local interval = 14
    if now >= 500 then
        interval = 10
    end
    if recovery.ForceScoutRecovery then
        interval = 6
    end

    if now - (runtime.LastScoutDirectorTime or -999) < interval then
        return
    end
    runtime.LastScoutDirectorTime = now

    local ownPos = GetMainPos(aiBrain, runtime)
    local targets = GetReconTargets(runtime, ownPos)
    if table.getn(targets) == 0 then
        return
    end

    local scouts = aiBrain:GetListOfUnits(categories.SCOUT * categories.MOBILE * (categories.AIR + categories.LAND), false, true)
    if not scouts or table.getn(scouts) == 0 then
        return
    end

    local idleScouts = {}
    for _, scout in scouts do
        if scout and not scout.Dead and IsIdle(scout) then
            table.insert(idleScouts, scout)
        end
    end

    if table.getn(idleScouts) == 0 then
        return
    end

    local lastEnemyContact = runtime.LastEnemyContactTime or -1000
    local lostContact = (now - lastEnemyContact) > 170
    local minScout = tune.ScoutMinCount or 2
    local maxOrders = math.max(1, math.min(table.getn(idleScouts), minScout + 1))
    if recovery.ForceScoutRecovery then
        maxOrders = math.max(maxOrders, math.min(4, table.getn(idleScouts)))
    end

    local ordered = 0
    for _, scout in idleScouts do
        if ordered >= maxOrders then
            break
        end

        local pick = PickTarget(runtime, targets, now, lostContact)
        if pick and pick.Pos then
            local issued, pending = OrderScout(scout, ownPos, pick)
            if issued then
                local scoutId = GetScoutId(scout)
                ClearPendingScout(recon, scoutId)
                if pending then
                    pending.Keys = { pick.Key or 'unknown' }
                    pending.Scout = scout
                    pending.OrderedAt = now
                    recon.PendingScoutTargets[scoutId] = pending
                    AdjustPendingCount(recon, pending.Keys, 1)
                end
                recon.LastIntent[pick.Key or 'unknown'] = now
                runtime.LastScoutTargetKey = pick.Key
                runtime.LastScoutTarget = pick.Pos
                ordered = ordered + 1
            end
        end
    end

    runtime.LastScoutOrderCount = ordered
    if ordered > 0 and (now - (runtime.LastScoutDirectorLogTime or -999)) >= 30 then
        runtime.LastScoutDirectorLogTime = now
        LOG(string.format('*OVERMIND SCOUTDIR A%d t=%.1f ordered=%d target=%s lostContact=%d',
            aiBrain:GetArmyIndex(),
            now,
            ordered,
            runtime.LastScoutTargetKey or 'unknown',
            lostContact and 1 or 0))
    end
end
