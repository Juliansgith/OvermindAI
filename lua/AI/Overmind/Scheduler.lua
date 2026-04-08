local OvermindBudget = import('/mods/OvermindAI/lua/AI/Overmind/Budget.lua')
local OvermindSubsystemContracts = import('/mods/OvermindAI/lua/AI/Overmind/SubsystemContracts.lua')

local function SafeRunAction(action, aiBrain, now)
    if type(action) ~= 'table' then
        LOG('*OVERMIND ERROR [subsystem] action-not-table')
        return
    end

    local ok, err = OvermindSubsystemContracts.Invoke(action, aiBrain, now)
    if not ok then
        LOG('*OVERMIND ERROR [' .. tostring(action.Label or action.Name or 'subsystem') .. '] ' .. tostring(err))
    end
end

local function RunGroup(groupName, aiBrain, now)
    for _, action in OvermindSubsystemContracts.GetGroup(groupName) do
        SafeRunAction(action, aiBrain, now)
    end
end

function Run(aiBrain)
    if not aiBrain or aiBrain:IsDefeated() then
        return
    end

    if aiBrain.OvermindSchedulerRunning then
        return
    end

    aiBrain.OvermindSchedulerRunning = true
    aiBrain.OvermindRuntime = aiBrain.OvermindRuntime or {}
    OvermindBudget.Init(aiBrain)
    LOG(string.format('*OVERMIND SCHEDULER START A%d', aiBrain:GetArmyIndex()))

    while aiBrain and not aiBrain:IsDefeated() and aiBrain.OvermindEnabled do
        local now = GetGameTimeSeconds()
        local okLoop, errLoop = pcall(function()
            OvermindBudget.Update(aiBrain, now)

            RunGroup('always', aiBrain, now)

            if OvermindBudget.ShouldRun(aiBrain, 'strategic', now, 7) then
                RunGroup('strategic', aiBrain, now)
            end

            if OvermindBudget.ShouldRun(aiBrain, 'tactical', now, 2) then
                RunGroup('tactical', aiBrain, now)
            end

            if OvermindBudget.ShouldRun(aiBrain, 'macro-control', now, 4) then
                RunGroup('macro-control', aiBrain, now)
            end

            if OvermindBudget.ShouldRun(aiBrain, 'factory-control', now, 0.8) then
                RunGroup('factory-control', aiBrain, now)
            end

            if OvermindBudget.ShouldRun(aiBrain, 'telemetry', now, 22) then
                RunGroup('telemetry', aiBrain, now)
            end
        end)

        if not okLoop then
            LOG('*OVERMIND ERROR [scheduler-loop] ' .. tostring(errLoop))
            if aiBrain.OvermindRuntime then
                aiBrain.OvermindRuntime.Budget = nil
            end
            OvermindBudget.Init(aiBrain)
        end

        local runtime = aiBrain.OvermindRuntime or {}
        runtime.LastSchedulerPulse = now
        aiBrain.OvermindRuntime = runtime
        if not runtime.SelfTestRuntimeLogged and now >= 20 then
            runtime.SelfTestRuntimeLogged = true
            local rec = runtime.Recovery or {}
            LOG(string.format('*OVERMIND SELFTEST_RUNTIME A%d t=%.1f facctrl=1 radarfb=1 bombharass=1 mexdef=1 qDef=%.2f qUp=%.2f',
                aiBrain:GetArmyIndex(),
                now,
                rec.FactoryQueueDeficitRatio or 0,
                rec.FactoryQueueUptime or 0))
        end
        if now - (runtime.LastSchedulerLogTime or -999) >= 60 then
            runtime.LastSchedulerLogTime = now
            LOG(string.format('*OVERMIND SCHEDULER PULSE A%d t=%.1f', aiBrain:GetArmyIndex(), now))
        end

        local tick = 30
        local okTick, tickValue = pcall(OvermindBudget.GetAdaptiveTick, aiBrain)
        if okTick and type(tickValue) == 'number' then
            tick = tickValue
        else
            LOG('*OVERMIND ERROR [scheduler-tick] ' .. tostring(tickValue))
        end

        tick = math.max(5, math.min(120, math.floor(tick)))
        WaitTicks(tick)
    end

    LOG(string.format('*OVERMIND SCHEDULER STOP A%d', aiBrain:GetArmyIndex()))
    aiBrain.OvermindSchedulerRunning = false
end
