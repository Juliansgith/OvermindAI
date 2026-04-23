local function GetUnitCount(aiBrain)
    return aiBrain:GetCurrentUnits(categories.ALLUNITS) or 0
end

local function GetRandomization(aiBrain)
    local runtime = aiBrain and aiBrain.OvermindRuntime or false
    if runtime and type(runtime.Randomization) == 'table' then
        return runtime.Randomization
    end
    return false
end

local function KeyHash(seed, key)
    local hash = math.mod((seed or 1315423911), 2147483647)
    local text = tostring(key or 'none')
    for i = 1, string.len(text) do
        hash = math.mod(((hash * 33) + string.byte(text, i) + i), 2147483647)
    end
    return hash
end

function Init(aiBrain)
    aiBrain.OvermindRuntime = aiBrain.OvermindRuntime or {}
    aiBrain.OvermindRuntime.Budget = aiBrain.OvermindRuntime.Budget or {
        LastRun = {},
        LoadFactor = 1,
        Tick = 40,
        UnitCount = 0,
    }
end

function Update(aiBrain, now)
    Init(aiBrain)
    local budget = aiBrain.OvermindRuntime.Budget
    local unitCount = GetUnitCount(aiBrain)

    budget.UnitCount = unitCount
    budget.LoadFactor = 1

    if unitCount >= 1400 then
        budget.LoadFactor = 3.8
    elseif unitCount >= 1100 then
        budget.LoadFactor = 3.0
    elseif unitCount >= 850 then
        budget.LoadFactor = 2.4
    elseif unitCount >= 650 then
        budget.LoadFactor = 1.9
    elseif unitCount >= 450 then
        budget.LoadFactor = 1.45
    end

    budget.Tick = math.floor(30 * budget.LoadFactor)
    if aiBrain.OvermindCheat then
        budget.Tick = math.max(20, budget.Tick - 4)
    end
end

function ShouldRun(aiBrain, key, now, baseInterval)
    local budget = aiBrain.OvermindRuntime and aiBrain.OvermindRuntime.Budget
    if not budget then
        return true
    end

    local randomization = GetRandomization(aiBrain)
    local cadenceScale = randomization and randomization.CadenceScale or 1
    local interval = (baseInterval or 1) * (budget.LoadFactor or 1) * cadenceScale
    local minInterval = (baseInterval or 1) * 0.55

    if randomization then
        randomization.KeyIntervalJitter = randomization.KeyIntervalJitter or {}
        local intervalAdjust = randomization.KeyIntervalJitter[key]
        if intervalAdjust == nil then
            local hash = KeyHash(randomization.Seed or 0, 'int:' .. tostring(key))
            intervalAdjust = (((math.mod(hash, 11)) - 5) * 0.04) + (randomization.KeyJitterBias or 0)
            randomization.KeyIntervalJitter[key] = intervalAdjust
        end
        interval = interval + intervalAdjust
    end
    interval = math.max(minInterval, interval)

    local last = budget.LastRun[key]
    if last == nil then
        if randomization then
            randomization.KeyPhaseJitter = randomization.KeyPhaseJitter or {}
            local phaseRatio = randomization.KeyPhaseJitter[key]
            if phaseRatio == nil then
                local hash = KeyHash(randomization.Seed or 0, 'phase:' .. tostring(key))
                phaseRatio = math.mod(hash, 5) * 0.04
                randomization.KeyPhaseJitter[key] = phaseRatio
            end
            last = now - (interval * (1 - phaseRatio))
        else
            last = -10000
        end
        budget.LastRun[key] = last
    end

    if now - last >= interval then
        local writeTime = now
        if randomization then
            randomization.KeyAdvanceJitter = randomization.KeyAdvanceJitter or {}
            local advance = randomization.KeyAdvanceJitter[key]
            if advance == nil then
                local hash = KeyHash(randomization.Seed or 0, 'adv:' .. tostring(key))
                advance = ((math.mod(hash, 7)) - 3) * 0.03
                randomization.KeyAdvanceJitter[key] = advance
            end
            writeTime = now + advance
        end
        budget.LastRun[key] = writeTime
        return true
    end

    return false
end

function GetAdaptiveTick(aiBrain)
    local budget = aiBrain.OvermindRuntime and aiBrain.OvermindRuntime.Budget
    if not budget then
        return 40
    end

    local tick = budget.Tick or 40
    local runtime = aiBrain.OvermindRuntime
    if runtime and runtime.Aggression and runtime.Aggression >= 1.4 and (budget.UnitCount or 0) < 800 then
        tick = math.max(20, tick - 8)
    end
    local randomization = GetRandomization(aiBrain)
    if randomization then
        tick = tick + (randomization.TickBias or 0)
        runtime.SchedulerCycle = (runtime.SchedulerCycle or 0) + 1
        local wave = (math.mod((runtime.SchedulerCycle + (randomization.Instance or 0)), 3)) - 1
        tick = tick + wave
    end
    return tick
end
