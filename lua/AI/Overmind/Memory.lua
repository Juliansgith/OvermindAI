local function Clamp(v, minV, maxV)
    if v < minV then
        return minV
    end

    if v > maxV then
        return maxV
    end

    return v
end

local function GetUnitMassValue(unit)
    if not unit or not unit.GetBlueprint then
        return 1
    end

    local bp = unit:GetBlueprint()
    if not bp or not bp.Economy then
        return 1
    end

    local mass = bp.Economy.BuildCostMass or 1
    return math.max(1, mass)
end

local function AddEngineerLossHotspot(memory, position, score, now)
    if not memory or not position then
        return
    end

    memory.EngineerLossHotspots = memory.EngineerLossHotspots or {}
    local merged = false
    local mergeDistSq = 40 * 40

    for _, hotspot in memory.EngineerLossHotspots do
        if hotspot and hotspot.Pos then
            local dx = (hotspot.Pos[1] or 0) - (position[1] or 0)
            local dz = (hotspot.Pos[3] or 0) - (position[3] or 0)
            if (dx * dx) + (dz * dz) <= mergeDistSq then
                hotspot.Score = math.min(24, (hotspot.Score or 0) + (score or 0.8))
                hotspot.Time = now
                merged = true
                break
            end
        end
    end

    if not merged then
        table.insert(memory.EngineerLossHotspots, {
            Pos = { position[1], 0, position[3] },
            Score = math.min(24, score or 0.8),
            Time = now,
        })
    end
end

local function AddRiskHotspot(memory, position, score, now, reason)
    if not memory or not position then
        return
    end

    memory.RiskHotspots = memory.RiskHotspots or {}
    local merged = false
    local mergeDistSq = 56 * 56

    for _, hotspot in memory.RiskHotspots do
        if hotspot and hotspot.Pos then
            local dx = (hotspot.Pos[1] or 0) - (position[1] or 0)
            local dz = (hotspot.Pos[3] or 0) - (position[3] or 0)
            if (dx * dx) + (dz * dz) <= mergeDistSq then
                hotspot.Score = math.min(28, (hotspot.Score or 0) + (score or 0.6))
                hotspot.Time = now
                if reason then
                    hotspot.Reason = reason
                end
                merged = true
                break
            end
        end
    end

    if not merged then
        table.insert(memory.RiskHotspots, {
            Pos = { position[1], 0, position[3] },
            Score = math.min(28, score or 0.6),
            Time = now,
            Reason = reason or 'risk',
        })
    end
end

local function AddRouteBlackspot(memory, position, score, now)
    if not memory or not position then
        return
    end

    memory.RouteBlackspots = memory.RouteBlackspots or {}
    local merged = false
    local mergeDistSq = 72 * 72

    for _, hotspot in memory.RouteBlackspots do
        if hotspot and hotspot.Pos then
            local dx = (hotspot.Pos[1] or 0) - (position[1] or 0)
            local dz = (hotspot.Pos[3] or 0) - (position[3] or 0)
            if (dx * dx) + (dz * dz) <= mergeDistSq then
                hotspot.Score = math.min(36, (hotspot.Score or 0) + (score or 1.4))
                hotspot.Time = now
                merged = true
                break
            end
        end
    end

    if not merged then
        table.insert(memory.RouteBlackspots, {
            Pos = { position[1], 0, position[3] },
            Score = math.min(36, score or 1.4),
            Time = now,
        })
    end
end

local function GetMainPos(aiBrain)
    if aiBrain and aiBrain.BuilderManagers and aiBrain.BuilderManagers.MAIN and aiBrain.BuilderManagers.MAIN.Position then
        return aiBrain.BuilderManagers.MAIN.Position
    end
    if aiBrain and aiBrain.OvermindRuntime and aiBrain.OvermindRuntime.ZoneModel and aiBrain.OvermindRuntime.ZoneModel.OwnMainPos then
        return aiBrain.OvermindRuntime.ZoneModel.OwnMainPos
    end
    if aiBrain and aiBrain.GetArmyStartPos then
        local sx, sz = aiBrain:GetArmyStartPos()
        return { sx, 0, sz }
    end
    return false
end

local function Distance2D(a, b)
    local dx = (a[1] or 0) - (b[1] or 0)
    local dz = (a[3] or 0) - (b[3] or 0)
    return math.sqrt((dx * dx) + (dz * dz))
end

local function EnsureMemory(aiBrain)
    aiBrain.OvermindMemory = aiBrain.OvermindMemory or {
        KillMassLifetime = 0,
        LossMassLifetime = 0,
        BuildMassLifetime = 0,
        ReclaimMassLifetime = 0,
        KillMassRecent = 0,
        LossMassRecent = 0,
        BuildMassRecent = 0,
        ReclaimMassRecent = 0,
        EngineerLossRecent = 0,
        EngineerBuiltRecent = 0,
        EngineerLossLifetime = 0,
        EngineerBuiltLifetime = 0,
        EngineerLossHotspots = {},
        RiskHotspots = {},
        RouteBlackspots = {},
        LastDecayTime = GetGameTimeSeconds(),
        LastCombatEventTime = -1000,
        LastEcoEventTime = -1000,
        LastEngineerLossTime = -1000,
    }

    return aiBrain.OvermindMemory
end

local function ApplyDecay(memory, now)
    local last = memory.LastDecayTime or now
    local delta = now - last
    if delta <= 0 then
        return
    end

    -- Half life of roughly 100s keeps the AI responsive to recent swings.
    local keepFactor = math.pow(0.5, delta / 100)
    memory.KillMassRecent = (memory.KillMassRecent or 0) * keepFactor
    memory.LossMassRecent = (memory.LossMassRecent or 0) * keepFactor
    memory.BuildMassRecent = (memory.BuildMassRecent or 0) * keepFactor
    memory.ReclaimMassRecent = (memory.ReclaimMassRecent or 0) * keepFactor
    memory.EngineerLossRecent = (memory.EngineerLossRecent or 0) * keepFactor
    memory.EngineerBuiltRecent = (memory.EngineerBuiltRecent or 0) * keepFactor

    if memory.EngineerLossHotspots then
        local newHotspots = {}
        for _, hotspot in memory.EngineerLossHotspots do
            local score = (hotspot.Score or 0) * keepFactor
            if score >= 0.2 and hotspot.Pos then
                hotspot.Score = score
                table.insert(newHotspots, hotspot)
            end
        end
        memory.EngineerLossHotspots = newHotspots
    end

    if memory.RiskHotspots then
        local newRisk = {}
        for _, hotspot in memory.RiskHotspots do
            local score = (hotspot.Score or 0) * keepFactor
            if score >= 0.25 and hotspot.Pos then
                hotspot.Score = score
                table.insert(newRisk, hotspot)
            end
        end
        memory.RiskHotspots = newRisk
    end

    if memory.RouteBlackspots then
        local newRoutes = {}
        for _, hotspot in memory.RouteBlackspots do
            local score = (hotspot.Score or 0) * keepFactor
            if score >= 0.35 and hotspot.Pos then
                hotspot.Score = score
                table.insert(newRoutes, hotspot)
            end
        end
        memory.RouteBlackspots = newRoutes
    end

    memory.LastDecayTime = now
end

function Init(aiBrain)
    EnsureMemory(aiBrain)
end

function RecordEnemySighting(aiBrain, position, strength)
    if not aiBrain or not aiBrain.OvermindAI or not position then
        return
    end

    local now = GetGameTimeSeconds()
    local memory = EnsureMemory(aiBrain)
    ApplyDecay(memory, now)
    local score = math.max(0.4, (strength or 1) * 0.45)
    AddRiskHotspot(memory, position, score, now, 'enemy')
    if aiBrain.OvermindRuntime then
        aiBrain.OvermindRuntime.LastEnemyContactTime = now
    end
end

function RecordThreatSpike(aiBrain, position, threatValue)
    if not aiBrain or not aiBrain.OvermindAI or not position then
        return
    end

    local now = GetGameTimeSeconds()
    local memory = EnsureMemory(aiBrain)
    ApplyDecay(memory, now)
    local score = math.max(0.5, (threatValue or 1) * 0.5)
    AddRiskHotspot(memory, position, score, now, 'threat')
end

function UpdateWindow(aiBrain, now)
    local memory = EnsureMemory(aiBrain)
    ApplyDecay(memory, now or GetGameTimeSeconds())
end

function RecordKill(aiBrain, killedUnit, killer)
    if not aiBrain or not aiBrain.OvermindAI or not killedUnit then
        return
    end

    local now = GetGameTimeSeconds()
    local memory = EnsureMemory(aiBrain)
    ApplyDecay(memory, now)

    local mass = GetUnitMassValue(killedUnit)
    memory.KillMassLifetime = (memory.KillMassLifetime or 0) + mass
    memory.KillMassRecent = (memory.KillMassRecent or 0) + mass
    memory.LastCombatEventTime = now
end

function RecordLoss(aiBrain, lostUnit, instigator)
    if not aiBrain or not aiBrain.OvermindAI or not lostUnit then
        return
    end

    local now = GetGameTimeSeconds()
    local memory = EnsureMemory(aiBrain)
    ApplyDecay(memory, now)

    local mass = GetUnitMassValue(lostUnit)
    memory.LossMassLifetime = (memory.LossMassLifetime or 0) + mass
    memory.LossMassRecent = (memory.LossMassRecent or 0) + mass
    memory.LastCombatEventTime = now

    if EntityCategoryContains(categories.ENGINEER * categories.MOBILE, lostUnit) then
        memory.EngineerLossRecent = (memory.EngineerLossRecent or 0) + 1
        memory.EngineerLossLifetime = (memory.EngineerLossLifetime or 0) + 1
        local pos = false
        if lostUnit.GetPosition then
            pos = lostUnit:GetPosition()
        end
        if pos then
            AddEngineerLossHotspot(memory, pos, math.max(0.7, mass / 80), now)
            local mainPos = GetMainPos(aiBrain)
            if mainPos then
                local dist = Distance2D(mainPos, pos)
                if dist > 150 then
                    AddRouteBlackspot(memory, pos, math.max(1.2, mass / 55), now)
                end
            else
                AddRouteBlackspot(memory, pos, math.max(0.9, mass / 70), now)
            end
            memory.LastEngineerLossTime = now
        end
    end
end

function RecordBuildComplete(aiBrain, builder, completedUnit)
    if not aiBrain or not aiBrain.OvermindAI or not completedUnit then
        return
    end

    local now = GetGameTimeSeconds()
    local memory = EnsureMemory(aiBrain)
    ApplyDecay(memory, now)

    local mass = GetUnitMassValue(completedUnit)
    memory.BuildMassLifetime = (memory.BuildMassLifetime or 0) + mass
    memory.BuildMassRecent = (memory.BuildMassRecent or 0) + mass
    if EntityCategoryContains(categories.ENGINEER * categories.MOBILE, completedUnit) then
        memory.EngineerBuiltRecent = (memory.EngineerBuiltRecent or 0) + 1
        memory.EngineerBuiltLifetime = (memory.EngineerBuiltLifetime or 0) + 1
    end
    memory.LastEcoEventTime = now
end

function RecordReclaim(aiBrain, reclaimer, target)
    if not aiBrain or not aiBrain.OvermindAI or not target then
        return
    end

    local now = GetGameTimeSeconds()
    local memory = EnsureMemory(aiBrain)
    ApplyDecay(memory, now)

    local mass = GetUnitMassValue(target) * 0.8
    memory.ReclaimMassLifetime = (memory.ReclaimMassLifetime or 0) + mass
    memory.ReclaimMassRecent = (memory.ReclaimMassRecent or 0) + mass
    memory.LastEcoEventTime = now
end

function GetCombatMomentum(aiBrain)
    local memory = EnsureMemory(aiBrain)
    local killMass = memory.KillMassRecent or 0
    local lossMass = memory.LossMassRecent or 0
    local total = killMass + lossMass

    if total < 1 then
        return 0
    end

    local raw = (killMass - lossMass) / math.max(80, total)
    return Clamp(raw, -1, 1)
end

function GetEconomicMomentum(aiBrain)
    local memory = EnsureMemory(aiBrain)
    local ecoFlow = (memory.BuildMassRecent or 0) + (memory.ReclaimMassRecent or 0)
    local scaled = ecoFlow / 400
    return Clamp(scaled, 0, 1.5)
end

function GetEngineerLossRisk(aiBrain, position, radius)
    if not aiBrain or not position then
        return 0
    end

    local memory = EnsureMemory(aiBrain)
    local hotspots = memory.EngineerLossHotspots or {}
    local checkRadius = radius or 48
    if checkRadius <= 0 then
        checkRadius = 48
    end

    local invRadius = 1 / checkRadius
    local risk = 0
    for _, hotspot in hotspots do
        if hotspot and hotspot.Pos then
            local dx = (hotspot.Pos[1] or 0) - (position[1] or 0)
            local dz = (hotspot.Pos[3] or 0) - (position[3] or 0)
            local dist = math.sqrt((dx * dx) + (dz * dz))
            if dist <= checkRadius then
                risk = risk + (hotspot.Score or 0) * (1 - (dist * invRadius))
            end
        end
    end

    return risk
end

function GetEngineerLossPressure(aiBrain)
    if not aiBrain then
        return 0
    end

    local now = GetGameTimeSeconds()
    local memory = EnsureMemory(aiBrain)
    ApplyDecay(memory, now)

    local currentEngineers = aiBrain:GetCurrentUnits(categories.ENGINEER * categories.MOBILE) or 0
    local recentBuilt = memory.EngineerBuiltRecent or 0
    local recentLoss = memory.EngineerLossRecent or 0
    local denominator = math.max(2, (recentBuilt * 0.55) + (currentEngineers * 0.35))
    return Clamp(recentLoss / denominator, 0, 3)
end

function GetExpansionRisk(aiBrain, position, radius)
    if not aiBrain or not position then
        return 0
    end

    local checkRadius = radius or 54
    if checkRadius <= 0 then
        checkRadius = 54
    end

    local memory = EnsureMemory(aiBrain)
    local risk = GetEngineerLossRisk(aiBrain, position, checkRadius)
    local hotspots = memory.RiskHotspots or {}
    local invRadius = 1 / checkRadius
    for _, hotspot in hotspots do
        if hotspot and hotspot.Pos then
            local dx = (hotspot.Pos[1] or 0) - (position[1] or 0)
            local dz = (hotspot.Pos[3] or 0) - (position[3] or 0)
            local dist = math.sqrt((dx * dx) + (dz * dz))
            if dist <= checkRadius then
                risk = risk + (hotspot.Score or 0) * (1 - (dist * invRadius))
            end
        end
    end

    return risk
end

function IsRouteBlacklisted(aiBrain, position, radius, minScore)
    if not aiBrain or not position then
        return false
    end

    local memory = EnsureMemory(aiBrain)
    local hotspots = memory.RouteBlackspots or {}
    local checkRadius = radius or 72
    local neededScore = minScore or 5
    local score = 0

    for _, hotspot in hotspots do
        if hotspot and hotspot.Pos then
            local dist = Distance2D(hotspot.Pos, position)
            if dist <= checkRadius then
                score = score + (hotspot.Score or 0) * (1 - (dist / math.max(1, checkRadius)))
                if score >= neededScore then
                    return true
                end
            end
        end
    end

    return false
end

function GetRouteRisk(aiBrain, fromPos, toPos, samples, probeRadius)
    if not aiBrain or not fromPos or not toPos then
        return 0
    end

    local sampleCount = math.max(3, math.min(8, math.floor(samples or 5)))
    local radius = math.max(36, probeRadius or 56)
    local totalRisk = 0

    for i = 1, sampleCount do
        local t = i / (sampleCount + 1)
        local probe = {
            fromPos[1] + ((toPos[1] - fromPos[1]) * t),
            0,
            fromPos[3] + ((toPos[3] - fromPos[3]) * t),
        }
        local probeRisk = GetExpansionRisk(aiBrain, probe, radius)
        totalRisk = totalRisk + probeRisk
    end

    return totalRisk / sampleCount
end
