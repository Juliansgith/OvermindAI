-- Runtime-safe entrypoint. The modular refactor remains available in
-- EngineerDirectorModular.lua, but startup uses the stable legacy module
-- until the split import graph is validated end-to-end.
local Legacy = import('/mods/OvermindAI/lua/AI/Overmind/EngineerDirectorLegacy.lua')

local M = {}

function M.Update(aiBrain, now)
    return Legacy.Update(aiBrain, now)
end

return M
