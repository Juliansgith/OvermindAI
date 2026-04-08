do
    local BenchIO = import('/mods/OvermindAI/lua/AI/Overmind/BenchIO.lua')

    OvermindAIPath = function()
        for _, mod in __active_mods do
            if mod.uid == 'A51D4E33-13D8-4F4E-B7B1-OVERMIND0001' then
                return mod.location
            end
        end
    end

    if BenchIO.BenchmarkMode() then
        local path = OvermindAIPath() or 'unknown'
        BenchIO.Emit('*OVERMIND_BENCH_META|phase=mod_loaded|path=' .. tostring(path))
    end
end
