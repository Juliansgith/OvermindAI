local M = {}

local function Distance2D(a, b)
    local dx = (a[1] or 0) - (b[1] or 0)
    local dz = (a[3] or 0) - (b[3] or 0)
    return math.sqrt((dx * dx) + (dz * dz))
end

local function Clamp(v, minV, maxV)
    if v < minV then
        return minV
    end
    if v > maxV then
        return maxV
    end
    return v
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

local function GetFraction(unit)
    if not unit or unit.Dead or not unit.GetFractionComplete then
        return 1
    end
    local ok, fraction = pcall(function()
        return unit:GetFractionComplete()
    end)
    if ok and type(fraction) == 'number' then
        return fraction
    end
    return 1
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

local function IsIdle(unit)
    local q = unit and unit.GetCommandQueue and unit:GetCommandQueue() or false
    return (not q) or table.getn(q) == 0
end

local function GetCommandQueueLength(unit)
    local q = unit and unit.GetCommandQueue and unit:GetCommandQueue() or false
    return q and table.getn(q) or 0
end

local function IsReadyBuilder(unit)
    return unit
        and not unit.Dead
        and GetFraction(unit) >= 0.95
        and not unit:IsUnitState('BeingBuilt')
        and not unit:IsUnitState('Upgrading')
end

local function IsConstructing(unit)
    if not unit or unit.Dead then
        return false
    end
    return unit:IsUnitState('Building') or unit:IsUnitState('Upgrading')
end

local function ShouldThrottle(runtime, entityId, now, interval)
    runtime.EngineerRecallCooldown = runtime.EngineerRecallCooldown or {}
    local last = runtime.EngineerRecallCooldown[entityId] or -1000
    if now - last < interval then
        return true
    end
    runtime.EngineerRecallCooldown[entityId] = now
    return false
end

local function RecallEngineer(runtime, eng, mainPos, now, reason)
    if not eng or eng.Dead or not mainPos then
        return false
    end
    local entityId = eng.EntityId or 0
    if entityId > 0 and ShouldThrottle(runtime, entityId, now, 12) then
        return false
    end

    if IssueClearCommands then
        IssueClearCommands({ eng })
    end
    if IssueMove then
        IssueMove({ eng }, mainPos)
    end

    runtime.LastEngineerRecallReason = reason
    runtime.LastEngineerRecallTime = now
    return true
end


M.Distance2D = Distance2D
M.Clamp = Clamp
M.GetMainPos = GetMainPos
M.GetFraction = GetFraction
M.GetEntityId = GetEntityId
M.IsIdle = IsIdle
M.GetCommandQueueLength = GetCommandQueueLength
M.IsReadyBuilder = IsReadyBuilder
M.IsConstructing = IsConstructing
M.ShouldThrottle = ShouldThrottle
M.RecallEngineer = RecallEngineer
return M
