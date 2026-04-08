local OvermindMemory = import('/mods/OvermindAI/lua/AI/Overmind/Memory.lua')

do
    local OvermindOldUnit = Unit

    Unit = Class(OvermindOldUnit) {
        OnKilled = function(self, instigator, type, overkillRatio)
            if self.GetAIBrain then
                local brain = self:GetAIBrain()
                if brain and brain.OvermindAI then
                    OvermindMemory.RecordLoss(brain, self, instigator)
                end
            end

            if OvermindOldUnit.OnKilled then
                OvermindOldUnit.OnKilled(self, instigator, type, overkillRatio)
            end
        end,

        OnKilledUnit = function(self, unitKilled, massKilled)
            if unitKilled and self.GetAIBrain then
                local brain = self:GetAIBrain()
                if brain and brain.OvermindAI then
                    OvermindMemory.RecordKill(brain, unitKilled, self)
                end
            end

            if OvermindOldUnit.OnKilledUnit then
                OvermindOldUnit.OnKilledUnit(self, unitKilled, massKilled)
            end
        end,

        OnStopBuild = function(self, unit)
            if unit and not unit.Dead and unit.GetFractionComplete and unit:GetFractionComplete() == 1 and self.GetAIBrain then
                local brain = self:GetAIBrain()
                if brain and brain.OvermindAI then
                    OvermindMemory.RecordBuildComplete(brain, self, unit)
                end
            end

            if OvermindOldUnit.OnStopBuild then
                return OvermindOldUnit.OnStopBuild(self, unit)
            end
        end,

        OnStopReclaim = function(self, target)
            if self.GetAIBrain then
                local brain = self:GetAIBrain()
                if brain and brain.OvermindAI then
                    OvermindMemory.RecordReclaim(brain, self, target)
                end
            end

            if OvermindOldUnit.OnStopReclaim then
                return OvermindOldUnit.OnStopReclaim(self, target)
            end
        end,
    }
end
