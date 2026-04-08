local RadarCategory = categories.STRUCTURE * categories.RADAR * categories.TECH1
local BuilderCategory = categories.ENGINEER * categories.MOBILE + categories.COMMAND
local Module = {}

local function Mod(a, b)
    return math.mod(a, b)
end

local RadarOffsets = {
    { 20, 0 },
    { -20, 0 },
    { 0, 20 },
    { 0, -20 },
    { 34, 16 },
    { -34, 16 },
    { 16, -34 },
    { -16, -34 },
}

local function Distance2D(a, b)
    local dx = (a[1] or 0) - (b[1] or 0)
    local dz = (a[3] or 0) - (b[3] or 0)
    return math.sqrt((dx * dx) + (dz * dz))
end

local function GetEntityId(unit)
    if not unit or unit.Dead then
        return false
    end
    if unit.GetEntityId then
        local ok, id = pcall(function()
            return unit:GetEntityId()
        end)
        if ok and id then
            return tostring(id)
        end
    end
    return tostring(unit)
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

local function GetRadarAnchors(runtime, mainPos)
    local anchors = { mainPos }
    local zone = runtime and runtime.ZoneModel or {}
    local graph = runtime and runtime.ZoneGraph or {}
    local expansionPos = zone.BestExpansionPos
    local raidPos = zone.BestRaidPos
    local frontPath = graph.PathToFront or {}
    local frontAnchor = (table.getn(frontPath) >= 2 and frontPath[2]) or graph.FrontLinePos

    if expansionPos and Distance2D(expansionPos, mainPos) >= 26 then
        table.insert(anchors, expansionPos)
    end
    if frontAnchor and Distance2D(frontAnchor, mainPos) >= 28 then
        local nearExisting = false
        for _, pos in anchors do
            if Distance2D(pos, frontAnchor) < 24 then
                nearExisting = true
                break
            end
        end
        if not nearExisting then
            table.insert(anchors, frontAnchor)
        end
    end
    if raidPos and Distance2D(raidPos, mainPos) >= 34 then
        local nearExisting = false
        for _, pos in anchors do
            if Distance2D(pos, raidPos) < 22 then
                nearExisting = true
                break
            end
        end
        if not nearExisting then
            table.insert(anchors, raidPos)
        end
    end

    return anchors
end

local function IsIdleBuilder(unit)
    if not unit or unit.Dead then
        return false
    end
    if unit:IsUnitState('Building') or unit:IsUnitState('Upgrading') then
        return false
    end
    local q = unit.GetCommandQueue and unit:GetCommandQueue() or false
    return (not q) or table.getn(q) == 0
end

local function FindBuilderById(aiBrain, builderId, bp)
    if not aiBrain or not builderId then
        return false
    end
    local builders = aiBrain:GetListOfUnits(BuilderCategory, false, true)
    if not builders then
        return false
    end
    for _, unit in builders do
        if unit and not unit.Dead and GetEntityId(unit) == builderId and (not bp or unit:CanBuild(bp)) then
            return unit
        end
    end
    return false
end

local function PickRadarBlueprint(builder)
    if not builder then
        return false
    end

    local radarBps = EntityCategoryGetUnitList(RadarCategory)
    if not radarBps or table.getn(radarBps) <= 0 then
        return false
    end

    for _, bp in radarBps do
        if bp and builder:CanBuild(bp) then
            return bp
        end
    end

    return false
end

local function PickBuilder(aiBrain, runtime, mainPos, bp, forceBusy)
    local acuList = aiBrain:GetListOfUnits(categories.COMMAND, false, true)
    if acuList then
        for _, acu in acuList do
            if acu and not acu.Dead and IsIdleBuilder(acu) and acu:CanBuild(bp) then
                local pos = acu:GetPosition()
                if pos then
                    local dx = (pos[1] or 0) - (mainPos[1] or 0)
                    local dz = (pos[3] or 0) - (mainPos[3] or 0)
                    local dist = math.sqrt((dx * dx) + (dz * dz))
                    if dist <= 120 then
                        return acu
                    end
                end
            end
        end
    end

    local builders = aiBrain:GetListOfUnits(BuilderCategory, false, true)
    if not builders then
        return false
    end

    local best = false
    local bestDist = 999999
    for _, eng in builders do
        local usable = false
        if eng and not eng.Dead and eng:CanBuild(bp) then
            if forceBusy then
                usable = not eng:IsUnitState('Building') and not eng:IsUnitState('Upgrading')
            else
                usable = IsIdleBuilder(eng)
            end
        end
        if usable then
            local pos = eng:GetPosition()
            if pos then
                local dx = (pos[1] or 0) - (mainPos[1] or 0)
                local dz = (pos[3] or 0) - (mainPos[3] or 0)
                local dist = math.sqrt((dx * dx) + (dz * dz))
                if dist < bestDist and dist <= 140 then
                    bestDist = dist
                    best = eng
                end
            end
        end
    end

    return best
end

local function FindUnfinishedRadar(aiBrain)
    local radars = aiBrain:GetListOfUnits(RadarCategory, false, true)
    if not radars then
        return false
    end
    local best = false
    local bestFraction = 1
    for _, radar in radars do
        if radar and not radar.Dead and radar.GetFractionComplete then
            local fraction = radar:GetFractionComplete() or 1
            if fraction < 0.995 and fraction < bestFraction then
                bestFraction = fraction
                best = radar
            end
        end
    end
    return best
end

local function PickBuilderNearTarget(aiBrain, targetPos, bp)
    if not targetPos then
        return false, false
    end
    local builders = aiBrain:GetListOfUnits(BuilderCategory, false, true)
    if not builders then
        return false, false
    end

    local bestIdle = false
    local bestIdleDist = 999999
    local bestBusy = false
    local bestBusyDist = 999999
    for _, unit in builders do
        if unit and not unit.Dead and unit:CanBuild(bp) then
            local pos = unit:GetPosition()
            if pos then
                local dist = Distance2D(pos, targetPos)
                if dist <= 170 then
                    local q = unit.GetCommandQueue and unit:GetCommandQueue() or false
                    local qLen = q and table.getn(q) or 0
                    local busy = qLen > 0 or unit:IsUnitState('Building') or unit:IsUnitState('Upgrading')
                    if not busy and dist < bestIdleDist then
                        bestIdle = unit
                        bestIdleDist = dist
                    elseif qLen <= 1 and dist < bestBusyDist then
                        bestBusy = unit
                        bestBusyDist = dist
                    end
                end
            end
        end
    end

    if bestIdle then
        return bestIdle, false
    end
    if bestBusy then
        return bestBusy, true
    end
    return false, false
end

local function ClearDirectOrder(state)
    state.DirectBuilderId = false
    state.DirectTargetPos = false
    state.DirectBlueprint = false
    state.DirectIssuedAt = -999
    state.DirectRetryAt = -999
    state.DirectExpiresAt = -999
    state.DirectForced = false
end

local function SetDirectOrder(state, builder, targetPos, bp, now, radarCritical, forced)
    state.DirectBuilderId = GetEntityId(builder)
    state.DirectTargetPos = { targetPos[1], targetPos[2] or 0, targetPos[3] }
    state.DirectBlueprint = bp
    state.DirectIssuedAt = now
    state.DirectRetryAt = now + (radarCritical and 4 or 6)
    state.DirectExpiresAt = now + (radarCritical and 36 or 24)
    state.DirectForced = forced and true or false
end

local function HasDirectOrder(state, now)
    return state
        and state.DirectBuilderId
        and state.DirectTargetPos
        and ((state.DirectExpiresAt or -999) > now)
end

local function StrengthenBuilderLocks(runtime, builder, now, radarCritical)
    runtime.RadarBuildLockUntil = math.max(runtime.RadarBuildLockUntil or -999, now + (radarCritical and 75 or 48))
    runtime.RadarBuildClaimUntil = math.max(runtime.RadarBuildClaimUntil or -999, now + (radarCritical and 18 or 10))
    if builder and EntityCategoryContains(categories.COMMAND, builder) then
        runtime.ACUSafetyLockUntil = math.max(runtime.ACUSafetyLockUntil or -999, now + 10)
        runtime.ACUHardBuildLockUntil = math.max(runtime.ACUHardBuildLockUntil or -999, now + (radarCritical and 18 or 12))
    end
end

local function IssueDirectRadarBuild(runtime, state, aiBrain, builder, targetPos, bp, now, radarCritical, forced)
    if not builder or builder.Dead or not targetPos or not bp or not IssueBuildMobile then
        return false
    end
    if forced and IssueClearCommands then
        IssueClearCommands({ builder })
        state.LastForceTime = now
    end
    IssueBuildMobile({ builder }, targetPos, bp, {})
    SetDirectOrder(state, builder, targetPos, bp, now, radarCritical, forced)
    StrengthenBuilderLocks(runtime, builder, now, radarCritical)
    state.NextTry = radarCritical and (now + 3) or (now + 6)
    return true
end

local function BuildLocation(anchorPos, slot, ring)
    local off = RadarOffsets[slot]
    local scale = 1 + (ring * 0.38)
    return {
        (anchorPos[1] or 0) + (off[1] * scale),
        0,
        (anchorPos[3] or 0) + (off[2] * scale),
    }
end

local function FindBuildableRadarPos(aiBrain, anchorPos, bp, maxRings)
    if not aiBrain or not anchorPos or not bp then
        return false
    end
    local rings = maxRings or 3
    for ring = 0, rings do
        for slot = 1, table.getn(RadarOffsets) do
            local pos = BuildLocation(anchorPos, slot, ring)
            if aiBrain.CanBuildStructureAt and aiBrain:CanBuildStructureAt(bp, pos) then
                return pos
            end
        end
    end
    return false
end

local function RequiredRadarByTime(now)
    if now >= 900 then
        return 3
    end
    if now >= 560 then
        return 2
    end
    if now >= 240 then
        return 1
    end
    return 0
end

local function MaintainDirectOrder(aiBrain, runtime, state, now, desired, requiredByNow, radarCount, radarCritical)
    if not HasDirectOrder(state, now) then
        return false
    end

    local unfinished = FindUnfinishedRadar(aiBrain)
    if unfinished or radarCount > 0 then
        ClearDirectOrder(state)
        return false
    end

    if now < (state.DirectRetryAt or -999) then
        state.NextTry = math.max(now + 2, state.DirectRetryAt or (now + 2))
        return true
    end

    local bp = state.DirectBlueprint
    local builder = FindBuilderById(aiBrain, state.DirectBuilderId, bp)
    local forced = false
    if not builder then
        builder, forced = PickBuilderNearTarget(aiBrain, state.DirectTargetPos, bp)
    else
        forced = not IsIdleBuilder(builder)
    end
    if not builder then
        state.NextTry = now + 3
        return true
    end

    if IssueDirectRadarBuild(runtime, state, aiBrain, builder, state.DirectTargetPos, bp, now, radarCritical, forced) then
        if now - (state.LastLogTime or -999) >= 10 then
            state.LastLogTime = now
            LOG(string.format('*OVERMIND RADARFB A%d t=%.1f built=%d/%d need=%d anchor=%d slot=%d forced=%d',
                aiBrain:GetArmyIndex(),
                now,
                radarCount,
                desired,
                requiredByNow,
                -1,
                -1,
                forced and 1 or 0))
        end
        return true
    end

    state.NextTry = now + 3
    return true
end

function Module.Update(aiBrain, now)
    local runtime = aiBrain.OvermindRuntime or {}
    aiBrain.OvermindRuntime = runtime

    local state = runtime.RadarFallback or {
        NextTry = -999,
        NextSlot = 1,
        NextAnchor = 1,
        LastLogTime = -999,
        LastForceTime = -999,
        DirectBuilderId = false,
        DirectTargetPos = false,
        DirectBlueprint = false,
        DirectIssuedAt = -999,
        DirectRetryAt = -999,
        DirectExpiresAt = -999,
        DirectForced = false,
    }
    runtime.RadarFallback = state

    if now < (state.NextTry or -999) then
        return
    end
    if (runtime.RadarBuildLockUntil or -999) > now then
        state.NextTry = math.max(now + 3, math.min(runtime.RadarBuildLockUntil, now + 9))
        return
    end

    local desired = 1
    local prod = runtime.ProductionDirector or {}
    local structurePlan = prod.StructurePlan or {}
    local current = prod.Current or {}
    if structurePlan.Radar then
        desired = structurePlan.Radar
    elseif now > 560 then
        desired = 2
    end
    local powerReady = (((current.Eco or {}).Power or {}).Ready) or 0
    local radarCritical = structurePlan.RadarCritical == true
        or (((structurePlan.Radar or 0) > 0) and powerReady > 0 and (aiBrain:GetCurrentUnits(RadarCategory) or 0) <= 0)

    local radarCount = aiBrain:GetCurrentUnits(RadarCategory) or 0
    local requiredByNow = RequiredRadarByTime(now)
    if radarCount >= desired and radarCount >= requiredByNow then
        ClearDirectOrder(state)
        state.NextTry = now + 10
        return
    end

    local eco = runtime.EcoState or {}
    local raid = runtime.RaidDefense or {}
    local emergencyVisionNeed = raid.UnderAirHarass or raid.UnderLandHarass or (runtime.LastEnemyContactTime and (now - runtime.LastEnemyContactTime) <= 50)
    if not radarCritical and not emergencyVisionNeed and (eco.EnergyStorageRatio or 0) < 0.08 and (eco.EnergyTrend or 0) < 2 and now < 560 then
        state.NextTry = now + 8
        return
    end

    if (eco.EnergyStorageRatio or 0) <= 0.001 and (eco.EnergyTrend or 0) <= -34 then
        state.NextTry = now + 8
        return
    end

    local mainPos = GetMainPos(aiBrain, runtime)
    local probeBp = PickRadarBlueprint((aiBrain:GetListOfUnits(BuilderCategory, false, true) or { })[1])
    if not probeBp then
        local builders = aiBrain:GetListOfUnits(BuilderCategory, false, true)
        if not builders or table.getn(builders) <= 0 then
            state.NextTry = now + 8
            return
        end
        for _, b in builders do
            if b and not b.Dead then
                probeBp = PickRadarBlueprint(b)
                if probeBp then
                    break
                end
            end
        end
    end

    if not probeBp then
        state.NextTry = now + 10
        return
    end

    if MaintainDirectOrder(aiBrain, runtime, state, now, desired, requiredByNow, radarCount, radarCritical) then
        return
    end

    if radarCount <= 0 then
        local homeTarget = FindBuildableRadarPos(aiBrain, mainPos, probeBp, 4)
            or { (mainPos[1] or 0) + 12, 0, (mainPos[3] or 0) + 6 }
        local nearbyHomeRadar = aiBrain:GetNumUnitsAroundPoint(RadarCategory, homeTarget, 20, 'Ally') or 0
        if nearbyHomeRadar <= 0 then
            local firstBuilder = PickBuilder(aiBrain, runtime, mainPos, probeBp, false)
            local firstForced = false
            if not firstBuilder and (radarCritical or now >= 180) then
                firstBuilder = PickBuilder(aiBrain, runtime, mainPos, probeBp, true)
                firstForced = firstBuilder and true or false
            end
            if firstBuilder and IssueDirectRadarBuild(runtime, state, aiBrain, firstBuilder, homeTarget, probeBp, now, radarCritical, firstForced) then
                if now - (state.LastLogTime or -999) >= 12 then
                    state.LastLogTime = now
                    LOG(string.format('*OVERMIND RADARFB A%d t=%.1f built=%d/%d need=%d anchor=%d slot=%d forced=%d',
                        aiBrain:GetArmyIndex(),
                        now,
                        radarCount,
                        desired,
                        requiredByNow,
                        1,
                        0,
                        firstForced and 1 or 0))
                end
                return
            end
        end
    end

    local unfinished = FindUnfinishedRadar(aiBrain)
    if unfinished then
        ClearDirectOrder(state)
        local engState = runtime.EngineerState or {}
        local structureTask = engState.UnfinishedStructureTask or {}
        if structureTask.Active and string.lower(structureTask.Kind or 'none') == 'radar' then
            state.NextTry = now + 6
            return
        end
        local unfinishedPos = unfinished.GetPosition and unfinished:GetPosition() or false
        if unfinishedPos then
            local assistBuilder, assistBusy = PickBuilderNearTarget(aiBrain, unfinishedPos, probeBp)
            if assistBuilder then
                if assistBusy and IssueClearCommands then
                    IssueClearCommands({ assistBuilder })
                end
                if IssueRepair then
                    IssueRepair({ assistBuilder }, unfinished)
                elseif IssueGuard then
                    IssueGuard({ assistBuilder }, unfinished)
                end
                StrengthenBuilderLocks(runtime, assistBuilder, now, true)
                state.NextTry = now + 8
                if now - (state.LastLogTime or -999) >= 12 then
                    state.LastLogTime = now
                    LOG(string.format('*OVERMIND RADARFB A%d t=%.1f built=%d/%d need=%d anchor=%d slot=%d forced=%d',
                        aiBrain:GetArmyIndex(),
                        now,
                        radarCount,
                        desired,
                        requiredByNow,
                        0,
                        0,
                        assistBusy and 1 or 0))
                end
                return
            end
        end
    end

    local deadlineMissed = radarCount < requiredByNow
    local forceBusy = radarCritical
        or (radarCount <= 0 and now >= 180 and (now - (state.LastForceTime or -999)) >= 45)
        or (deadlineMissed and (now - (state.LastForceTime or -999)) >= 12)
    local builder = PickBuilder(aiBrain, runtime, mainPos, probeBp, false)
    if not builder and forceBusy then
        builder = PickBuilder(aiBrain, runtime, mainPos, probeBp, true)
    end
    if not builder then
        state.NextTry = radarCritical and (now + 2) or (deadlineMissed and (now + 3) or (now + 6))
        return
    end

    local offsetCount = table.getn(RadarOffsets)
    if offsetCount <= 0 then
        return
    end

    local anchors = GetRadarAnchors(runtime, mainPos)
    local anchorCount = table.getn(anchors)
    if anchorCount <= 0 then
        anchors = { mainPos }
        anchorCount = 1
    elseif radarCount <= 0 then
        anchors = { mainPos }
        anchorCount = 1
    end

    local startSlot = state.NextSlot or (Mod((aiBrain:GetArmyIndex() * 3), offsetCount) + 1)
    local startAnchor = state.NextAnchor or 1

    for anchorOffset = 0, anchorCount - 1 do
        local anchorSlot = Mod((startAnchor - 1 + anchorOffset), anchorCount) + 1
        local anchorPos = anchors[anchorSlot]
        local ring = math.floor((radarCount + anchorOffset) / offsetCount)
        for i = 0, offsetCount - 1 do
            local slot = Mod((startSlot - 1 + i), offsetCount) + 1
            local target = BuildLocation(anchorPos, slot, ring)
            local nearbyRadar = aiBrain:GetNumUnitsAroundPoint(RadarCategory, target, 16, 'Ally') or 0
            if nearbyRadar <= 0 then
                if IssueDirectRadarBuild(runtime, state, aiBrain, builder, target, probeBp, now, radarCritical, forceBusy) then
                    state.NextSlot = Mod(slot, offsetCount) + 1
                    state.NextAnchor = Mod(anchorSlot, anchorCount) + 1

                    if now - (state.LastLogTime or -999) >= 12 then
                        state.LastLogTime = now
                        LOG(string.format('*OVERMIND RADARFB A%d t=%.1f built=%d/%d need=%d anchor=%d slot=%d forced=%d',
                            aiBrain:GetArmyIndex(),
                            now,
                            radarCount,
                            desired,
                            requiredByNow,
                            anchorSlot,
                            slot,
                            forceBusy and 1 or 0))
                    end
                    return
                end
            end
        end
    end

    state.NextTry = deadlineMissed and (now + 4) or (now + 9)
end

-- FAF import exposes globals from the file environment.
-- Keep a global Update symbol for scheduler compatibility.
function Update(aiBrain, now)
    return Module.Update(aiBrain, now)
end
RadarFallbackUpdate = Module.Update

return Module
