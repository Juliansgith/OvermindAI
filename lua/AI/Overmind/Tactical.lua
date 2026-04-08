local TacticalCategory = categories.MOBILE * (categories.LAND + categories.AIR + categories.NAVAL) - categories.ENGINEER - categories.SCOUT - categories.COMMAND
local LandDirectEscortCategory = categories.MOBILE * categories.LAND * categories.DIRECTFIRE - categories.ENGINEER - categories.SCOUT - categories.COMMAND
local LandIndirectCategory = categories.MOBILE * categories.LAND * categories.INDIRECTFIRE - categories.ENGINEER - categories.SCOUT - categories.COMMAND
local LandAACategory = categories.MOBILE * categories.LAND * categories.ANTIAIR - categories.ENGINEER - categories.SCOUT - categories.COMMAND

local function Distance2D(a, b)
    local dx = (a[1] or 0) - (b[1] or 0)
    local dz = (a[3] or 0) - (b[3] or 0)
    return math.sqrt((dx * dx) + (dz * dz))
end

local function LerpPos(a, b, t)
    local clamped = math.max(0, math.min(1, t or 0.5))
    return {
        (a[1] or 0) + (((b[1] or 0) - (a[1] or 0)) * clamped),
        0,
        (a[3] or 0) + (((b[3] or 0) - (a[3] or 0)) * clamped),
    }
end

local function SelectIdleUnits(aiBrain, maxCount)
    local units = aiBrain:GetListOfUnits(TacticalCategory, false, true)
    if not units or table.getn(units) == 0 then
        return {}
    end

    local out = {}
    local n = 0
    for _, unit in units do
        if unit and not unit.Dead then
            local q = unit.GetCommandQueue and unit:GetCommandQueue() or false
            if not q or table.getn(q) == 0 then
                table.insert(out, unit)
                n = n + 1
                if n >= maxCount then
                    break
                end
            end
        end
    end
    return out
end

local function HasSoloIndirectProblem(aiBrain, units)
    local indirect = 0
    local escorts = 0
    for _, unit in units do
        if unit and not unit.Dead then
            if EntityCategoryContains(LandIndirectCategory, unit) then
                indirect = indirect + 1
            elseif EntityCategoryContains(LandDirectEscortCategory + LandAACategory, unit) then
                escorts = escorts + 1
            end
        end
    end
    return indirect >= 2 and escorts < (indirect * 2)
end

local function SplitUnits(units, firstCount)
    local first = {}
    local second = {}
    local count = 0
    local limit = math.max(0, math.floor(firstCount or 0))
    for _, unit in units do
        if count < limit then
            table.insert(first, unit)
        else
            table.insert(second, unit)
        end
        count = count + 1
    end
    return first, second
end

local function FindFallback(aiBrain, runtime)
    local ownPos = runtime.ZoneModel and runtime.ZoneModel.OwnMainPos
    if ownPos then
        return ownPos
    end

    local sx, sz = aiBrain:GetArmyStartPos()
    return { sx, 0, sz }
end

local function FindGoalTarget(runtime)
    local graph = runtime.ZoneGraph or {}
    local goal = runtime.StrategyGoal or 'hold'
    local zone = runtime.ZoneModel or {}
    if runtime.StrategyFocusPos then
        return runtime.StrategyFocusPos
    end

    if goal == 'raid' and graph.BestRaidPos then
        return graph.BestRaidPos
    end
    if (goal == 'expand' or goal == 'tech') and graph.BestExpansionPos then
        return graph.BestExpansionPos
    end
    if graph.FrontLinePos and goal == 'hold' then
        return graph.FrontLinePos
    end
    if graph.BestRaidPos then
        return graph.BestRaidPos
    end
    if graph.BestExpansionPos then
        return graph.BestExpansionPos
    end

    if goal == 'raid' and zone.BestRaidPos then
        return zone.BestRaidPos
    end
    if (goal == 'expand' or goal == 'tech') and zone.BestExpansionPos then
        return zone.BestExpansionPos
    end
    if zone.BestRaidPos then
        return zone.BestRaidPos
    end
    return zone.BestExpansionPos
end

function Update(aiBrain, now)
    local runtime = aiBrain.OvermindRuntime
    if not runtime or not runtime.ZoneModel then
        return
    end

    if now - (runtime.LastPressureTime or -999) < 6 then
        return
    end

    local fallback = FindFallback(aiBrain, runtime)
    local target = FindGoalTarget(runtime)
    if not target then
        return
    end

    local ownThreat = aiBrain:GetThreatAtPosition(fallback, 1, true, 'AntiSurface') or 0
    local targetThreat = aiBrain:GetThreatAtPosition(target, 1, true, 'AntiSurface') or 0
    local aggression = (runtime.Aggression or 1) + (runtime.GoalAggressionModifier or 0)
    local relativePower = (runtime.OpponentModel and runtime.OpponentModel.RelativePower) or 1
    local recovery = runtime.Recovery or {}
    local inRecovery = recovery.ForceFactoryRecovery or recovery.ForceBaseEngineerRecovery or (recovery.StagnationTime or 0) > 90

    local retreat = false
    if ownThreat > 10 and targetThreat > ownThreat * 1.3 then
        retreat = true
    end
    if runtime.StrategyGoal == 'hold' and ownThreat > 6 then
        retreat = true
    end
    if relativePower < 0.85 and targetThreat > ownThreat * 1.05 then
        retreat = true
    end
    if inRecovery then
        retreat = true
    end

    local maxUnits = math.floor(10 + aggression * 18)
    if inRecovery then
        maxUnits = math.floor(maxUnits * 0.62)
    end
    if runtime.Budget and runtime.Budget.LoadFactor and runtime.Budget.LoadFactor > 2.5 then
        maxUnits = math.floor(maxUnits * 0.75)
    end
    maxUnits = math.max(8, math.min(72, maxUnits))

    local units = SelectIdleUnits(aiBrain, maxUnits)
    if table.getn(units) == 0 then
        return
    end

    local distance = Distance2D(fallback, target)
    local staging = LerpPos(fallback, target, 0.44)
    local minGroup = (now < 600) and 10 or 8
    if table.getn(units) < minGroup then
        if IssueMove then
            IssueMove(units, staging)
        end
        runtime.LastTacticalOrder = 'staging_small_group'
        runtime.LastTacticalTime = now
        runtime.LastTacticalCount = table.getn(units)
        return
    end

    if HasSoloIndirectProblem(aiBrain, units) then
        if IssueMove then
            IssueMove(units, staging)
        end
        runtime.LastTacticalOrder = 'staging_indirect_escort'
        runtime.LastTacticalTime = now
        runtime.LastTacticalCount = table.getn(units)
        return
    end

    if retreat then
        local reserveSize = math.max(3, math.floor(table.getn(units) * 0.65))
        local defenders, reserve = SplitUnits(units, reserveSize)
        if table.getn(defenders) > 0 and IssueMove then
            IssueMove(defenders, fallback)
        end
        if table.getn(reserve) > 0 and IssueAggressiveMove then
            IssueAggressiveMove(reserve, fallback)
        end
        runtime.LastTacticalOrder = 'retreat'
    else
        local shouldReserve = runtime.StrategyGoal == 'hold' or ownThreat > 8
        if shouldReserve and table.getn(units) >= 12 then
            local attackers, reserve = SplitUnits(units, math.floor(table.getn(units) * 0.72))
            if table.getn(attackers) > 0 then
                if distance > 150 and IssueMove then
                    IssueMove(attackers, LerpPos(fallback, target, 0.58))
                end
                if IssueAggressiveMove and distance > 20 then
                    IssueAggressiveMove(attackers, target)
                elseif IssueMove then
                    IssueMove(attackers, target)
                end
            end
            if table.getn(reserve) > 0 and IssueMove then
                IssueMove(reserve, fallback)
            end
            runtime.LastTacticalOrder = 'advance_with_reserve'
        elseif IssueAggressiveMove and distance > 20 then
            if distance > 150 and IssueMove then
                IssueMove(units, LerpPos(fallback, target, 0.6))
            end
            IssueAggressiveMove(units, target)
            runtime.LastTacticalOrder = distance > 150 and 'stage_advance' or 'advance'
        elseif IssueMove then
            IssueMove(units, target)
            runtime.LastTacticalOrder = 'advance_move'
        end
    end

    runtime.LastTacticalTime = now
    runtime.LastTacticalCount = table.getn(units)
end
