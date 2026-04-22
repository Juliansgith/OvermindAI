local OldCreateUI = CreateUI
local BenchIO = import('/mods/OvermindAI/lua/AI/Overmind/BenchIO.lua')

BenchIO.Emit('*OVERMIND_BENCH_META|phase=main_hook_loaded')
BenchIO.Probe('*OVERMIND_HOOK|phase=main_hook_loaded')

local function ReadSingleArg(argName)
    return BenchIO.Arg(argName)
end

local function IsBenchmarkMode()
    return BenchIO.BenchmarkMode()
end

local function GetBenchmarkMapName()
    local mapName = ReadSingleArg('/benchmap')
    if mapName and mapName ~= '' then
        return mapName
    end

    mapName = ReadSingleArg('/map')
    if mapName and mapName ~= '' then
        return mapName
    end

    return 'scmp_007'
end

local function StartBenchmarkSessionFromMenu()
    if _G.__OvermindBenchStartIssued then
        return
    end
    _G.__OvermindBenchStartIssued = true

    local mapName = GetBenchmarkMapName()
    BenchIO.Emit('*OVERMIND_BENCH_META|phase=autostart_menu|map=' .. tostring(mapName))

    ForkThread(function()
        WaitSeconds(0.5)
        import('/lua/SinglePlayerLaunch.lua').StartCommandLineSession(mapName, false)
    end)
end

function CreateUI()
    OldCreateUI()

    BenchIO.Emit('*OVERMIND_BENCH_META|phase=create_ui|bench=' .. tostring(IsBenchmarkMode()))
    BenchIO.Probe('*OVERMIND_HOOK|phase=create_ui|bench=' .. tostring(IsBenchmarkMode()))

    if not IsBenchmarkMode() then
        return
    end

    local ok, err = pcall(StartBenchmarkSessionFromMenu)
    if not ok then
        BenchIO.Emit('*OVERMIND_BENCH_ERROR|phase=autostart_menu|message=' .. tostring(err))
    end
end

