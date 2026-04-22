local BenchIO = import('/mods/OvermindAI/lua/AI/Overmind/BenchIO.lua')
local OldOnFirstUpdate = OnFirstUpdate

function OnFirstUpdate()
    if OldOnFirstUpdate then
        OldOnFirstUpdate()
    end

    if not BenchIO.BenchmarkMode() then
        return
    end

    if rawget(_G, '__OvermindBenchSimSpeedApplied') then
        return
    end
    rawset(_G, '__OvermindBenchSimSpeedApplied', true)

    local speed = tonumber(BenchIO.Arg('/bench_simspeed') or '') or 2
    speed = math.max(1, math.floor(speed + 0.5))

    local conExecute = rawget(_G, 'ConExecute')
    if conExecute then
        conExecute('WLD_GameSpeed ' .. tostring(speed))
        BenchIO.Emit('*OVERMIND_BENCH_META|phase=simspeed|value=' .. tostring(speed))
    else
        BenchIO.Emit('*OVERMIND_BENCH_WARN|phase=simspeed|message=conexecute_missing')
    end
end
