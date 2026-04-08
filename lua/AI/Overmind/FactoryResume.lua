local FactoryCategory = categories.FACTORY * categories.STRUCTURE
local BuilderCategory = categories.ENGINEER * categories.MOBILE + categories.COMMAND

local Module = {}

local function Distance2D(a, b)
    local dx = (a[1] or 0) - (b[1] or 0)
    local dz = (a[3] or 0) - (b[3] or 0)
    return math.sqrt((dx * dx) + (dz * dz))
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
        return tostring(unit:GetEntityId())
    end
    return tostring(unit)
end

local function CountCompletedFactories(aiBrain)
    local factories = aiBrain:GetListOfUnits(FactoryCategory, false, true)
    if not factories then
        return 0
    end

    local count = 0
    for _, factory in factories do
        if factory and not factory.Dead and GetFraction(factory) >= 0.95 then
            count = count + 1
        end
    end
    return count
end

local function FindBestUnfinishedFactory(aiBrain, mainPos)
    local factories = aiBrain:GetListOfUnits(FactoryCategory, false, true)
    if not factories then
        return false, false
    end

    local best = false
    local bestPos = false
    local bestScore = -999999
    for _, factory in factories do
        if factory and not factory.Dead then
            local fraction = GetFraction(factory)
            if fraction < 0.95 then
                local pos = factory.GetPosition and factory:GetPosition() or false
                if pos then
                    local distMain = Distance2D(pos, mainPos)
                    local score = (fraction * 120) - (distMain * 0.18)
                    if EntityCategoryContains(categories.FACTORY * categories.LAND, factory) then
                        score = score + 8
                    end
                    if distMain <= 120 then
                        score = score + 6
                    end
                    if score > bestScore then
                        best = factory
                        bestPos = pos
                        bestScore = score
                    end
                end
            end
        end
    end

    return best, bestPos
end

local function ScoreBuilder(unit, dist, busy, isCommander, qLen)
    local score = -dist
    if not busy then
        score = score + 140
    elseif qLen <= 1 then
        score = score + 60
    else
        score = score + math.max(0, 30 - (qLen * 6))
    end
    if isCommander then
        score = score + 35
    end
    return score
end

local function PickBuilderNearTarget(aiBrain, targetPos, forceBusy, mainPos, stallTime, completeFactories)
    local builders = aiBrain:GetListOfUnits(BuilderCategory, false, true)
    if not builders then
        return false, false, { Total = 0, Safe = 0, Local = 0, Interruptible = 0 }
    end

    local localRadius = 320
    if stallTime >= 12 then
        localRadius = 480
    end
    if stallTime >= 28 then
        localRadius = 720
    end
    if stallTime >= 55 then
        localRadius = 960
    end

    local interruptQCap = 1
    if stallTime >= 18 then
        interruptQCap = 3
    end
    if stallTime >= 45 then
        interruptQCap = 6
    end
    if completeFactories <= 0 and stallTime >= 8 then
        interruptQCap = math.max(interruptQCap, 8)
    end

    local bestLocalIdle = false
    local bestLocalIdleScore = -999999
    local bestLocalBusy = false
    local bestLocalBusyScore = -999999
    local bestGlobalIdle = false
    local bestGlobalIdleScore = -999999
    local bestGlobalBusy = false
    local bestGlobalBusyScore = -999999
    local debug = {
        Total = 0,
        Safe = 0,
        Local = 0,
        Interruptible = 0,
    }

    for _, unit in builders do
        if unit and not unit.Dead then
            debug.Total = debug.Total + 1
            local pos = unit.GetPosition and unit:GetPosition() or false
            if pos then
                local dist = Distance2D(pos, targetPos)
                local q = unit.GetCommandQueue and unit:GetCommandQueue() or false
                local qLen = q and table.getn(q) or 0
                local busy = qLen > 0 or unit:IsUnitState('Building') or unit:IsUnitState('Upgrading')
                local localThreat = aiBrain:GetThreatAtPosition(pos, 2, true, 'AntiSurface') or 0
                local isCommander = EntityCategoryContains(categories.COMMAND, unit)
                local safeCap = 2.5
                if stallTime >= 18 then
                    safeCap = 3.2
                end
                if isCommander then
                    safeCap = safeCap + 0.6
                end
                local safe = localThreat <= safeCap
                if isCommander and mainPos and Distance2D(pos, mainPos) > 180 then
                    safe = false
                end

                if safe then
                    debug.Safe = debug.Safe + 1
                    local score = ScoreBuilder(unit, dist, busy, isCommander, qLen)
                    local isLocal = dist <= localRadius
                    local interruptible = (not busy) or (forceBusy and qLen <= interruptQCap)
                    if isLocal then
                        debug.Local = debug.Local + 1
                    end
                    if interruptible then
                        debug.Interruptible = debug.Interruptible + 1
                        if isLocal then
                            if not busy and score > bestLocalIdleScore then
                                bestLocalIdle = unit
                                bestLocalIdleScore = score
                            elseif busy and score > bestLocalBusyScore then
                                bestLocalBusy = unit
                                bestLocalBusyScore = score
                            end
                        else
                            if not busy and score > bestGlobalIdleScore then
                                bestGlobalIdle = unit
                                bestGlobalIdleScore = score
                            elseif busy and score > bestGlobalBusyScore then
                                bestGlobalBusy = unit
                                bestGlobalBusyScore = score
                            end
                        end
                    end
                end
            end
        end
    end

    if bestLocalIdle then
        return bestLocalIdle, false, debug
    end
    if bestLocalBusy then
        return bestLocalBusy, true, debug
    end
    if bestGlobalIdle then
        return bestGlobalIdle, false, debug
    end
    if bestGlobalBusy then
        return bestGlobalBusy, true, debug
    end
    return false, false, debug
end

function Module.Update(aiBrain, now)
    local runtime = aiBrain.OvermindRuntime or {}
    aiBrain.OvermindRuntime = runtime

    local engineerState = runtime.EngineerState or {}
    local factoryTask = engineerState.UnfinishedFactoryTask or {}
    if factoryTask.Active and (factoryTask.AssignedBuilders or 0) > 0 then
        local state = runtime.FactoryResume or {}
        state.NextTry = now + 6
        runtime.FactoryResume = state
        return
    end

    local state = runtime.FactoryResume or {
        NextTry = -999,
        LastLogTime = -999,
        LastTargetId = false,
        LastFraction = 0,
        LastProgressTime = now,
    }
    runtime.FactoryResume = state

    if now < (state.NextTry or -999) then
        return
    end

    local mainPos = GetMainPos(aiBrain, runtime)
    local target, targetPos = FindBestUnfinishedFactory(aiBrain, mainPos)
    if not target or not targetPos then
        state.LastTargetId = false
        state.NextTry = now + 4
        return
    end

    local targetId = GetEntityId(target)
    local fraction = GetFraction(target)
    if state.LastTargetId ~= targetId or fraction > ((state.LastFraction or 0) + 0.01) then
        state.LastTargetId = targetId
        state.LastFraction = fraction
        state.LastProgressTime = now
    end

    local completeFactories = CountCompletedFactories(aiBrain)
    local recovery = runtime.Recovery or {}
    local stallTime = now - (state.LastProgressTime or now)
    local forceBusy = stallTime >= 8
        or fraction >= 0.45
        or completeFactories <= 0
        or recovery.ForceFactoryRecovery
        or (recovery.StagnationTime or 0) >= 25

    local builder, busy, debug = PickBuilderNearTarget(aiBrain, targetPos, forceBusy, mainPos, stallTime, completeFactories)
    if not builder then
        if now - (state.LastLogTime or -999) >= 10 then
            state.LastLogTime = now
            LOG(string.format('*OVERMIND FACRESUME A%d t=%.1f frac=%.2f stall=%.1f forced=%d busy=-1 cand=%d/%d/%d/%d',
                aiBrain:GetArmyIndex(),
                now,
                fraction,
                stallTime,
                forceBusy and 1 or 0,
                debug and debug.Total or 0,
                debug and debug.Safe or 0,
                debug and debug.Local or 0,
                debug and debug.Interruptible or 0))
        end
        state.NextTry = now + 2
        return
    end

    if busy and forceBusy and IssueClearCommands then
        IssueClearCommands({ builder })
    end

    if IssueRepair then
        IssueRepair({ builder }, target)
    elseif IssueGuard then
        IssueGuard({ builder }, target)
    end

    state.NextTry = now + 5
    if now - (state.LastLogTime or -999) >= 10 then
        state.LastLogTime = now
        LOG(string.format('*OVERMIND FACRESUME A%d t=%.1f frac=%.2f stall=%.1f forced=%d busy=%d',
            aiBrain:GetArmyIndex(),
            now,
            fraction,
            stallTime,
            forceBusy and 1 or 0,
            busy and 1 or 0))
    end
end

function Update(aiBrain, now)
    return Module.Update(aiBrain, now)
end

return Module
