local ProductionDirector = import('/mods/OvermindAI/lua/AI/Overmind/ProductionDirector.lua')

local Module = {
    Name = 'T1DirectorCompat',
    StateSlice = 'ProductionDirector',
    CompatibilityOnly = true,
}

function Module.Update(aiBrain, now)
    return ProductionDirector.Update(aiBrain, now)
end

function Update(aiBrain, now)
    return Module.Update(aiBrain, now)
end

return Module
