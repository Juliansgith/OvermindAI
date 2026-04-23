local OvermindMemory = import('/mods/OvermindAI/lua/AI/Overmind/Memory.lua')
local T1AAStructureCategory = categories.STRUCTURE * categories.DEFENSE * categories.ANTIAIR * categories.TECH1
local T1PDStructureCategory = categories.STRUCTURE * categories.DEFENSE * categories.DIRECTFIRE * categories.TECH1
local BuilderCategory = categories.ENGINEER * categories.MOBILE + categories.COMMAND
local Module = {}

local BuildOffsets = {
    { 10, 0 },
    { -10, 0 },
    { 0, 10 },
    { 0, -10 },
    { 14, 8 },
    { -14, 8 },
    { 8, -14 },
    { -8, -14 },
}

local function Distance2D(a, b)
    local dx = (a[1] or 0) - (b[1] or 0)
    local dz = (a[3] or 0) - (b[3] or 0)
    return math.sqrt((dx * dx) + (dz * dz))
end

local function Normalize2D(dx, dz)
    local mag = math.sqrt((dx * dx) + (dz * dz))
    if mag <= 0.01 then
        return 1, 0
    end
    return dx / mag, dz / mag
end

local function GetMainPos(aiBrain, runtime)
    if runtime and runtime.OwnMainPos then
        return runtime.OwnMainPos
    end
    if aiBrain.BuilderManagers and aiBrain.BuilderManagers.MAIN and aiBrain.BuilderManagers.MAIN.Position then
        return aiBrain.BuilderManagers.MAIN.Position
    end
    local sx, sz = aiBrain:GetArmyStartPos()
    return { sx, 0, sz }
end

local function PickBlueprint(builder, needAA)
    if not builder then
        return false
    end

    local cat = needAA and T1AAStructureCategory or T1PDStructureCategory
    local options = EntityCategoryGetUnitList(cat)
    if not options then
        return false
    end

    for _, bp in options do
        if bp and builder:CanBuild(bp) then
            return bp
        end
    end

    return false
end

local function PickBuilder(aiBrain, targetPos, bp)
    local builders = aiBrain:GetListOfUnits(BuilderCategory, false, true)
    if not builders then
        return false
    end

    local bestIdle = false
    local bestIdleDist = 999999
    local bestBusy = false
    local bestBusyDist = 999999

    for _, unit in builders do
        if unit and not unit.Dead and unit:CanBuild(bp) then
            local pos = unit:GetPosition()
            if pos then
                local dist = Distance2D(pos, targetPos)
                if dist <= 180 then
                    local q = unit.GetCommandQueue and unit:GetCommandQueue() or false
                    local qLen = q and table.getn(q) or 0
                    local isBusy = qLen > 0 or unit:IsUnitState('Building') or unit:IsUnitState('Upgrading')
                    if not isBusy then
                        if dist < bestIdleDist then
                            bestIdleDist = dist
                            bestIdle = unit
                        end
                    elseif qLen <= 1 and dist < bestBusyDist then
                        bestBusyDist = dist
                        bestBusy = unit
                    end
                end
            end
        end
    end

    if bestIdle then
        return bestIdle, false
    end
    if bestBusy then
        return bestBusy, true
    end
    return false, false
end

local function BuildPerimeterOffsets(anchorPos, facingPos)
    if not anchorPos or not facingPos then
        return false
    end

    local dirX, dirZ = Normalize2D((facingPos[1] or 0) - (anchorPos[1] or 0), (facingPos[3] or 0) - (anchorPos[3] or 0))
    local perpX, perpZ = -dirZ, dirX
    local offsets = {}

    for _, distance in { 30, 36, 42 } do
        for _, lateral in { 0, 10, -10, 18, -18 } do
            table.insert(offsets, { (dirX * distance) + (perpX * lateral), (dirZ * distance) + (perpZ * lateral) })
        end
    end

    return offsets
end

local function ResolveBaseFacingPos(runtime, raid, mainPos)
    if raid and raid.LastThreatMexPos and (raid.UnderLandHarass or raid.UnderAirHarass) then
        return raid.LastThreatMexPos
    end
    if raid and raid.ExposedMexThreatPos then
        return raid.ExposedMexThreatPos
    end

    local cluster = runtime and runtime.EnemyClusterTracker or {}
    local approach = cluster and cluster.ApproachCluster or {}
    if approach and approach.Pos and (((approach.ConfirmedUnits or 0) > 0) or ((approach.TotalThreat or 0) >= 4.5)) then
        return approach.Pos
    end

    if runtime and runtime.PrimaryEnemyPos then
        return runtime.PrimaryEnemyPos
    end

    return mainPos and { (mainPos[1] or 0) + 36, 0, (mainPos[3] or 0) } or false
end

local function FindBuildPos(aiBrain, mexPos, category, facingPos)
    local offsetSets = {}
    local perimeterOffsets = BuildPerimeterOffsets(mexPos, facingPos)
    if perimeterOffsets then
        table.insert(offsetSets, perimeterOffsets)
    end
    table.insert(offsetSets, BuildOffsets)

    for _, offsets in offsetSets do
        for _, offset in offsets do
            local pos = { (mexPos[1] or 0) + offset[1], 0, (mexPos[3] or 0) + offset[2] }
            local nearby = aiBrain:GetNumUnitsAroundPoint(category, pos, 7, 'Ally') or 0
            local mexHere = aiBrain:GetNumUnitsAroundPoint(categories.STRUCTURE * categories.MASSEXTRACTION, pos, 5, 'Ally') or 0
            if nearby <= 0 and mexHere <= 0 then
                return pos
            end
        end
    end

    if perimeterOffsets and perimeterOffsets[1] then
        return { (mexPos[1] or 0) + perimeterOffsets[1][1], 0, (mexPos[3] or 0) + perimeterOffsets[1][2] }
    end
    return { (mexPos[1] or 0) + 10, 0, (mexPos[3] or 0) }
end

local function FindThreatenedMex(aiBrain, runtime, mainPos)
    local mexes = aiBrain:GetListOfUnits(categories.STRUCTURE * categories.MASSEXTRACTION, false, true) or {}
    local bestPos = false
    local bestNeedAA = false
    local bestScore = -999999

    for _, mex in mexes do
        if mex and not mex.Dead and mex.GetPosition then
            local pos = mex:GetPosition()
            if pos then
                local enemyLand = aiBrain:GetNumUnitsAroundPoint(categories.MOBILE * categories.LAND - categories.ENGINEER - categories.SCOUT, pos, 24, 'Enemy') or 0
                local enemyAir = aiBrain:GetNumUnitsAroundPoint(categories.MOBILE * categories.AIR - categories.SCOUT - categories.TRANSPORTATION, pos, 32, 'Enemy') or 0
                if enemyLand > 0 or enemyAir > 0 then
                    local tech = EntityCategoryContains(categories.TECH3, mex) and 3 or (EntityCategoryContains(categories.TECH2, mex) and 2 or 1)
                    local distMain = mainPos and Distance2D(mainPos, pos) or 999
                    local aaCount = aiBrain:GetNumUnitsAroundPoint(T1AAStructureCategory, pos, 18, 'Ally') or 0
                    local pdCount = aiBrain:GetNumUnitsAroundPoint(T1PDStructureCategory, pos, 18, 'Ally') or 0
                    local needAA = enemyAir > 0 or (enemyLand > 0 and aaCount <= 0 and tech >= 2)
                    local stillExposed = (needAA and aaCount < 1) or ((not needAA) and pdCount < 1)
                    if stillExposed then
                        local score = (enemyLand * 70) + (enemyAir * 90) + (tech * 85) - (distMain * 0.12)
                        if mex:IsUnitState('Upgrading') then
                            score = score + 140
                        end
                        if distMain <= 180 then
                            score = score + 90
                        elseif distMain <= 260 then
                            score = score + 35
                        end
                        if score > bestScore then
                            bestScore = score
                            bestPos = pos
                            bestNeedAA = needAA
                        end
                    end
                end
            end
        end
    end

    return bestPos, bestNeedAA, bestScore
end

local function FindExposedMexForPreemptiveAA(aiBrain, mainPos)
    local mexes = aiBrain:GetListOfUnits(categories.STRUCTURE * categories.MASSEXTRACTION, false, true) or {}
    local bestPos = false
    local bestScore = -999999

    for _, mex in mexes do
        if mex and not mex.Dead and mex.GetPosition then
            local pos = mex:GetPosition()
            if pos then
                local aaCount = aiBrain:GetNumUnitsAroundPoint(T1AAStructureCategory, pos, 18, 'Ally') or 0
                if aaCount <= 0 then
                    local distMain = mainPos and Distance2D(mainPos, pos) or 999
                    local enemyAir = aiBrain:GetNumUnitsAroundPoint(categories.MOBILE * categories.AIR - categories.SCOUT - categories.TRANSPORTATION, pos, 38, 'Enemy') or 0
                    local enemyLand = aiBrain:GetNumUnitsAroundPoint(categories.MOBILE * categories.LAND - categories.ENGINEER - categories.SCOUT, pos, 28, 'Enemy') or 0
                    if distMain >= 80 and distMain <= 420 and enemyLand <= 4 then
                        local tech = EntityCategoryContains(categories.TECH3, mex) and 3 or (EntityCategoryContains(categories.TECH2, mex) and 2 or 1)
                        local score = (tech * 150) + math.min(180, distMain) - (enemyLand * 35) + (enemyAir * 20)
                        if mex:IsUnitState('Upgrading') then
                            score = score + 120
                        end
                        if score > bestScore then
                            bestScore = score
                            bestPos = pos
                        end
                    end
                end
            end
        end
    end

    return bestPos, bestScore
end

function Module.Update(aiBrain, now)
    local runtime = aiBrain.OvermindRuntime
    if not runtime then
        return
    end

    local state = runtime.MexDefense or {
        NextTry = -999,
        LastLog = -999,
        LastPreemptiveAATry = -999,
    }
    runtime.MexDefense = state

    if now < (state.NextTry or -999) then
        return
    end

    local raid = runtime.RaidDefense or {}
    local prod = runtime.ProductionDirector or {}
    local structurePlan = prod.StructurePlan or {}
    local current = prod.Current or {}
    local constraints = prod.ConstraintState or {}
    local powerReady = (((current.Eco or {}).Power or {}).Ready) or 0
    local radarCritical = structurePlan.RadarCritical == true
    local desiredExposedMexAA = structurePlan.ExposedMexAA or 0
    local exposedMexAirRaid = raid.ExposedMexUnderAirRaid == true and raid.ExposedMexThreatPos ~= false
    local bomberWatch = constraints.BomberWatch == true or ((raid.LastBomberEnemyCount or 0) >= 1 and not raid.UnderAirHarass)
    local bomberPanic = ((raid.BomberPanicUntil or -999) > now) or ((raid.LastBomberEnemyCount or 0) >= 1 and raid.UnderAirHarass)
    local threatPos = raid.LastThreatMexPos
    local buildPosBase = false
    local chooseAA = false
    local targetIsBase = false

    local eco = runtime.EcoState or {}
    if (eco.MassStorageRatio or 0) <= 0.01 and (eco.EnergyStorageRatio or 0) <= 0.01 and (eco.MassTrend or 0) < -0.55 then
        state.NextTry = now + 10
        return
    end

    local mainPos = GetMainPos(aiBrain, runtime)
    local threatenedMexPos, threatenedMexNeedAA = FindThreatenedMex(aiBrain, runtime, mainPos)
    if threatenedMexPos then
        chooseAA = threatenedMexNeedAA
        buildPosBase = threatenedMexPos
    end

    local useMexThreat = threatPos
        and raid.LastThreatLabel == 'mex'
        and (raid.UnderLandHarass or raid.UnderAirHarass)
    if not buildPosBase and useMexThreat then
        local needAA = raid.UnderAirHarass or (raid.LastBomberEnemyCount or 0) >= 1
        local needPD = raid.UnderLandHarass or (raid.LastLandEnemyCount or 0) >= 2
        local engineerLossRisk = OvermindMemory.GetEngineerLossRisk(aiBrain, threatPos, 42)

        local aaCount = aiBrain:GetNumUnitsAroundPoint(T1AAStructureCategory, threatPos, 18, 'Ally') or 0
        local pdCount = aiBrain:GetNumUnitsAroundPoint(T1PDStructureCategory, threatPos, 18, 'Ally') or 0

        local targetAA = 1
        if bomberWatch then
            targetAA = math.max(targetAA, 1)
        end
        if exposedMexAirRaid or desiredExposedMexAA >= 2 or engineerLossRisk >= 1.4 or (raid.LastBomberEnemyCount or 0) >= 2 then
            targetAA = 2
        end
        local wantAA = needAA and aaCount < targetAA
        local wantPD = needPD and pdCount < 1
        if wantAA or wantPD then
            local farMex = mainPos and Distance2D(mainPos, threatPos) > 260
            if farMex and (eco.MassTrend or 0) < -0.12 and not exposedMexAirRaid then
                state.NextTry = now + 9
                return
            end
            chooseAA = wantAA
            if wantPD and not wantAA then
                chooseAA = false
            elseif wantPD and wantAA and (raid.LastLandEnemyCount or 0) > (raid.LastAirEnemyCount or 0) + 1 then
                chooseAA = false
            end
            buildPosBase = threatPos
        end
    end

    if not buildPosBase and exposedMexAirRaid and raid.ExposedMexThreatPos then
        local threatAA = aiBrain:GetNumUnitsAroundPoint(T1AAStructureCategory, raid.ExposedMexThreatPos, 18, 'Ally') or 0
        local targetAA = math.max(1, desiredExposedMexAA)
        if threatAA < targetAA then
            chooseAA = true
            buildPosBase = raid.ExposedMexThreatPos
        end
    end

    if not buildPosBase
        and mainPos
        and powerReady > 0
        and now >= 300
        and (bomberWatch or bomberPanic or exposedMexAirRaid or desiredExposedMexAA >= 2)
        and now >= ((state.LastPreemptiveAATry or -999) + 22) then
        local preemptivePos = false
        if exposedMexAirRaid or bomberPanic or (eco.MassTrend or 0) >= -0.18 then
            preemptivePos = FindExposedMexForPreemptiveAA(aiBrain, mainPos)
        end
        if preemptivePos then
            chooseAA = true
            buildPosBase = preemptivePos
            state.LastPreemptiveAATry = now
        end
    end

    if not buildPosBase and mainPos then
        local baseAA = aiBrain:GetNumUnitsAroundPoint(T1AAStructureCategory, mainPos, 46, 'Ally') or 0
        local basePD = aiBrain:GetNumUnitsAroundPoint(T1PDStructureCategory, mainPos, 46, 'Ally') or 0
        local desiredAA = math.max(0, math.min(3, structurePlan.BaseAA or 0))
        local desiredPD = math.max(0, math.min(2, structurePlan.PD or 0))
        if bomberWatch and powerReady > 0 then
            desiredAA = math.max(desiredAA, 1)
        end
        if bomberPanic or exposedMexAirRaid then
            desiredAA = math.max(desiredAA, 2 + (((raid.BomberRaidSeverity or 0) >= 4) and 1 or 0))
        end
        if desiredAA <= 0 and desiredPD <= 0 then
            state.NextTry = now + 8
            return
        end
        if (powerReady <= 0 or radarCritical) and not raid.UnderLandHarass and not raid.UnderAirHarass then
            state.NextTry = now + 8
            return
        end
        local wantBaseAA = now >= 170 and baseAA < desiredAA
        local wantBasePD = now >= 200 and basePD < desiredPD
        if wantBaseAA or wantBasePD then
            chooseAA = wantBaseAA
            if wantBasePD and not wantBaseAA then
                chooseAA = false
            elseif wantBasePD and wantBaseAA and (raid.LastLandEnemyCount or 0) > (raid.LastAirEnemyCount or 0) then
                chooseAA = false
            end
            buildPosBase = mainPos
            targetIsBase = true
        end
    end

    if not buildPosBase then
        state.NextTry = now + 8
        return
    end

    local probeBuilder = (aiBrain:GetListOfUnits(BuilderCategory, false, true) or { })[1]
    local bp = PickBlueprint(probeBuilder, chooseAA)
    if not bp then
        local builders = aiBrain:GetListOfUnits(BuilderCategory, false, true)
        if builders then
            for _, b in builders do
                bp = PickBlueprint(b, chooseAA)
                if bp then
                    break
                end
            end
        end
    end

    if not bp then
        state.NextTry = now + 10
        return
    end

    local builder, busy = PickBuilder(aiBrain, buildPosBase, bp)
    if not builder then
        state.NextTry = now + 7
        return
    end

    local category = chooseAA and T1AAStructureCategory or T1PDStructureCategory
    local facingPos = targetIsBase and ResolveBaseFacingPos(runtime, raid, mainPos) or false
    local buildPos = FindBuildPos(aiBrain, buildPosBase, category, facingPos)

    if busy and IssueClearCommands then
        IssueClearCommands({ builder })
    end
    if IssueBuildMobile then
        IssueBuildMobile({ builder }, buildPos, bp, {})

        if now - (state.LastLog or -999) >= 12 then
            state.LastLog = now
            LOG(string.format('*OVERMIND MEXDEF A%d t=%.1f kind=%s busy=%d',
                aiBrain:GetArmyIndex(),
                now,
                (chooseAA and 'aa' or 'pd') .. (targetIsBase and '_base' or ''),
                busy and 1 or 0))
        end
    end

    state.NextTry = now + 16
end

-- FAF import exposes globals from the file environment.
-- Keep a global Update symbol for scheduler compatibility.
function Update(aiBrain, now)
    return Module.Update(aiBrain, now)
end
MexDefenseUpdate = Module.Update

return Module
