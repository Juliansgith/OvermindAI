local ForceDirector = import('/mods/OvermindAI/lua/AI/Overmind/ForceDirector.lua')

local Module = {
    Name = 'ForceManagerCompat',
    StateSlice = 'ForceDirector',
    CompatibilityOnly = true,
}

function Module.Update(aiBrain, now)
    return ForceDirector.Update(aiBrain, now)
end

function Update(aiBrain, now)
    return Module.Update(aiBrain, now)
end

return Module
