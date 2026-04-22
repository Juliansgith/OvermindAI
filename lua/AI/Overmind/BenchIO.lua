local ControlPath = 'benchmarks/latest/pending_run.txt'
local ProbePath = 'benchmarks/latest/hook_probe.txt'

local function Trim(value)
    local s = tostring(value or '')
    s = string.gsub(s, '^%s+', '')
    s = string.gsub(s, '%s+$', '')
    return s
end

local function NormalizeArgName(argName)
    local name = string.lower(Trim(argName))
    if string.sub(name, 1, 1) == '/' then
        name = string.sub(name, 2)
    end
    return name
end

local function AppendLine(path, line)
    local ioLib = rawget(_G, 'io')
    local openFn = ioLib and ioLib.open
    if not path or path == '' or not openFn then
        return
    end

    local ok, err = pcall(function()
        local file = openFn(path, 'a')
        if file then
            file:write(line)
            file:write('\n')
            file:close()
        end
    end)

    if not ok and err and LOG then
        LOG('*OVERMIND_BENCH_ERROR|phase=file_append|path=' .. tostring(path) .. '|message=' .. tostring(err))
    end
end

local function ReadControlData()
    local data = {}
    local ioLib = rawget(_G, 'io')
    local openFn = ioLib and ioLib.open
    if not openFn then
        return data
    end

    local ok, file = pcall(openFn, ControlPath, 'r')
    if not ok or not file then
        return data
    end

    for line in file:lines() do
        local key, value = string.match(line, '^%s*([^=]+)%s*=(.*)$')
        if key and value then
            data[NormalizeArgName(key)] = Trim(value)
        end
    end
    file:close()

    return data
end

local function ReadCommandLineArg(argName)
    local getter = rawget(_G, 'GetCommandLineArg')
    if not getter then
        return nil
    end

    local ok, args = pcall(getter, argName, 1)
    if not ok or not args or not args[1] then
        return nil
    end

    local value = Trim(args[1])
    if value == '' then
        return nil
    end
    return value
end

local function HasCommandLine(argName)
    local hasArgFn = rawget(_G, 'HasCommandLineArg')
    if hasArgFn then
        local ok, value = pcall(hasArgFn, argName)
        if ok and value then
            return true
        end
    end
    return ReadCommandLineArg(argName) ~= nil
end

local function ReadControlArg(argName)
    local data = ReadControlData()
    local key = NormalizeArgName(argName)
    local value = data[key]
    if value and value ~= '' then
        return value
    end
    return nil
end

local function ReadSingleArg(argName)
    local value = ReadCommandLineArg(argName)
    if value then
        return value
    end
    return ReadControlArg(argName)
end

local function IsTruthy(value)
    local lower = string.lower(Trim(value))
    return lower == '1' or lower == 'true' or lower == 'yes' or lower == 'on' or lower == 'ready'
end

local function IsBenchmarkMode()
    if HasCommandLine('/overmindbench') then
        return true
    end

    -- Some launcher / init combinations drop boolean flags but keep valued args.
    -- Treat the benchmark payload arguments as an implicit benchmark-mode signal.
    if ReadCommandLineArg('/benchout') or ReadCommandLineArg('/benchid') or ReadCommandLineArg('/bench_ai') then
        return true
    end

    local mode = ReadControlArg('mode')
    if mode and IsTruthy(mode) then
        return true
    end

    local controlFlag = ReadControlArg('overmindbench')
    if controlFlag and IsTruthy(controlFlag) then
        return true
    end

    return false
end

local function GetBenchOutPath()
    local path = ReadSingleArg('/benchout')
    if path and path ~= '' then
        return path
    end
    return nil
end

local function AppendToBenchFile(line)
    AppendLine(GetBenchOutPath(), line)
end

function Emit(line)
    if LOG then
        LOG(line)
    end
    AppendToBenchFile(line)
end

function Probe(line)
    AppendLine(ProbePath, line)
end

function BenchmarkMode()
    return IsBenchmarkMode()
end

function Arg(name)
    return ReadSingleArg(name)
end

