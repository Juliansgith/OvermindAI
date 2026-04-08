local OvermindMemory = import('/mods/OvermindAI/lua/AI/Overmind/Memory.lua')

local LandCombatCategory = categories.MOBILE * categories.LAND - categories.ENGINEER - categories.SCOUT - categories.COMMAND
local AirFighterCategory = categories.MOBILE * categories.AIR * categories.ANTIAIR - categories.SCOUT - categories.TRANSPORTATION - categories.COMMAND
local MobileAACategory = categories.MOBILE * (categories.LAND + categories.AIR) * categories.ANTIAIR - categories.SCOUT - categories.TRANSPORTATION - categories.COMMAND
local EnemyLandRaidCategory = categories.MOBILE * categories.LAND - categories.ENGINEER - categories.SCOUT - categories.COMMAND
local EnemyAirRaidCategory = categories.MOBILE * categories.AIR - categories.SCOUT - categories.TRANSPORTATION - categories.COMMAND
local EnemyBomberRaidCategory = categories.MOBILE * categories.AIR * categories.BOMBER - categories.SCOUT - categories.TRANSPORTATION - categories.COMMAND
local BaseAssetCategory = categories.STRUCTURE * (categories.FACTORY + categories.ENERGYPRODUCTION + categories.DEFENSE + categories.RADAR)

local function Distance2D(a, b)
    local dx = (a[1] or 0) - (b[1] or 0)
    local dz = (a[3] or 0) - (b[3] or 0)
    return math.sqrt((dx * dx) + (dz * dz))
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

local function IsIdle(unit)
    local q = unit.GetCommandQueue and unit:GetCommandQueue() or false
    return (not q) or table.getn(q) == 0
end

local function IsReassignable(unit, allowQueued)
    if not unit or unit.Dead then
        return false
    end
    local q = unit.GetCommandQueue and unit:GetCommandQueue() or false
    local qLen = q and table.getn(q) or 0
    if qLen <= 0 then
        return true
    end
    if allowQueued and qLen <= 1 then
        return true
    end
    return false
end

local function SelectResponseUnits(aiBrain, category, maxCount, nearPos, allowQueued)
    local list = aiBrain:GetListOfUnits(category, false, true)
    if not list or table.getn(list) == 0 then
        return {}
    end

    local fallback = {}
    local nearby = {}
    local nearbyRadius = 135
    if category == AirFighterCategory then
        nearbyRadius = 210
    end

    for _, unit in list do
        if unit and not unit.Dead and IsReassignable(unit, allowQueued) then
            local pos = unit.GetPosition and unit:GetPosition() or false
            local isNear = false
            if pos and nearPos and Distance2D(pos, nearPos) <= nearbyRadius then
                isNear = true
            end
            if isNear then
                table.insert(nearby, unit)
            elseif IsIdle(unit) then
                table.insert(fallback, unit)
            end
        end
    end

    local out = {}
    for _, unit in nearby do
        table.insert(out, unit)
        if table.getn(out) >= maxCount then
            break
        end
    end
    if table.getn(out) < maxCount then
        for _, unit in fallback do
            table.insert(out, unit)
            if table.getn(out) >= maxCount then
                break
            end
        end
    end

    return out
end

local function AppendUniqueUnits(target, source, maxCount)
    target = target or {}
    source = source or {}
    local seen = {}
    for _, unit in target do
        if unit and not unit.Dead then
            seen[tostring(unit)] = true
        end
    end
    for _, unit in source do
        if table.getn(target) >= (maxCount or 9999) then
            break
        end
        if unit and not unit.Dead then
            local key = tostring(unit)
            if not seen[key] then
                table.insert(target, unit)
                seen[key] = true
            end
        end
    end
    return target
end

local function GetAssetTargets(aiBrain, runtime)
    local out = {}
    local mainPos = GetMainPos(aiBrain, runtime)
    if mainPos then
        table.insert(out, {
            Pos = mainPos,
            Importance = 2.3,
            Label = 'main',
        })
    end

    local acuList = aiBrain:GetListOfUnits(categories.COMMAND, false, true)
    if acuList and acuList[1] and not acuList[1].Dead then
        local acuPos = acuList[1]:GetPosition()
        if acuPos then
            table.insert(out, {
                Pos = acuPos,
                Importance = 2.8,
                Label = 'acu',
            })
        end
    end

    local mexes = aiBrain:GetListOfUnits(categories.MASSEXTRACTION * categories.STRUCTURE, false, true)
    if mexes and table.getn(mexes) > 0 then
        local processed = 0
        for _, mex in mexes do
            if mex and not mex.Dead then
                local pos = mex:GetPosition()
                if pos then
                    processed = processed + 1
                    if processed > 30 then
                        break
                    end

                    local importance = 1.7
                    if EntityCategoryContains(categories.TECH2, mex) then
                        importance = 2.1
                    elseif EntityCategoryContains(categories.TECH3, mex) then
                        importance = 2.5
                    end

                    table.insert(out, {
                        Pos = pos,
                        Importance = importance,
                        Label = 'mex',
                    })
                end
            end
        end
    end

    local assets = aiBrain:GetListOfUnits(BaseAssetCategory, false, true)
    if assets and table.getn(assets) > 0 then
        local processed = 0
        for _, asset in assets do
            if asset and not asset.Dead then
                local pos = asset:GetPosition()
                if pos then
                    processed = processed + 1
                    if processed > 16 then
                        break
                    end
                    table.insert(out, {
                        Pos = pos,
                        Importance = 1.1,
                        Label = 'asset',
                    })
                end
            end
        end
    end

    return out
end

local function FindMostThreatenedTarget(aiBrain, runtime, now)
    local targets = GetAssetTargets(aiBrain, runtime)
    if not targets or table.getn(targets) == 0 then
        return false, 0, 0, false, 0, 'none'
    end

    local bestPos = false
    local bestEnemyLand = 0
    local bestEnemyAir = 0
    local bestEnemyBomb = 0
    local bestScore = 0
    local bestEnemyAirPos = false
    local bestLabel = 'none'

    local mainPos = GetMainPos(aiBrain, runtime)
    local processed = 0
    for _, target in targets do
        local pos = target.Pos
        if pos then
            processed = processed + 1
            if processed > 52 then
                break
            end

            local enemyLandUnits = aiBrain:GetUnitsAroundPoint(EnemyLandRaidCategory, pos, 30, 'Enemy')
            local enemyAirUnits = aiBrain:GetUnitsAroundPoint(EnemyAirRaidCategory, pos, 42, 'Enemy')
            local enemyBombers = aiBrain:GetUnitsAroundPoint(EnemyBomberRaidCategory, pos, 52, 'Enemy')
            local enemyLand = enemyLandUnits and table.getn(enemyLandUnits) or 0
            local enemyAir = enemyAirUnits and table.getn(enemyAirUnits) or 0
            local enemyBomb = enemyBombers and table.getn(enemyBombers) or 0

            local allyLand = aiBrain:GetNumUnitsAroundPoint(LandCombatCategory, pos, 34, 'Ally') or 0
            local allyAA = aiBrain:GetNumUnitsAroundPoint(MobileAACategory, pos, 44, 'Ally') or 0
            local threat = aiBrain:GetThreatAtPosition(pos, 1, true, 'AntiSurface') or 0
            local distPenalty = Distance2D(mainPos, pos) / 260
            local score = (enemyLand * 2.5)
                + (enemyAir * 1.8)
                + (enemyBomb * 2.7)
                + (threat * 1.25)
                + (target.Importance or 1)
                - (allyLand * 1.15)
                - (allyAA * 0.9)
                - distPenalty

            if enemyBomb >= 1 and (target.Importance or 1) >= 1.6 then
                score = score + 1.4
            end

            if score > bestScore then
                bestScore = score
                bestPos = pos
                bestEnemyLand = enemyLand
                bestEnemyAir = enemyAir
                bestEnemyBomb = enemyBomb
                bestLabel = target.Label or 'asset'
                if enemyAirUnits and enemyAirUnits[1] and enemyAirUnits[1].GetPosition then
                    bestEnemyAirPos = enemyAirUnits[1]:GetPosition()
                end
            end
        end
    end

    if bestPos and bestScore > 0.9 then
        runtime.LastRaidDefenseContactTime = now
        OvermindMemory.RecordThreatSpike(aiBrain, bestPos, math.max(1, bestEnemyLand + bestEnemyAir + (bestEnemyBomb * 1.4)))
        return bestPos, bestEnemyLand, bestEnemyAir + bestEnemyBomb, bestEnemyAirPos, bestEnemyBomb, bestLabel
    end

    return false, 0, 0, false, 0, 'none'
end

function Update(aiBrain, now)
    local runtime = aiBrain.OvermindRuntime
    if not runtime then
        return
    end

    if now - (runtime.LastRaidDefenseUpdateTime or -999) < 3 then
        return
    end
    runtime.LastRaidDefenseUpdateTime = now

    runtime.RaidDefense = runtime.RaidDefense or {}
    local state = runtime.RaidDefense
    state.UnderLandHarass = state.UnderLandHarass or false
    state.UnderAirHarass = state.UnderAirHarass or false
    state.LastThreatMexPos = state.LastThreatMexPos or false
    state.LastEnemyAirPos = state.LastEnemyAirPos or false
    state.LastLandEnemyCount = state.LastLandEnemyCount or 0
    state.LastAirEnemyCount = state.LastAirEnemyCount or 0
    state.LastBomberEnemyCount = state.LastBomberEnemyCount or 0
    state.LastThreatLabel = state.LastThreatLabel or 'none'
    state.LastAirHarassTargetLabel = state.LastAirHarassTargetLabel or 'none'
    state.LandHarassUntil = state.LandHarassUntil or -999
    state.AirHarassUntil = state.AirHarassUntil or -999
    state.BomberPanicUntil = state.BomberPanicUntil or -999
    state.ExposedMexAirRaidUntil = state.ExposedMexAirRaidUntil or -999
    state.ExposedMexUnderAirRaid = state.ExposedMexUnderAirRaid or false
    state.ExposedMexThreatPos = state.ExposedMexThreatPos or false
    state.LastConfirmedBomberRaidTime = state.LastConfirmedBomberRaidTime or -999
    state.BomberRaidSeverity = state.BomberRaidSeverity or 0
    state.LastLandResponse = 0
    state.LastAirResponse = 0
    state.LastAAResponse = 0

    local threatPos, enemyLand, enemyAir, enemyAirPos, enemyBombers, threatLabel = FindMostThreatenedTarget(aiBrain, runtime, now)
    if not threatPos then
        state.UnderLandHarass = now < (state.LandHarassUntil or -999)
        state.UnderAirHarass = now < (state.AirHarassUntil or -999)
        if not state.UnderLandHarass then
            state.LastLandEnemyCount = 0
        end
        if not state.UnderAirHarass then
            state.LastAirEnemyCount = 0
            state.LastBomberEnemyCount = 0
        end
        state.ExposedMexUnderAirRaid = now < (state.ExposedMexAirRaidUntil or -999)
        if not state.ExposedMexUnderAirRaid then
            state.ExposedMexThreatPos = false
            state.BomberRaidSeverity = 0
        end
        return
    end

    state.LastThreatMexPos = threatPos
    state.LastEnemyAirPos = enemyAirPos
    state.LastThreatLabel = threatLabel
    state.LastLandEnemyCount = math.max(state.LastLandEnemyCount or 0, enemyLand)
    state.LastAirEnemyCount = math.max(state.LastAirEnemyCount or 0, enemyAir)
    state.LastBomberEnemyCount = math.max(state.LastBomberEnemyCount or 0, enemyBombers or 0)

    if enemyLand >= 1 then
        state.LandHarassUntil = now + ((threatLabel == 'mex' and enemyLand <= 2) and 22 or 16)
    end
    if enemyAir >= 1 then
        state.AirHarassUntil = now + 22
        state.LastAirHarassTargetLabel = threatLabel
    end
    if (enemyBombers or 0) >= 1 then
        state.AirHarassUntil = now + 30
        state.BomberPanicUntil = math.max(state.BomberPanicUntil or -999, now + 120)
        state.LastConfirmedBomberRaidTime = now
        state.BomberRaidSeverity = math.max(state.BomberRaidSeverity or 0, (enemyBombers or 0) + math.floor(enemyAir * 0.5))
        state.LastAirHarassTargetLabel = threatLabel
        if threatLabel == 'mex' or threatLabel == 'asset' then
            state.ExposedMexAirRaidUntil = now + 55
            state.ExposedMexUnderAirRaid = true
            state.ExposedMexThreatPos = threatPos
        end
    end

    state.UnderLandHarass = now < (state.LandHarassUntil or -999)
    state.UnderAirHarass = now < (state.AirHarassUntil or -999)
    state.ExposedMexUnderAirRaid = state.ExposedMexUnderAirRaid or (now < (state.ExposedMexAirRaidUntil or -999))
    if now >= (state.ExposedMexAirRaidUntil or -999) then
        state.ExposedMexUnderAirRaid = false
    end

    runtime.Recovery = runtime.Recovery or {}
    local recovery = runtime.Recovery
    if state.UnderAirHarass and ((enemyAir >= 2) or ((enemyBombers or 0) >= 1)) then
        recovery.ForceDefenseRecovery = true
    end

    local mainPos = GetMainPos(aiBrain, runtime)
    local baseEdgeSiege = mainPos
        and threatPos
        and (state.LastThreatLabel == 'acu' or state.LastThreatLabel == 'main' or state.LastThreatLabel == 'asset')
        and enemyLand >= 6
        and Distance2D(mainPos, threatPos) <= 120

    if state.UnderLandHarass then
        local needLand = math.min(16, math.max(4, enemyLand + math.floor(enemyAir * 0.5) + 2))
        local smallMexSabotage = (state.LastThreatLabel == 'mex' or state.LastThreatLabel == 'asset') and enemyLand >= 1 and enemyLand <= 2
        local largeBaseAttack = baseEdgeSiege or ((state.LastThreatLabel == 'acu' or state.LastThreatLabel == 'main' or state.LastThreatLabel == 'asset') and enemyLand >= 5)
        if smallMexSabotage then
            needLand = math.min(8, math.max(needLand, enemyLand + 4))
        end
        if largeBaseAttack then
            needLand = math.min(22, math.max(needLand, enemyLand + 6 + math.floor(enemyAir * 0.5)))
        end
        local defenders = SelectResponseUnits(aiBrain, LandCombatCategory, needLand, threatPos, true)
        if smallMexSabotage and table.getn(defenders) < needLand then
            defenders = AppendUniqueUnits(defenders, SelectResponseUnits(aiBrain, LandCombatCategory, needLand + 2, threatPos, true), needLand + 2)
        end
        if largeBaseAttack and table.getn(defenders) < needLand then
            defenders = AppendUniqueUnits(defenders, SelectResponseUnits(aiBrain, LandCombatCategory, math.min(24, needLand + 4), threatPos, true), math.min(24, needLand + 4))
        end
        if table.getn(defenders) > 0 then
            if IssueMove then
                IssueMove(defenders, threatPos)
            end
            if IssueAggressiveMove then
                IssueAggressiveMove(defenders, threatPos)
            end
            state.LastLandResponse = table.getn(defenders)
        end

        if smallMexSabotage then
            recovery.ForceBaseEngineerRecovery = true
        end

        if largeBaseAttack then
            recovery.ForceDefenseRecovery = true
            recovery.ForceFactoryRecovery = true
            recovery.ForceFactoryLand = true
            local reserves = SelectResponseUnits(aiBrain, LandCombatCategory, math.min(24, enemyLand + 10), threatPos, true)
            if table.getn(reserves) > 0 then
                if IssueMove then
                    IssueMove(reserves, threatPos)
                end
                if IssueAggressiveMove then
                    IssueAggressiveMove(reserves, threatPos)
                end
                state.LastLandResponse = math.max(state.LastLandResponse or 0, table.getn(reserves))
            end
        elseif (state.LastThreatLabel == 'acu' or state.LastThreatLabel == 'main' or state.LastThreatLabel == 'asset') and enemyLand >= 4 then
            recovery.ForceDefenseRecovery = true
            recovery.ForceFactoryRecovery = true
            recovery.ForceFactoryLand = true
            local reserves = SelectResponseUnits(aiBrain, LandCombatCategory, math.min(22, enemyLand + 8), threatPos, true)
            if table.getn(reserves) > 0 and IssueMove then
                IssueMove(reserves, threatPos)
            end
        elseif smallMexSabotage and table.getn(defenders) < 4 then
            local reserves = SelectResponseUnits(aiBrain, LandCombatCategory, 4, threatPos, true)
            if table.getn(reserves) > 0 and IssueAggressiveMove then
                IssueAggressiveMove(reserves, threatPos)
                state.LastLandResponse = math.max(state.LastLandResponse or 0, table.getn(reserves))
            end
        end
    end

    if state.UnderAirHarass then
        local airTarget = enemyAirPos or threatPos
        local needFighters = math.min(18, math.max(5, enemyAir + (enemyBombers or 0) + 3))
        local fighters = SelectResponseUnits(aiBrain, AirFighterCategory, needFighters, airTarget, true)
        if table.getn(fighters) > 0 and IssueAggressiveMove then
            IssueAggressiveMove(fighters, airTarget)
            state.LastAirResponse = table.getn(fighters)
        end

        local needMobileAA = math.min(14, math.max(3, enemyAir + 2 + (((enemyBombers or 0) >= 1) and 2 or 0)))
        local mobileAA = SelectResponseUnits(aiBrain, MobileAACategory, needMobileAA, threatPos, false)
        if table.getn(mobileAA) > 0 then
            local coverPos = threatPos
            if (state.LastThreatLabel == 'mex' or state.LastThreatLabel == 'asset') and mainPos then
                coverPos = {
                    ((threatPos[1] or 0) * 0.72) + ((mainPos[1] or 0) * 0.28),
                    0,
                    ((threatPos[3] or 0) * 0.72) + ((mainPos[3] or 0) * 0.28),
                }
            end
            if IssueMove then
                IssueMove(mobileAA, coverPos)
            end
            if enemyAirPos and IssueAggressiveMove then
                local engage = true
                if coverPos and Distance2D(coverPos, enemyAirPos) > 80 then
                    engage = false
                end
                if engage then
                    IssueAggressiveMove(mobileAA, enemyAirPos)
                end
            end
            state.LastAAResponse = table.getn(mobileAA)
        end

        if (enemyBombers or 0) >= 1 and (state.LastThreatLabel == 'mex' or state.LastThreatLabel == 'asset') then
            recovery.ForceBaseEngineerRecovery = true
        end

        if table.getn(fighters) == 0 and enemyAir >= 2 then
            recovery.ForceFactoryRecovery = true
            recovery.ForceFactoryAir = true
            recovery.ForceFactoryLand = false
        end
    end

    if (state.LastLandResponse + state.LastAirResponse + state.LastAAResponse) > 0 and (now - (runtime.LastRaidDefenseLogTime or -999)) >= 16 then
        runtime.LastRaidDefenseLogTime = now
        LOG(string.format('*OVERMIND RAIDDEF A%d t=%.1f zone=%s land=%d air=%d bomb=%d lresp=%d aresp=%d aa=%d',
            aiBrain:GetArmyIndex(),
            now,
            state.LastThreatLabel or 'asset',
            enemyLand,
            enemyAir,
            enemyBombers or 0,
            state.LastLandResponse or 0,
            state.LastAirResponse or 0,
            state.LastAAResponse or 0))
    end
end
