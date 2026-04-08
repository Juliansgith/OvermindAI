local OldCallEndGame = CallEndGame
local BenchSummaryWritten = false
local BenchIO = import('/mods/OvermindAI/lua/AI/Overmind/BenchIO.lua')

local function IsBenchmarkMode()
    return BenchIO.BenchmarkMode()
end

local function ReadSingleArg(argName)
    return BenchIO.Arg(argName)
end

local function EscapeField(value)
    local s = tostring(value or '')
    s = string.gsub(s, '[\r\n|]', '_')
    return s
end

local function ReadStat(aiBrain, key)
    local stat = aiBrain:GetArmyStat(key, 0)
    if stat and stat.Value then
        return stat.Value
    end
    return 0
end

local function BuildResultLookup()
    local lookup = {}
    if Sync and Sync.GameResult then
        for _, entry in Sync.GameResult do
            if entry and entry[1] and entry[2] then
                lookup[entry[1]] = entry[2]
            end
        end
    end
    return lookup
end

local function EmitBenchmarkSummary()
    if BenchSummaryWritten or not IsBenchmarkMode() then
        return
    end
    BenchSummaryWritten = true

    local benchId = ReadSingleArg('/benchid') or ('bench-' .. math.floor(GetGameTimeSeconds()))
    local mapName = ''
    if ScenarioInfo then
        mapName = ScenarioInfo.file or ScenarioInfo.name or ScenarioInfo.map or ''
    end

    BenchIO.Emit('*OVERMIND_BENCH_META|phase=final|id=' .. EscapeField(benchId)
        .. '|map=' .. EscapeField(mapName)
        .. '|time=' .. string.format('%.2f', GetGameTimeSeconds()))

    local results = BuildResultLookup()

    for _, aiBrain in ArmyBrains do
        local armyIndex = aiBrain:GetArmyIndex()
        if not ArmyIsCivilian(armyIndex) then
            local armyName = aiBrain.Name or ('ARMY_' .. tostring(armyIndex))
            local armySetup = ScenarioInfo and ScenarioInfo.ArmySetup and ScenarioInfo.ArmySetup[armyName] or {}
            local aiKey = armySetup and armySetup.AIPersonality or aiBrain.Personality or ''
            local result = results[armyIndex]

            if not result then
                if aiBrain:IsDefeated() then
                    result = 'defeat'
                else
                    result = 'unknown'
                end
            end

            local message = table.concat({
                '*OVERMIND_BENCH_RESULT',
                'id=' .. EscapeField(benchId),
                'army=' .. tostring(armyIndex),
                'name=' .. EscapeField(armyName),
                'ai=' .. EscapeField(aiKey),
                'result=' .. EscapeField(result),
                'score=' .. string.format('%.2f', aiBrain:CalculateScore()),
                'mass_in=' .. string.format('%.2f', ReadStat(aiBrain, 'Economy_TotalProduced_Mass')),
                'mass_out=' .. string.format('%.2f', ReadStat(aiBrain, 'Economy_TotalConsumed_Mass')),
                'mass_over=' .. string.format('%.2f', ReadStat(aiBrain, 'Economy_AccumExcess_Mass')),
                'energy_in=' .. string.format('%.2f', ReadStat(aiBrain, 'Economy_TotalProduced_Energy')),
                'energy_out=' .. string.format('%.2f', ReadStat(aiBrain, 'Economy_TotalConsumed_Energy')),
                'energy_over=' .. string.format('%.2f', ReadStat(aiBrain, 'Economy_AccumExcess_Energy')),
                'kills_mass=' .. string.format('%.2f', ReadStat(aiBrain, 'Enemies_MassValue_Destroyed')),
                'loss_mass=' .. string.format('%.2f', ReadStat(aiBrain, 'Units_MassValue_Lost')),
                'units_built=' .. string.format('%.0f', ReadStat(aiBrain, 'Units_History')),
                'units_lost=' .. string.format('%.0f', ReadStat(aiBrain, 'Units_Killed')),
                'units_killed=' .. string.format('%.0f', ReadStat(aiBrain, 'Enemies_Killed')),
                'time=' .. string.format('%.2f', GetGameTimeSeconds()),
            }, '|')

            BenchIO.Emit(message)
        end
    end
end

function CallEndGame(callEndGame, submitXMLStats)
    if callEndGame then
        local ok, err = pcall(EmitBenchmarkSummary)
        if not ok then
            BenchIO.Emit('*OVERMIND_BENCH_ERROR|phase=final_emit|message=' .. tostring(err))
        end
    end

    return OldCallEndGame(callEndGame, submitXMLStats)
end
