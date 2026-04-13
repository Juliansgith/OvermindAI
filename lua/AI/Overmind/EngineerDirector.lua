local LegacyPath = '/mods/OvermindAI/lua/AI/Overmind/EngineerDirectorLegacy.lua'
local ModularPath = '/mods/OvermindAI/lua/AI/Overmind/EngineerDirectorModular.lua'

local ActiveModule = false
local ActiveMode = false
local LastModularError = false

local function SetImplementation(aiBrain, runtime, mode, detail)
    ActiveMode = mode
    if runtime then
        runtime.EngineerDirectorImplementation = mode
        runtime.EngineerDirectorImplementationDetail = detail or mode
    end
    local logKey = tostring(mode) .. ':' .. tostring(detail or mode)
    if aiBrain and runtime and runtime.EngineerDirectorImplLogged ~= logKey then
        runtime.EngineerDirectorImplLogged = logKey
        LOG(string.format('*OVERMIND ENGDIR IMPL A%d mode=%s detail=%s',
            aiBrain:GetArmyIndex(),
            tostring(mode),
            tostring(detail or mode)))
    end
end

local function ResolveActiveModule(aiBrain, runtime)
    if ActiveModule then
        return ActiveModule
    end

    local okModular, modular = pcall(import, ModularPath)
    if okModular and type(modular) == 'table' and type(modular.Update) == 'function' then
        ActiveModule = modular
        SetImplementation(aiBrain, runtime, 'modular', 'primary')
        return ActiveModule
    end

    LastModularError = okModular and 'modular-missing-update' or tostring(modular)

    local okLegacy, legacy = pcall(import, LegacyPath)
    if okLegacy and type(legacy) == 'table' and type(legacy.Update) == 'function' then
        ActiveModule = legacy
        SetImplementation(aiBrain, runtime, 'legacy', LastModularError or 'fallback')
        return ActiveModule
    end

    error('EngineerDirector failed to resolve active module')
end

function Update(aiBrain, now)
    local runtime = aiBrain and aiBrain.OvermindRuntime or false
    local moduleRef = ResolveActiveModule(aiBrain, runtime)
    local ok, result = pcall(moduleRef.Update, aiBrain, now)
    if ok then
        return result
    end

    if ActiveMode == 'modular' then
        local okLegacy, legacy = pcall(import, LegacyPath)
        if okLegacy and type(legacy) == 'table' and type(legacy.Update) == 'function' then
            ActiveModule = legacy
            LastModularError = tostring(result)
            SetImplementation(aiBrain, runtime, 'legacy', 'runtime-fallback:' .. LastModularError)
            return legacy.Update(aiBrain, now)
        end
    end

    error(result)
end
