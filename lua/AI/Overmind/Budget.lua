local function GetUnitCount(aiBrain)
    return aiBrain:GetCurrentUnits(categories.ALLUNITS) or 0
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

    local last = budget.LastRun[key] or -10000
    local interval = (baseInterval or 1) * (budget.LoadFactor or 1)

    if now - last >= interval then
        budget.LastRun[key] = now
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
    return tick
end

