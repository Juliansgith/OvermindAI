local OvermindAutoTune = import('/mods/OvermindAI/lua/AI/Overmind/AutoTune.lua')

local function Clamp(v, minV, maxV)
    if v < minV then
        return minV
    end
    if v > maxV then
        return maxV
    end
    return v
end

local function GetMainPos(aiBrain, runtime)
    if aiBrain.BuilderManagers and aiBrain.BuilderManagers.MAIN and aiBrain.BuilderManagers.MAIN.Position then
        return aiBrain.BuilderManagers.MAIN.Position
    end
    if runtime and runtime.ZoneModel and runtime.ZoneModel.OwnMainPos then
        return runtime.ZoneModel.OwnMainPos
    end
    local sx, sz = aiBrain:GetArmyStartPos()
    return { sx, 0, sz }
end

local function CountIdleFactories(aiBrain)
    local idle = 0
    local all = aiBrain:GetListOfUnits(categories.FACTORY * categories.STRUCTURE, false, true)
    if not all then
        return 0
    end

    for _, fac in all do
        if fac and not fac.Dead then
            local q = fac.GetCommandQueue and fac:GetCommandQueue() or false
            if not q or table.getn(q) == 0 then
                idle = idle + 1
            end
        end
    end

    return idle
end

function Update(aiBrain, now)
    local runtime = aiBrain.OvermindRuntime or {}
    aiBrain.OvermindRuntime = runtime

    local rec = runtime.Recovery or {
        LastProgressTime = now,
        LastScoutPresence = now,
        LastFlagSignature = '',
    }
    runtime.Recovery = rec

    local eco = runtime.EcoState or {}
    local policy = runtime.EcoPolicy or {}
    local zone = runtime.ZoneModel or {}
    local raid = runtime.RaidDefense or {}
    local tune = OvermindAutoTune.GetConfig(aiBrain)
    local mainPos = GetMainPos(aiBrain, runtime)

    local factories = aiBrain:GetCurrentUnits(categories.FACTORY * categories.STRUCTURE) or 0
    local idleFactories = CountIdleFactories(aiBrain)
    local landFactories = aiBrain:GetCurrentUnits(categories.FACTORY * categories.LAND * categories.STRUCTURE) or 0
    local airFactories = aiBrain:GetCurrentUnits(categories.FACTORY * categories.AIR * categories.STRUCTURE) or 0
    local engineers = aiBrain:GetCurrentUnits(categories.ENGINEER * categories.MOBILE) or 0
    local baseEngineers = aiBrain:GetNumUnitsAroundPoint(categories.ENGINEER * categories.MOBILE, mainPos, 80, 'Ally') or 0
    local defenses = aiBrain:GetCurrentUnits(categories.DEFENSE * categories.STRUCTURE) or 0
    local scoutAir = aiBrain:GetCurrentUnits(categories.SCOUT * categories.AIR * categories.MOBILE) or 0
    local scoutLand = aiBrain:GetCurrentUnits(categories.SCOUT * categories.LAND * categories.MOBILE) or 0
    local scoutTotal = scoutAir + scoutLand
    local mexes = aiBrain:GetCurrentUnits(categories.MASSEXTRACTION * categories.STRUCTURE) or 0
    local unitCount = eco.UnitCount or (aiBrain:GetCurrentUnits(categories.ALLUNITS) or 0)

    if scoutTotal > 0 then
        rec.LastScoutPresence = now
    end

    local progressed = false
    if unitCount >= (rec.LastUnitCount or 0) + 2 then
        progressed = true
    end
    if factories > (rec.LastFactoryCount or 0) then
        progressed = true
    end
    if mexes > (rec.LastMexCount or 0) then
        progressed = true
    end
    if progressed then
        rec.LastProgressTime = now
    end

    rec.LastUnitCount = unitCount
    rec.LastFactoryCount = factories
    rec.LastMexCount = mexes

    local safeEco = ((eco.EnergyStored or 0) > 1800 or (eco.EnergyTrend or 0) > 4)
        and ((eco.MassStored or 0) > 120 or (eco.MassTrend or 0) > -0.04)
    local mildEco = ((eco.EnergyStored or 0) > 900 or (eco.EnergyTrend or 0) > -1)
        and ((eco.MassStored or 0) > 70 or (eco.MassTrend or 0) > -0.08)

    local gameTime = now or 0
    local minFactoryFloor = 2
    if gameTime >= 220 then
        minFactoryFloor = tune.FactoryFloorEarly or 3
    end
    if gameTime >= 420 then
        minFactoryFloor = tune.FactoryFloorMid or 4
    end
    if gameTime >= 760 then
        minFactoryFloor = tune.FactoryFloorLate or 6
    end

    local idleRatio = 0
    if factories > 0 then
        idleRatio = idleFactories / factories
    end

    local stagnation = now - (rec.LastProgressTime or now)
    rec.StagnationTime = Clamp(stagnation, 0, 999)
    rec.FactoryCount = factories
    rec.IdleFactories = idleFactories
    rec.IdleRatio = idleRatio

    local baseFloor = math.max(policy.BaseEngineerFloor or 3, tune.BaseEngineerFloorMin or 3)
    local homeThreat = zone.HomeThreat or 0
    local stagnationTrigger = tune.FactoryRecoveryStagnation or 85

    rec.ForceFactoryRecovery = false
    rec.ForceFactoryLand = false
    rec.ForceFactoryAir = false
    rec.ForceScoutRecovery = false
    rec.ForceBaseEngineerRecovery = false
    rec.ForceDefenseRecovery = false

    if factories < minFactoryFloor and mildEco then
        rec.ForceFactoryRecovery = true
    end

    if gameTime >= 120 and factories <= 1 and mexes >= 1 and (eco.EnergyStorageRatio or 0) >= 0.005 and (eco.EnergyTrend or 0) > -32 then
        rec.ForceFactoryRecovery = true
    end

    if gameTime >= 160 and factories <= 1 and mexes >= 2 and (eco.EnergyStorageRatio or 0) >= 0.02 and (eco.EnergyTrend or 0) > -20 then
        rec.ForceFactoryRecovery = true
    end

    if gameTime >= 240 and factories <= 1 and mexes >= 2 and (eco.EnergyStorageRatio or 0) >= 0.002 then
        rec.ForceFactoryRecovery = true
    end

    if gameTime >= 260 and factories <= 2 and mexes >= 4 and (eco.EnergyStorageRatio or 0) >= 0.03 and (eco.MassTrend or 0) > -0.28 then
        rec.ForceFactoryRecovery = true
    end

    if stagnation > stagnationTrigger and safeEco and factories >= 1 and idleRatio >= 0.45 then
        rec.ForceFactoryRecovery = true
    end

    if (rec.FactoryQueueStarvationTime or 0) > 40 and (rec.FactoryQueueDeficitRatio or 0) >= 0.35 then
        rec.ForceFactoryRecovery = true
    end

    if rec.ForceFactoryRecovery then
        if landFactories <= 1 then
            rec.ForceFactoryLand = true
        elseif airFactories <= 0 and gameTime > 190 then
            rec.ForceFactoryAir = true
        elseif landFactories < math.max(2, airFactories) then
            rec.ForceFactoryLand = true
        else
            rec.ForceFactoryAir = true
        end
    end

    local scoutFloor = tune.ScoutMinCount or 2
    if (gameTime > 110 and scoutTotal < scoutFloor) or (gameTime > 300 and (now - (rec.LastScoutPresence or now)) > 120) then
        rec.ForceScoutRecovery = true
    end

    if gameTime < 900 and engineers >= baseFloor and baseEngineers < baseFloor then
        rec.ForceBaseEngineerRecovery = true
    end

    if gameTime > 230 and defenses < 2 and (homeThreat > 2.5 or rec.ForceBaseEngineerRecovery) and mildEco then
        rec.ForceDefenseRecovery = true
    end

    if raid.UnderAirHarass and (((raid.LastAirEnemyCount or 0) >= 2) or ((raid.LastBomberEnemyCount or 0) >= 1)) then
        rec.ForceDefenseRecovery = true
        rec.ForceScoutRecovery = true
        if airFactories <= 1 and (eco.EnergyStorageRatio or 0) >= 0.005 then
            rec.ForceFactoryRecovery = true
            rec.ForceFactoryAir = true
            rec.ForceFactoryLand = false
        end
    end

    local sig = table.concat({
        rec.ForceFactoryRecovery and 'F' or '-',
        rec.ForceFactoryLand and 'L' or '-',
        rec.ForceFactoryAir and 'A' or '-',
        rec.ForceScoutRecovery and 'S' or '-',
        rec.ForceBaseEngineerRecovery and 'E' or '-',
        rec.ForceDefenseRecovery and 'D' or '-',
    }, '')

    if sig ~= (rec.LastFlagSignature or '') or (now - (rec.LastLogTime or -999)) >= 45 then
        rec.LastFlagSignature = sig
        rec.LastLogTime = now
        LOG(string.format('*OVERMIND WATCHDOG A%d t=%.1f fac=%d idle=%d ratio=%.2f eng=%d base=%d scout=%d stagn=%.1f flags=%s',
            aiBrain:GetArmyIndex(),
            now,
            factories,
            idleFactories,
            idleRatio,
            engineers,
            baseEngineers,
            scoutTotal,
            rec.StagnationTime or 0,
            sig))
    end
end
