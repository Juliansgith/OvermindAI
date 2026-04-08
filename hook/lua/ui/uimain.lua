local OldNoteGameOver = NoteGameOver
local BenchIO = import('/mods/OvermindAI/lua/AI/Overmind/BenchIO.lua')

local function ReadSingleArg(argName)
    return BenchIO.Arg(argName)
end

local function IsBenchmarkMode()
    return BenchIO.BenchmarkMode()
end

function NoteGameOver()
    OldNoteGameOver()

    if not IsBenchmarkMode() then
        return
    end

    if _G.__OvermindBenchExitQueued then
        return
    end
    _G.__OvermindBenchExitQueued = true

    local exitDelay = tonumber(ReadSingleArg('/bench_exit_delay') or '') or 8
    exitDelay = math.max(1, exitDelay)

    BenchIO.Emit('*OVERMIND_BENCH_META|phase=exit_queued|delay=' .. tostring(exitDelay))

    ForkThread(function()
        WaitSeconds(exitDelay)
        ExitApplication()
    end)
end
