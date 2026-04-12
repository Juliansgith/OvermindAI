local Common = import('/mods/OvermindAI/lua/AI/Overmind/EngineerDirector/Common.lua')
local Threat = import('/mods/OvermindAI/lua/AI/Overmind/EngineerDirector/Threat.lua')
local Policy = import('/mods/OvermindAI/lua/AI/Overmind/EngineerDirector/Policy.lua')
local Expansion = import('/mods/OvermindAI/lua/AI/Overmind/EngineerDirector/Expansion.lua')
local OvermindMemory = import('/mods/OvermindAI/lua/AI/Overmind/Memory.lua')

local FactoryCategory = categories.FACTORY * categories.STRUCTURE
local StructureCategory = categories.STRUCTURE - categories.FACTORY
local MexCategory = categories.STRUCTURE * categories.MASSEXTRACTION
local EnergyCategory = categories.STRUCTURE * categories.ENERGYPRODUCTION
local RadarCategory = categories.STRUCTURE * categories.RADAR
local AADefenseCategory = categories.STRUCTURE * categories.DEFENSE * categories.ANTIAIR
local DefenseCategory = categories.STRUCTURE * categories.DEFENSE


local M = {}

local function GetFactoryDomain(factory)
    if EntityCategoryContains(categories.FACTORY * categories.LAND, factory) then
        return 'Land'
    elseif EntityCategoryContains(categories.FACTORY * categories.AIR, factory) then
        return 'Air'
    elseif EntityCategoryContains(categories.FACTORY * categories.NAVAL, factory) then
        return 'Navy'
    end
    return 'Other'
end

local function GetStructureKind(structure)
    if EntityCategoryContains(MexCategory, structure) then
        return 'Mex'
    elseif EntityCategoryContains(EnergyCategory, structure) then
        return 'Power'
    elseif EntityCategoryContains(RadarCategory, structure) then
        return 'Radar'
    elseif EntityCategoryContains(AADefenseCategory, structure) then
        return 'AA'
    elseif EntityCategoryContains(DefenseCategory, structure) then
        return 'Defense'
    end
    return 'Structure'
end

local function CountReadyFactories(aiBrain, category)
    local units = aiBrain:GetListOfUnits(category, false, true) or {}
    local ready = 0
    for _, unit in units do
        if unit and not unit.Dead and Common.GetFraction(unit) >= 0.95 and not unit:IsUnitState('BeingBuilt') and not unit:IsUnitState('Upgrading') then
            ready = ready + 1
        end
    end
    return ready
end

local function ScoreStructureTarget(aiBrain, runtime, structure, kind, pos, fraction, mainPos)
    local eco = runtime.EcoState or {}
    local recovery = runtime.Recovery or {}
    local raid = runtime.RaidDefense or {}
    local constraints = ((runtime.ProductionDirector or {}).ConstraintState or {})
    local distMain = Common.Distance2D(pos, mainPos)
    local localThreat = aiBrain:GetThreatAtPosition(pos, 1, true, 'AntiSurface') or 0
    local engineerLossRisk = OvermindMemory.GetEngineerLossRisk(aiBrain, pos, 42)
    local expansionRisk = OvermindMemory.GetExpansionRisk(aiBrain, pos, 56)
    local bootstrapPowerNeed = Policy.NeedsBootstrapPower(aiBrain, runtime)
    local radarCritical = Policy.NeedsCriticalRadar(runtime)
    local starterPhase = ((runtime.ProductionDirector or {}).ConstraintState or {}).StarterPhase == true
    local bomberWatch, bomberPanic, exposedMexAirRaid = Threat.ComputeAirThreatFlags(runtime, GetGameTimeSeconds())
    local forceFinishPower = kind == 'Power'
        and fraction >= 0.8
        and (
            (eco.MassStorageRatio or 0) >= 0.12
            or (eco.MassTrend or 0) >= 0.02
            or (eco.EnergyStorageRatio or 0) <= 0.35
            or constraints.PowerBufferLow == true
        )

    local kindBias = 24
    if kind == 'Mex' then
        kindBias = 94
    elseif kind == 'Power' then
        kindBias = 78
    elseif kind == 'Radar' then
        kindBias = 60
    elseif kind == 'AA' then
        kindBias = 54
    elseif kind == 'Defense' then
        kindBias = 42
    end

    local score = kindBias + (fraction * 120) - (distMain * 0.16) - (localThreat * 18) - (engineerLossRisk * 18) - (expansionRisk * 10)
    if bootstrapPowerNeed then
        if kind == 'Power' then
            score = score + 120
        elseif kind == 'Mex' then
            score = score - 80
        elseif kind == 'Radar' or kind == 'AA' or kind == 'Defense' then
            score = score - 120
        end
    elseif radarCritical then
        if kind == 'Radar' then
            score = score + 220
        elseif kind == 'AA' or kind == 'Defense' then
            score = score - 90
        elseif kind == 'Mex' then
            score = score - 120
        end
    end
    if starterPhase and not bootstrapPowerNeed then
        if kind == 'Radar' and radarCritical then
            score = score + 140
        elseif kind == 'Mex' and radarCritical then
            score = score - 160
        end
    end
    if bomberWatch and not bomberPanic and not exposedMexAirRaid then
        if kind == 'Radar' then
            score = score + (radarCritical and 180 or 85)
        elseif kind == 'AA' then
            score = score + (radarCritical and 18 or 80)
        elseif kind == 'Power' then
            score = score + 24
        elseif kind == 'Mex' then
            score = score - (radarCritical and 170 or 55)
        elseif kind == 'Defense' then
            score = score - 25
        end
    end
    if distMain <= 135 then
        score = score + 12
    end
    if kind == 'Mex' and (eco.MassStorageRatio or 0) <= 0.12 then
        score = score + 18
    end
    if kind == 'Power' and (eco.EnergyStorageRatio or 0) <= 0.18 then
        score = score + 20
    end
    if forceFinishPower then
        score = score + 220 + (fraction * 40)
    end
    if kind == 'Radar' and ((runtime.IntelModel and runtime.IntelModel.StaleZones) or 0) >= 3 then
        score = score + 12
    end
    if (kind == 'AA' or kind == 'Defense') and recovery.ForceDefenseRecovery then
        score = score + 14
    end
    if bomberPanic or exposedMexAirRaid then
        if kind == 'AA' then
            score = score + 130
        elseif kind == 'Radar' then
            score = score + 55
        elseif kind == 'Power' then
            score = score + 18
        elseif kind == 'Mex' then
            score = score - 85
        elseif kind == 'Defense' then
            score = score - 30
        end
    end
    if exposedMexAirRaid and raid.ExposedMexThreatPos and Common.Distance2D(pos, raid.ExposedMexThreatPos) < 44 then
        if kind == 'AA' then
            score = score + 180
        elseif kind == 'Radar' then
            score = score + 70
        elseif kind == 'Mex' then
            score = score - 150
        elseif kind == 'Defense' then
            score = score - 40
        end
    end

    return score, localThreat
end

local function FindBestUnfinishedStructure(aiBrain, runtime, mainPos)
    local structures = aiBrain:GetListOfUnits(StructureCategory, false, true) or {}
    if table.getn(structures) <= 0 then
        return false, false, 1, 'none', 0
    end

    local best = false
    local bestPos = false
    local bestFraction = 1
    local bestKind = 'none'
    local bestPriority = 0
    local bestScore = -999999
    local safeExpandDistance = (runtime.EcoPolicy and runtime.EcoPolicy.SafeExpandDistance) or 680

    for _, structure in structures do
        if structure and not structure.Dead and not structure:IsUnitState('Upgrading') then
            local fraction = Common.GetFraction(structure)
            if fraction < 0.995 then
                local pos = structure.GetPosition and structure:GetPosition() or false
                if pos then
                    local distMain = Common.Distance2D(pos, mainPos)
                    local kind = GetStructureKind(structure)
                    local maxDist = (kind == 'Mex') and math.max(300, safeExpandDistance * 0.95) or 240
                    if distMain <= maxDist then
                        local score, threat = ScoreStructureTarget(aiBrain, runtime, structure, kind, pos, fraction, mainPos)
                        if threat <= ((kind == 'Mex') and 3.1 or 2.8) and score > bestScore then
                            best = structure
                            bestPos = pos
                            bestFraction = fraction
                            bestKind = kind
                            bestPriority = score
                            bestScore = score
                        end
                    end
                end
            end
        end
    end

    return best, bestPos, bestFraction, bestKind, bestPriority
end

local function FindBestUnfinishedFactory(aiBrain, runtime, mainPos)
    local factories = aiBrain:GetListOfUnits(FactoryCategory, false, true) or {}
    if table.getn(factories) <= 0 then
        return false, false, 1, 'none', 0
    end

    local readyLand = CountReadyFactories(aiBrain, categories.FACTORY * categories.LAND * categories.STRUCTURE)
    local readyAir = CountReadyFactories(aiBrain, categories.FACTORY * categories.AIR * categories.STRUCTURE)
    local readySea = CountReadyFactories(aiBrain, categories.FACTORY * categories.NAVAL * categories.STRUCTURE)

    local best = false
    local bestPos = false
    local bestFraction = 1
    local bestDomain = 'none'
    local bestReady = 0
    local bestScore = -999999
    for _, factory in factories do
        if factory and not factory.Dead then
            local fraction = Common.GetFraction(factory)
            if fraction < 0.95 and not factory:IsUnitState('Upgrading') then
                local pos = factory.GetPosition and factory:GetPosition() or false
                if pos then
                    local domain = GetFactoryDomain(factory)
                    local readyInDomain = 0
                    if domain == 'Land' then
                        readyInDomain = readyLand
                    elseif domain == 'Air' then
                        readyInDomain = readyAir
                    elseif domain == 'Navy' then
                        readyInDomain = readySea
                    end

                    local distMain = Common.Distance2D(pos, mainPos)
                    local score = (fraction * 150) - (distMain * 0.18)
                    if domain == 'Land' then
                        score = score + 10
                    end
                    if readyInDomain <= 0 then
                        score = score + 18
                    end
                    if distMain <= 130 then
                        score = score + 10
                    end
                    if runtime and runtime.Recovery and runtime.Recovery.ForceFactoryRecovery and domain == 'Land' then
                        score = score + 12
                    end
                    if score > bestScore then
                        best = factory
                        bestPos = pos
                        bestFraction = fraction
                        bestDomain = domain
                        bestReady = readyInDomain
                        bestScore = score
                    end
                end
            end
        end
    end

    return best, bestPos, bestFraction, bestDomain, bestReady
end

local function ResetFactoryTask(task)
    task.Active = false
    task.TargetId = false
    task.TargetPos = false
    task.TargetFraction = 1
    task.Domain = 'none'
    task.StallTime = 0
    task.ReadyFactories = 0
    task.RequiredBuilders = 0
    task.AssignedBuilders = 0
    task.BuilderIds = {}
    task.LastProgressTime = false
    task.UsedCommander = false
    task.CandidateDebug = false
end

local function ResetStructureTask(task)
    task.Active = false
    task.TargetId = false
    task.TargetPos = false
    task.TargetFraction = 1
    task.Kind = 'none'
    task.Priority = 0
    task.StickyUntil = -999
    task.StallTime = 0
    task.RequiredBuilders = 0
    task.AssignedBuilders = 0
    task.BuilderIds = {}
    task.LastProgressTime = false
    task.UsedCommander = false
    task.CandidateDebug = false
end

local function ComputeFactoryTaskRequirements(domain, fraction, stallTime, readyFactories, eco)
    local required = 1
    if domain == 'Land' and readyFactories <= 0 then
        required = required + 1
    end
    if domain == 'Land' and readyFactories <= 1 and fraction >= 0.15 then
        required = required + 1
    end
    if domain == 'Land' and readyFactories <= 1 and fraction >= 0.28 then
        required = required + 1
    end
    if fraction >= 0.4 then
        required = required + 1
    end
    if domain == 'Land' and fraction >= 0.6 then
        required = required + 1
    end
    if stallTime >= 8 then
        required = required + 1
    end
    if domain == 'Land' and stallTime >= 18 then
        required = required + 1
    end
    if (eco.MassStorageRatio or 0) <= 0.02 and required > 2 and readyFactories > 0 then
        required = required - 1
    end
    if domain == 'Land' then
        return Common.Clamp(required, 2, 4)
    end
    return Common.Clamp(required, 1, 4)
end

local function PickPowerBlueprint(builder)
    if not builder or builder.Dead then
        return false
    end

    local bps = EntityCategoryGetUnitList(categories.STRUCTURE * categories.ENERGYPRODUCTION * categories.TECH1)
    if not bps or table.getn(bps) <= 0 then
        return false
    end

    for _, bp in bps do
        if bp and builder:CanBuild(bp) then
            return bp
        end
    end

    return false
end

local PowerBuildOffsets = {
    { 18, 0 }, { -18, 0 }, { 0, 18 }, { 0, -18 },
    { 28, 12 }, { -28, 12 }, { 12, -28 }, { -12, -28 },
    { 36, 0 }, { -36, 0 }, { 0, 36 }, { 0, -36 },
}

local function GetFactoryAnchor(aiBrain, mainPos)
    local factories = aiBrain:GetListOfUnits(categories.FACTORY * categories.LAND * categories.STRUCTURE, false, true) or {}
    local best = mainPos
    local bestDist = 999999
    for _, unit in factories do
        if unit and not unit.Dead and Common.GetFraction(unit) >= 0.95 and not unit:IsUnitState('BeingBuilt') then
            local pos = unit.GetPosition and unit:GetPosition() or false
            if pos then
                local dist = Common.Distance2D(pos, mainPos)
                if dist < bestDist then
                    best = pos
                    bestDist = dist
                end
            end
        end
    end
    return best
end

local function FindPowerBuildPos(aiBrain, anchorPos)
    if not aiBrain or not anchorPos then
        return false
    end

    for _, offset in PowerBuildOffsets do
        local pos = { (anchorPos[1] or 0) + offset[1], 0, (anchorPos[3] or 0) + offset[2] }
        local powerNearby = aiBrain:GetNumUnitsAroundPoint(EnergyCategory, pos, 8, 'Ally') or 0
        local factoryNearby = aiBrain:GetNumUnitsAroundPoint(categories.FACTORY * categories.STRUCTURE, pos, 6, 'Ally') or 0
        if powerNearby <= 0 and factoryNearby <= 0 and not Threat.HasEnemyCombatNear(aiBrain, pos, 34) then
            return pos
        end
    end

    return false
end

local function CountNearbyUnfinishedPower(aiBrain, mainPos, radius)
    local units = aiBrain:GetListOfUnits(EnergyCategory, false, true) or {}
    local count = 0
    for _, unit in units do
        if unit and not unit.Dead then
            local pos = unit.GetPosition and unit:GetPosition() or false
            if pos and Common.Distance2D(pos, mainPos) <= (radius or 180) and Common.GetFraction(unit) < 0.995 and not unit:IsUnitState('Upgrading') then
                count = count + 1
            end
        end
    end
    return count
end

local function GetPriorityPowerRecoveryTarget(aiBrain, runtime, mainPos, structureTargetObject, structureTask)
    if not aiBrain or not mainPos then
        return false
    end

    if structureTask and structureTask.Active and structureTask.Kind == 'Power' and structureTargetObject and not structureTargetObject.Dead then
        return structureTargetObject
    end

    local best = false
    local bestScore = -999999
    local units = aiBrain:GetListOfUnits(EnergyCategory, false, true) or {}
    for _, unit in units do
        if unit and not unit.Dead and not unit:IsUnitState('Upgrading') then
            local pos = unit.GetPosition and unit:GetPosition() or false
            if pos then
                local dist = Common.Distance2D(pos, mainPos)
                if dist <= 220 then
                    local fraction = Common.GetFraction(unit)
                    local health = unit.GetHealth and unit:GetHealth() or 0
                    local maxHealth = unit.GetMaxHealth and unit:GetMaxHealth() or 0
                    local score = -999999
                    if fraction < 0.995 then
                        score = 320 + (fraction * 140) - dist
                    elseif maxHealth > 0 and health > 0 and health < (maxHealth * 0.92) then
                        score = 220 + ((1 - (health / maxHealth)) * 180) - dist
                    end
                    if score > bestScore then
                        bestScore = score
                        best = unit
                    end
                end
            end
        end
    end

    return best
end

local function GetPriorityMexRecoveryTarget(aiBrain, runtime, mainPos, structureTargetObject, structureTask)
    if not aiBrain or not mainPos then
        return false
    end

    if structureTask and structureTask.Active and structureTask.Kind == 'Mex' and structureTargetObject and not structureTargetObject.Dead then
        return structureTargetObject
    end

    local best = false
    local bestScore = -999999
    local units = aiBrain:GetListOfUnits(MexCategory, false, true) or {}
    for _, unit in units do
        if unit and not unit.Dead and not unit:IsUnitState('Upgrading') then
            local pos = unit.GetPosition and unit:GetPosition() or false
            if pos then
                local dist = Common.Distance2D(pos, mainPos)
                if dist <= 520 then
                    local fraction = Common.GetFraction(unit)
                    if fraction < 0.995 then
                        local threat = aiBrain:GetThreatAtPosition(pos, 1, true, 'AntiSurface') or 0
                        if threat <= 2.8 then
                            local score = 300 + (fraction * 180) - (dist * 0.18)
                            if fraction >= 0.35 then
                                score = score + 120
                            end
                            if fraction >= 0.7 then
                                score = score + 140
                            end
                            if score > bestScore then
                                bestScore = score
                                best = unit
                            end
                        end
                    end
                end
            end
        end
    end

    return best
end

local function ShouldForceFinishEcoStructure(aiBrain, runtime, mainPos, structureTargetObject, structureTask)
    local powerTarget = GetPriorityPowerRecoveryTarget(aiBrain, runtime, mainPos, structureTargetObject, structureTask)
    local mexTarget = GetPriorityMexRecoveryTarget(aiBrain, runtime, mainPos, structureTargetObject, structureTask)
    local eco = runtime and runtime.EcoState or {}
    local constraints = (((runtime or {}).ProductionDirector or {}).ConstraintState or {})
    local bootstrapPowerNeed = Policy.NeedsBootstrapPower(aiBrain, runtime)
    local bestTarget = false
    local bestKind = false
    local bestScore = -999999

    if powerTarget and not powerTarget.Dead then
        local fraction = Common.GetFraction(powerTarget)
        local score = (bootstrapPowerNeed and 1000 or 0)
            + ((constraints.PowerBufferLow == true) and 700 or 0)
            + 500
            + (fraction * 300)
            + ((fraction >= 0.35) and 180 or 0)
        if score > bestScore then
            bestScore = score
            bestTarget = powerTarget
            bestKind = 'Power'
        end
    end

    if mexTarget and not mexTarget.Dead then
        local fraction = Common.GetFraction(mexTarget)
        local score = 420
            + (fraction * 260)
            + ((fraction >= 0.35) and 180 or 0)
            + ((fraction >= 0.7) and 120 or 0)
            + (((eco.MassStorageRatio or 0) <= 0.18) and 120 or 0)
        if score > bestScore then
            bestScore = score
            bestTarget = mexTarget
            bestKind = 'Mex'
        end
    end

    return bestTarget ~= false, bestTarget, bestKind
end

local function TryOpenPowerRecoveryBuild(aiBrain, runtime, eng, mainPos, now)
    if not eng or eng.Dead or not mainPos or not IssueBuildMobile then
        return false
    end

    if now < ((runtime.LastPowerRecoveryIssueTime or -999) + 8) then
        return false
    end
    if CountNearbyUnfinishedPower(aiBrain, mainPos, 260) >= 1 then
        return false
    end

    local bp = PickPowerBlueprint(eng)
    local anchor = bp and GetFactoryAnchor(aiBrain, mainPos) or false
    local buildPos = bp and anchor and FindPowerBuildPos(aiBrain, anchor) or false
    if not bp or not buildPos then
        return false
    end

    IssueBuildMobile({ eng }, buildPos, bp, {})
    runtime.LastPowerRecoveryIssueTime = now
    runtime.LastPowerRecoveryPos = buildPos
    return true
end

local function ShouldScaleBaseEco(runtime, now)
    local director = runtime and runtime.ProductionDirector or {}
    local constraints = director.ConstraintState or {}
    local current = director.Current or {}
    local eco = runtime and runtime.EcoState or {}
    local factories = current.Factories or {}
    local readyLand = ((factories.Land or {}).Ready) or 0
    local powerReady = (((current.Eco or {}).Power or {}).Ready) or 0
    local mexReady = (((current.Eco or {}).Mex or {}).Ready) or 0

    if now < 240 or constraints.EcoCrash or constraints.QueueStarved or constraints.CriticalFactory or constraints.CriticalStructure then
        return false
    end
    if readyLand < 3 or mexReady < 5 then
        return false
    end
    if (eco.MassStorageRatio or 0) < 0.14 or (eco.MassTrend or 0) < -0.12 then
        return false
    end
    if (eco.EnergyStorageRatio or 0) >= 0.72 and powerReady >= (mexReady + 1) then
        return false
    end
    return powerReady <= mexReady or (eco.EnergyStorageRatio or 0) < 0.52 or (eco.EnergyTrend or 0) < 10
end

local function CountUnfinishedMexes(aiBrain, mainPos, radius)
    local units = aiBrain:GetListOfUnits(MexCategory, false, true) or {}
    local count = 0
    for _, unit in units do
        if unit and not unit.Dead and not unit:IsUnitState('Upgrading') and Common.GetFraction(unit) < 0.995 then
            local pos = unit.GetPosition and unit:GetPosition() or false
            if pos and (not mainPos or Common.Distance2D(pos, mainPos) <= (radius or 520)) then
                count = count + 1
            end
        end
    end
    return count
end

local function ShouldPersistentSurplusSpend(runtime, now)
    local macro = runtime and runtime.MacroController or {}
    local phase = macro.Phase or (((runtime and runtime.ProductionDirector) or {}).MacroObjective) or 'land_factory_floor'
    if phase ~= 'surplus_scale' then
        return false
    end
    local director = runtime and runtime.ProductionDirector or {}
    local constraints = director.ConstraintState or {}
    local current = director.Current or {}
    local eco = runtime and runtime.EcoState or {}
    local factories = current.Factories or {}
    local readyLand = ((factories.Land or {}).Ready) or 0
    local totalLand = ((factories.Land or {}).Total) or 0
    local powerReady = (((current.Eco or {}).Power or {}).Ready) or 0
    local mexReady = (((current.Eco or {}).Mex or {}).Ready) or 0

    if now < 210 or constraints.EcoCrash or constraints.QueueStarved or constraints.CriticalStructure then
        return false
    end
    if constraints.CriticalFactory and not (readyLand >= 4 and totalLand <= readyLand and powerReady >= 4) then
        return false
    end
    if constraints.LandPanic or constraints.AirPanic then
        return false
    end
    if readyLand < 3 or mexReady < 5 then
        return false
    end
    if (eco.MassStorageRatio or 0) < 0.12 or (eco.MassTrend or 0) < -0.08 then
        return false
    end
    if (eco.EnergyStorageRatio or 0) < 0.08 or (eco.EnergyTrend or 0) < -12 then
        return false
    end
    return true
end

local function TryOpenSurplusExpansionBuild(aiBrain, runtime, eng, mainPos, enemyPos, safeExpandDistance, now)
    if not eng or eng.Dead or not mainPos or not IssueBuildMobile then
        return false
    end
    if now < ((runtime.LastSurplusExpansionIssueTime or -999) + 10) then
        return false
    end
    if CountUnfinishedMexes(aiBrain, mainPos, math.max(520, safeExpandDistance)) >= 1 then
        return false
    end

    local engineerId = Common.GetEntityId(eng)
    local pos = eng.GetPosition and eng:GetPosition() or false
    local sourcePos = pos and { pos[1], pos[2] or 0, pos[3], EngineerId = engineerId } or false
    local target = Expansion.FindExpansionTarget(aiBrain, runtime, mainPos, enemyPos, math.max(520, safeExpandDistance), 1.7, now, sourcePos)
    if not target then
        target = Expansion.FindExpansionTarget(aiBrain, runtime, mainPos, enemyPos, math.max(600, safeExpandDistance + 80), 1.95, now, sourcePos)
    end
    if not target then
        return false
    end

    local bp = Expansion.PickMexBlueprint(eng)
    if not bp then
        return false
    end

    Expansion.ReserveExpansionTarget(runtime, now, target, engineerId)
    IssueBuildMobile({ eng }, target, bp, {})
    runtime.LastSurplusExpansionIssueTime = now
    runtime.LastSurplusExpansionPos = target
    return true
end

local function ComputeStructureTaskRequirements(kind, fraction, stallTime, eco)
    local required = 1
    if kind == 'Mex' then
        if fraction >= 0.25 then
            required = required + 1
        end
        if (eco.MassStorageRatio or 0) <= 0.08 then
            required = required + 1
        end
    elseif kind == 'Power' then
        if (eco.EnergyStorageRatio or 0) <= 0.2 then
            required = required + 1
        end
        if fraction >= 0.55 then
            required = required + 1
        end
    elseif kind == 'Radar' then
        if stallTime >= 18 then
            required = required + 1
        end
    elseif kind == 'AA' or kind == 'Defense' then
        if fraction >= 0.45 then
            required = required + 1
        end
    end
    if stallTime >= 24 then
        required = required + 1
    end
    return Common.Clamp(required, 1, 3)
end

local function FindTrackedUnfinishedStructure(aiBrain, task)
    if not aiBrain or not task or (not task.TargetId and not task.TargetPos) then
        return false
    end

    local structures = aiBrain:GetListOfUnits(StructureCategory, false, true) or {}
    local fallback = false
    local fallbackPos = false
    local fallbackFraction = 1
    local fallbackKind = 'Structure'
    local fallbackPriority = 0

    for _, structure in structures do
        if structure and not structure.Dead and structure:IsUnitState('BeingBuilt') then
            local pos = structure:GetPosition()
            if pos then
                local fraction = Common.GetFraction(structure)
                if fraction < 0.995 then
                    local entityId = Common.GetEntityId(structure)
                    local kind = GetStructureKind(structure)
                    local priority = 0
                    if kind == 'Mex' then
                        priority = 5
                    elseif kind == 'Power' then
                        priority = 4
                    elseif kind == 'Radar' then
                        priority = 6
                    elseif kind == 'AA' then
                        priority = 3
                    elseif kind == 'Defense' then
                        priority = 2
                    else
                        priority = 1
                    end

                    if task.TargetId and entityId == task.TargetId then
                        return structure, pos, fraction, kind, priority
                    end

                    if task.TargetPos and not fallback and Common.Distance2D(pos, task.TargetPos) <= 8 then
                        fallback = structure
                        fallbackPos = pos
                        fallbackFraction = fraction
                        fallbackKind = kind
                        fallbackPriority = priority
                    end
                end
            end
        end
    end

    return fallback, fallbackPos, fallbackFraction, fallbackKind, fallbackPriority
end

local function ShouldKeepTrackedStructureTask(now, task, trackedTargetId, trackedKind, trackedFraction, trackedPriority, bestTargetId, bestKind, bestPriority, radarCritical)
    if not trackedTargetId then
        return false
    end

    if not bestTargetId or trackedTargetId == bestTargetId then
        return true
    end

    local assigned = task.AssignedBuilders or 0
    local stickyUntil = task.StickyUntil or -999
    local keep = false
    local trackedLower = string.lower(trackedKind or 'none')
    local bestLower = string.lower(bestKind or 'none')

    if now < stickyUntil then
        keep = true
    end

    if assigned > 0 and trackedFraction >= 0.35 then
        keep = true
    end

    if trackedKind == 'Mex' and trackedFraction >= 0.55 then
        keep = true
    elseif trackedKind == 'Power' and trackedFraction >= 0.55 then
        keep = true
    elseif trackedKind == 'Radar' and trackedFraction >= 0.35 then
        keep = true
    elseif (trackedLower == 'aa' or trackedLower == 'defense') and trackedFraction >= 0.2 then
        keep = true
    elseif trackedLower == 'structure' and trackedFraction >= 0.5 then
        keep = true
    end
    if trackedKind == 'Power' and trackedFraction >= 0.8 then
        keep = true
    end
    if assigned <= 0 and trackedFraction >= 0.72 then
        keep = true
    end

    local preemptMargin = 85
    if bestLower == 'radar' and radarCritical then
        preemptMargin = 140
    end
    if trackedKind == 'Mex' and trackedFraction >= 0.55 then
        preemptMargin = preemptMargin + 120
    elseif trackedKind == 'Power' and trackedFraction >= 0.55 then
        preemptMargin = preemptMargin + 100
    elseif trackedKind == 'Radar' and trackedFraction >= 0.35 then
        preemptMargin = preemptMargin + 80
    elseif (trackedLower == 'aa' or trackedLower == 'defense') and trackedFraction >= 0.2 then
        preemptMargin = preemptMargin + 115
    elseif trackedLower == 'structure' and trackedFraction >= 0.5 then
        preemptMargin = preemptMargin + 140
    end
    if trackedKind == 'Power' and trackedFraction >= 0.8 then
        preemptMargin = preemptMargin + 180
    end
    if assigned <= 0 and trackedFraction >= 0.72 then
        preemptMargin = preemptMargin + 120
    end

    if bestPriority > (trackedPriority + preemptMargin) then
        keep = false
    end

    return keep
end


M.GetFactoryDomain = GetFactoryDomain
M.GetStructureKind = GetStructureKind
M.CountReadyFactories = CountReadyFactories
M.ScoreStructureTarget = ScoreStructureTarget
M.FindBestUnfinishedStructure = FindBestUnfinishedStructure
M.FindBestUnfinishedFactory = FindBestUnfinishedFactory
M.ResetFactoryTask = ResetFactoryTask
M.ResetStructureTask = ResetStructureTask
M.ComputeFactoryTaskRequirements = ComputeFactoryTaskRequirements
M.PickPowerBlueprint = PickPowerBlueprint
M.GetFactoryAnchor = GetFactoryAnchor
M.FindPowerBuildPos = FindPowerBuildPos
M.CountNearbyUnfinishedPower = CountNearbyUnfinishedPower
M.GetPriorityPowerRecoveryTarget = GetPriorityPowerRecoveryTarget
M.GetPriorityMexRecoveryTarget = GetPriorityMexRecoveryTarget
M.ShouldForceFinishEcoStructure = ShouldForceFinishEcoStructure
M.TryOpenPowerRecoveryBuild = TryOpenPowerRecoveryBuild
M.ShouldScaleBaseEco = ShouldScaleBaseEco
M.CountUnfinishedMexes = CountUnfinishedMexes
M.ShouldPersistentSurplusSpend = ShouldPersistentSurplusSpend
M.TryOpenSurplusExpansionBuild = TryOpenSurplusExpansionBuild
M.ComputeStructureTaskRequirements = ComputeStructureTaskRequirements
M.FindTrackedUnfinishedStructure = FindTrackedUnfinishedStructure
M.ShouldKeepTrackedStructureTask = ShouldKeepTrackedStructureTask
M.NeedsBootstrapPower = Policy.NeedsBootstrapPower
M.NeedsCriticalRadar = Policy.NeedsCriticalRadar
M.GetRadarReservedBuilderIds = Policy.GetRadarReservedBuilderIds
return M

