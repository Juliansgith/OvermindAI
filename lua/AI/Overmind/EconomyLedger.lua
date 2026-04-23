local M = {}

local function Clamp(v, minV, maxV)
    if v < minV then
        return minV
    end
    if v > maxV then
        return maxV
    end
    return v
end

local function CopyTable(src)
    local dst = {}
    if type(src) ~= 'table' then
        return dst
    end
    for key, value in src do
        dst[key] = value
    end
    return dst
end

local function Ensure(runtime)
    runtime.EconomyLedger = runtime.EconomyLedger or {
        Factory = {},
        Engineer = {},
        Upgrade = {},
        Reclaim = {},
        Aggregate = {},
        LastUpdate = -999,
    }
    local ledger = runtime.EconomyLedger
    ledger.Factory = ledger.Factory or {}
    ledger.Engineer = ledger.Engineer or {}
    ledger.Upgrade = ledger.Upgrade or {}
    ledger.Reclaim = ledger.Reclaim or {}
    ledger.Aggregate = ledger.Aggregate or {}
    return ledger
end

local function Refresh(runtime, now)
    local ledger = Ensure(runtime)
    local factory = ledger.Factory or {}
    local engineer = ledger.Engineer or {}
    local upgrade = ledger.Upgrade or {}
    local reclaim = ledger.Reclaim or {}

    local factoryReady = factory.ReadyCount or 0
    local factoryIdle = factory.IdleCount or factory.EmptyCount or 0
    local engineerTotal = engineer.TotalCount or 0
    local engineerIdle = engineer.IdleCount or 0
    local activeMex = upgrade.ActiveMexUpgrades or upgrade.InFlight or 0
    local reclaimEngineers = reclaim.AssignedCount or engineer.ReclaimFieldCount or 0

    local aggregate = ledger.Aggregate or {}
    aggregate.FactoryBusyRatio = factoryReady > 0 and Clamp((factoryReady - factoryIdle) / factoryReady, 0, 1) or 0
    aggregate.EngineerBusyRatio = engineerTotal > 0 and Clamp((engineerTotal - engineerIdle) / engineerTotal, 0, 1) or 0
    aggregate.ActiveMexUpgrades = activeMex
    aggregate.ReclaimEngineerCount = reclaimEngineers
    aggregate.IdleFactoryCount = factoryIdle
    aggregate.IdleEngineerCount = engineerIdle
    aggregate.FactoryBlockedReason = factory.BlockedReason or 'none'
    aggregate.EngineerBlockedReason = engineer.BlockedReason or 'none'
    aggregate.UpgradeBlockedReason = upgrade.Reason or upgrade.BlockedReason or 'none'
    aggregate.ReclaimBlockedReason = reclaim.BlockedReason or 'none'
    aggregate.SpendSaturation = Clamp(
        (aggregate.FactoryBusyRatio * 0.48)
        + (aggregate.EngineerBusyRatio * 0.34)
        + (activeMex > 0 and 0.10 or 0)
        + (reclaimEngineers > 0 and 0.08 or 0),
        0,
        1)
    aggregate.UpdatedAt = now or ledger.LastUpdate or 0
    ledger.Aggregate = aggregate
    ledger.LastUpdate = now or ledger.LastUpdate
    return ledger
end

function M.Ensure(runtime)
    return Ensure(runtime or {})
end

function M.GetSnapshot(runtime)
    return Ensure(runtime or {})
end

function M.PublishFactoryActivity(aiBrain, runtime, now, data)
    if not runtime then
        return false
    end
    local ledger = Ensure(runtime)
    ledger.Factory = CopyTable(data)
    ledger.Factory.UpdatedAt = now
    Refresh(runtime, now)
    return true
end

function M.PublishEngineerActivity(aiBrain, runtime, now, data)
    if not runtime then
        return false
    end
    local ledger = Ensure(runtime)
    ledger.Engineer = CopyTable(data)
    ledger.Engineer.UpdatedAt = now
    ledger.Reclaim.AssignedCount = data.ReclaimFieldCount or ledger.Reclaim.AssignedCount or 0
    ledger.Reclaim.EnemyMexCount = data.ReclaimEnemyMexCount or ledger.Reclaim.EnemyMexCount or 0
    ledger.Reclaim.UpdatedAt = now
    Refresh(runtime, now)
    return true
end

function M.PublishUpgradeActivity(aiBrain, runtime, now, data)
    if not runtime then
        return false
    end
    local ledger = Ensure(runtime)
    ledger.Upgrade = CopyTable(data)
    ledger.Upgrade.UpdatedAt = now
    Refresh(runtime, now)
    return true
end

function M.PublishReclaimActivity(aiBrain, runtime, now, data)
    if not runtime then
        return false
    end
    local ledger = Ensure(runtime)
    ledger.Reclaim = CopyTable(data)
    ledger.Reclaim.UpdatedAt = now
    Refresh(runtime, now)
    return true
end

function M.Refresh(aiBrain, runtime, now)
    if not runtime then
        return false
    end
    return Refresh(runtime, now)
end

return M
