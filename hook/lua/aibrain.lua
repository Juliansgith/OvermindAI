local OvermindBootstrap = import('/mods/OvermindAI/lua/AI/Overmind/Bootstrap.lua')

do
    local OvermindOldAIBrain = AIBrain

    AIBrain = Class(OvermindOldAIBrain) {
        OnCreateAI = function(self, planName)
            OvermindBootstrap.PreCreate(self)
            OvermindOldAIBrain.OnCreateAI(self, planName)
            OvermindBootstrap.PostCreate(self, planName)
        end,

        OnDefeat = function(self)
            OvermindBootstrap.OnDefeat(self)
            OvermindOldAIBrain.OnDefeat(self)
        end,
    }
end

