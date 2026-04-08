local OldLaunchSinglePlayerSession = LaunchSinglePlayerSession

local LobbyComm = import('/lua/ui/lobby/lobbyComm.lua')
local GameColors = import('/lua/gameColors.lua').GameColors
local BenchIO = import('/mods/OvermindAI/lua/AI/Overmind/BenchIO.lua')

local PersonalityAliases = {
    overmind = 'overmind',
    overmindcheat = 'overmindcheat',
    m27 = 'm27ai',
    m27ai = 'm27ai',
    m27aix = 'm27aicheat',
    m27aicheat = 'm27aicheat',
    m28 = 'm28ai',
    m28ai = 'm28ai',
    m28aix = 'm28aicheat',
    m28aicheat = 'm28aicheat',
    sorian = 'adaptive',
    rng = 'rngai',
    rngai = 'rngai',
}

local function IsBenchmarkMode()
    return BenchIO.BenchmarkMode()
end

local function ReadSingleArg(argName)
    return BenchIO.Arg(argName)
end

local function Trim(value)
    if not value then
        return ''
    end
    local v = string.gsub(value, '^%s+', '')
    v = string.gsub(v, '%s+$', '')
    return v
end

local function ParseBool(value, defaultValue)
    if value == nil then
        return defaultValue
    end

    local lower = string.lower(Trim(tostring(value)))
    if lower == '1' or lower == 'true' or lower == 'yes' or lower == 'on' then
        return true
    end

    if lower == '0' or lower == 'false' or lower == 'no' or lower == 'off' then
        return false
    end

    return defaultValue
end

local function ParseCsvArg(argName, fallbackCsv)
    local csv = ReadSingleArg(argName)
    if not csv or csv == '' then
        csv = fallbackCsv or ''
    end

    local values = {}
    for token in string.gmatch(csv, '([^,]+)') do
        local cleaned = Trim(token)
        if cleaned ~= '' then
            table.insert(values, cleaned)
        end
    end
    return values
end

local function BuildAvailablePersonalitySet()
    local available = {}
    local aiTypes = import('/lua/ui/lobby/aitypes.lua').aitypes or {}

    for _, entry in aiTypes do
        if entry and entry.key then
            available[string.lower(entry.key)] = true
        end
    end

    return available
end

local function ResolvePersonality(rawToken, available)
    local token = string.lower(Trim(rawToken or ''))
    if token == '' then
        return nil
    end

    local aliased = PersonalityAliases[token] or token
    if available[aliased] then
        return aliased
    end

    if available[token] then
        return token
    end

    return nil
end

local function PickFromList(values, index)
    if not values or table.getn(values) == 0 then
        return nil
    end
    local idx = math.mod(index - 1, table.getn(values)) + 1
    return values[idx]
end

local function ApplyBenchmarkOverrides(sessionInfo)
    if not sessionInfo or not sessionInfo.scenarioInfo then
        return
    end

    local standard = sessionInfo.scenarioInfo.Configurations
        and sessionInfo.scenarioInfo.Configurations.standard
    local armies = standard and standard.teams and standard.teams[1] and standard.teams[1].armies or {}
    local playerCount = table.getn(armies)

    if playerCount < 2 then
        BenchIO.Emit('*OVERMIND_BENCH_ERROR|phase=session_override|message=map_has_less_than_2_armies')
        return
    end

    local available = BuildAvailablePersonalitySet()
    local aiTokens = ParseCsvArg('/bench_ai', 'overmind,m27ai')
    local resolved = {}
    for _, token in aiTokens do
        local aiKey = ResolvePersonality(token, available)
        if aiKey then
            table.insert(resolved, aiKey)
        else
            BenchIO.Emit('*OVERMIND_BENCH_WARN|phase=session_override|message=unknown_ai_token|token=' .. tostring(token))
        end
    end

    if table.getn(resolved) == 0 then
        if available.overmind then
            table.insert(resolved, 'overmind')
        elseif available.adaptive then
            table.insert(resolved, 'adaptive')
        else
            table.insert(resolved, 'rush')
        end
    end

    local factionTokens = ParseCsvArg('/bench_faction', '')
    local cheatEnabled = ParseBool(ReadSingleArg('/bench_cheats'), false)
    local victory = string.lower(ReadSingleArg('/bench_victory') or 'demoralization')
    local unitCap = tonumber(ReadSingleArg('/bench_unitcap') or '')
    local numColors = table.getn(GameColors.PlayerColors or {})

    sessionInfo.teamInfo = sessionInfo.teamInfo or {}
    for i = 1, playerCount do
        local slot = sessionInfo.teamInfo[i]
        if not slot then
            slot = LobbyComm.GetDefaultPlayerOptions('BenchAI-' .. i)
        end

        local aiKey = PickFromList(resolved, i)
        local factionRaw = PickFromList(factionTokens, i)
        local faction = tonumber(factionRaw or '')

        slot.Human = false
        slot.Civilian = false
        slot.AIPersonality = aiKey
        slot.ArmyName = armies[i] or slot.ArmyName or ('ARMY_' .. i)
        slot.PlayerName = 'BenchAI-' .. i .. '-' .. aiKey
        slot.Team = i

        if faction and faction >= 1 and faction <= 4 then
            slot.Faction = faction
        end

        if numColors > 0 then
            slot.PlayerColor = math.mod(i, numColors)
            slot.ArmyColor = math.mod(i, numColors)
        end

        sessionInfo.teamInfo[i] = slot

        local setup = sessionInfo.scenarioInfo.ArmySetup
        if setup and setup[slot.ArmyName] then
            setup[slot.ArmyName].AIPersonality = aiKey
            setup[slot.ArmyName].Human = false
        end
    end

    local options = sessionInfo.scenarioInfo.Options or {}
    options.TeamSpawn = 'fixed'
    options.TeamLock = 'locked'
    options.Victory = victory
    options.CivilianAlliance = 'enemy'
    options.CheatsEnabled = cheatEnabled and 'true' or 'false'
    options.FogOfWar = options.FogOfWar or 'explored'
    options.PrebuiltUnits = options.PrebuiltUnits or 'Off'

    if unitCap then
        options.UnitCap = tostring(math.floor(unitCap))
    end

    sessionInfo.scenarioInfo.Options = options
    sessionInfo.createReplay = true

    local seed = tonumber(ReadSingleArg('/seed') or '')
    if seed then
        sessionInfo.RandomSeed = seed
    end

    BenchIO.Emit('*OVERMIND_BENCH_META|phase=session_override|players=' .. playerCount
        .. '|ais=' .. table.concat(resolved, ',')
        .. '|victory=' .. tostring(options.Victory)
        .. '|cheats=' .. tostring(options.CheatsEnabled))
end

function LaunchSinglePlayerSession(sessionInfo)
    if not OldLaunchSinglePlayerSession then
        return
    end

    if IsBenchmarkMode() then
        local ok, err = pcall(ApplyBenchmarkOverrides, sessionInfo)
        if not ok then
            BenchIO.Emit('*OVERMIND_BENCH_ERROR|phase=session_override|message=' .. tostring(err))
        end
    end

    return OldLaunchSinglePlayerSession(sessionInfo)
end

