local function ClassifyFactory(factory)
    if not factory then
        return 'other'
    end
    if EntityCategoryContains(categories.FACTORY * categories.LAND, factory) then
        return 'land'
    end
    if EntityCategoryContains(categories.FACTORY * categories.AIR, factory) then
        return 'air'
    end
    return 'other'
end

local function IsFactoryReady(factory)
    if not factory or factory.Dead then
        return false
    end
    if factory:IsUnitState('BeingBuilt') or factory:IsUnitState('Upgrading') then
        return false
    end
    if factory:IsPaused() then
        return false
    end
    if factory.GetFractionComplete and factory:GetFractionComplete() < 0.95 then
        return false
    end
    return true
end

function Update(aiBrain, now)
    local runtime = aiBrain.OvermindRuntime
    if not runtime then
        return
    end

    local recovery = runtime.Recovery or {}
    runtime.Recovery = recovery

    local factories = aiBrain:GetListOfUnits(categories.FACTORY * categories.STRUCTURE, false, true)
    if not factories or table.getn(factories) == 0 then
        return
    end

    local total = 0
    local deficits = 0
    local landDeficits = 0
    local airDeficits = 0

    for _, fac in factories do
        if IsFactoryReady(fac) then
            total = total + 1
            local q = fac.GetCommandQueue and fac:GetCommandQueue() or false
            local qLen = q and table.getn(q) or 0
            if qLen < 1 then
                deficits = deficits + 1
                local kind = ClassifyFactory(fac)
                if kind == 'land' then
                    landDeficits = landDeficits + 1
                elseif kind == 'air' then
                    airDeficits = airDeficits + 1
                end
            end
        end
    end

    if total <= 0 then
        return
    end

    local anyNowDeficit = deficits >= 1
    if not anyNowDeficit then
        recovery.LastAnyFactoryQueueHealthyTime = now
    elseif not recovery.LastAnyFactoryQueueHealthyTime then
        recovery.LastAnyFactoryQueueHealthyTime = now
    end

    local deficitRatio = deficits / total
    local queueUptime = 1 - deficitRatio
    local nowDeficit = deficits >= 1 and deficitRatio >= 0.28
    if not nowDeficit then
        recovery.LastFactoryQueueHealthyTime = now
    elseif not recovery.LastFactoryQueueHealthyTime then
        recovery.LastFactoryQueueHealthyTime = now
    end

    local anyStarvationTime = now - (recovery.LastAnyFactoryQueueHealthyTime or now)
    local starvationTime = now - (recovery.LastFactoryQueueHealthyTime or now)
    recovery.FactoryAnyQueueStarvationTime = anyStarvationTime
    recovery.FactoryQueueDeficit = deficits
    recovery.FactoryQueueDeficitRatio = deficitRatio
    recovery.FactoryQueueUptime = queueUptime
    recovery.FactoryQueueStarvationTime = starvationTime
    recovery.FactoryQueueExpansionBlocked = false

    if deficits >= 1 and (deficitRatio >= 0.2 or starvationTime >= 8 or anyStarvationTime >= 12) then
        recovery.FactoryQueueExpansionBlocked = true
    end

    if anyStarvationTime > 14 and deficits >= 1 then
        recovery.ForceFactoryDeadlock = true
        recovery.FactoryDeadlockUntil = now + 12
        if landDeficits > 0 then
            recovery.ForceFactoryLand = true
        end
        if airDeficits > 0 then
            recovery.ForceFactoryAir = true
        end
    elseif deficits <= 0 and now > (recovery.FactoryDeadlockUntil or -999) then
        recovery.ForceFactoryDeadlock = false
        recovery.ForceFactoryLand = false
        recovery.ForceFactoryAir = false
    end

    if starvationTime > 20 and deficits >= 1 then
        recovery.ForceFactoryRecovery = true
        if landDeficits >= airDeficits then
            recovery.ForceFactoryLand = true
        else
            recovery.ForceFactoryAir = true
        end
    elseif deficits <= 0 and starvationTime <= 1 then
        recovery.ForceFactoryRecovery = false
    end

    if (now - (runtime.LastFactoryHeartbeatLogTime or -999)) >= 35 then
        runtime.LastFactoryHeartbeatLogTime = now
        LOG(string.format('*OVERMIND FACTORYHB A%d t=%.1f fac=%d deficit=%d ratio=%.2f uptime=%.2f starving=%.1f',
            aiBrain:GetArmyIndex(),
            now,
            total,
            deficits,
            deficitRatio,
            queueUptime,
            starvationTime))
    end
end
