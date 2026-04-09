local OvermindMemory = import('/mods/OvermindAI/lua/AI/Overmind/Memory.lua')
local OvermindRoleWeights = import('/mods/OvermindAI/lua/AI/Overmind/RoleWeights.lua')

local PressureCategory = categories.MOBILE * (categories.LAND + categories.AIR) - categories.ENGINEER - categories.SCOUT - categories.COMMAND
local LandPressureCategory = categories.MOBILE * categories.LAND - categories.ENGINEER - categories.SCOUT - categories.COMMAND
local LandDirectEscortCategory = categories.MOBILE * categories.LAND * categories.DIRECTFIRE - categories.ENGINEER - categories.SCOUT - categories.COMMAND
local LandIndirectCategory = categories.MOBILE * categories.LAND * categories.INDIRECTFIRE - categories.ENGINEER - categories.SCOUT - categories.COMMAND
local LandAACategory = categories.MOBILE * categories.LAND * categories.ANTIAIR - categories.ENGINEER - categories.SCOUT - categories.COMMAND
local LandHeavyCategory = categories.MOBILE * categories.LAND * categories.DIRECTFIRE * (categories.TECH2 + categories.TECH3)
    - categories.ENGINEER - categories.SCOUT - categories.ANTIAIR - categories.COMMAND

local function Distance2D(a, b)
    local dx = (a[1] or 0) - (b[1] or 0)
    local dz = (a[3] or 0) - (b[3] or 0)
    return math.sqrt((dx * dx) + (dz * dz))
end

local function LerpPos(a, b, t)
    if not a or not b then
        return b or a
    end
    local clampedT = math.max(0, math.min(1, t or 0.5))
    return {
        a[1] + ((b[1] - a[1]) * clampedT),
        0,
        a[3] + ((b[3] - a[3]) * clampedT),
    }
end

local function BuildDetourPoint(fromPos, toPos, sideBias)
    if not fromPos or not toPos then
        return toPos or fromPos
    end
    local mid = LerpPos(fromPos, toPos, 0.5)
    local dx = (toPos[1] or 0) - (fromPos[1] or 0)
    local dz = (toPos[3] or 0) - (fromPos[3] or 0)
    local mag = math.sqrt((dx * dx) + (dz * dz))
    if mag < 0.001 then
        return mid
    end
    local nx = -dz / mag
    local nz = dx / mag
    local side = (math.mod((sideBias or 1), 2) == 0) and -1 or 1
    local offset = 24
    return {
        (mid[1] or 0) + (nx * offset * side),
        0,
        (mid[3] or 0) + (nz * offset * side),
    }
end

local function RetreatFromEnemy(homePos, enemyPos, factor)
    if not homePos then
        return false
    end
    if not enemyPos then
        return homePos
    end

    local k = factor or 0.35
    return {
        (homePos[1] or 0) + (((homePos[1] or 0) - (enemyPos[1] or 0)) * k),
        0,
        (homePos[3] or 0) + (((homePos[3] or 0) - (enemyPos[3] or 0)) * k),
    }
end

local function MoveAwayFromEnemy(pos, enemyPos, distance)
    if not pos or not enemyPos then
        return pos
    end
    local dx = (pos[1] or 0) - (enemyPos[1] or 0)
    local dz = (pos[3] or 0) - (enemyPos[3] or 0)
    local mag = math.sqrt((dx * dx) + (dz * dz))
    if mag < 0.001 then
        return { (pos[1] or 0) + distance, 0, (pos[3] or 0) }
    end
    local scale = (distance or 12) / mag
    return {
        (pos[1] or 0) + (dx * scale),
        0,
        (pos[3] or 0) + (dz * scale),
    }
end

local function IsBrainValid(brain)
    return brain and not brain:IsDefeated()
end

local function GetBrainAnchorPosition(aiBrain)
    if aiBrain.BuilderManagers and aiBrain.BuilderManagers['MAIN'] and aiBrain.BuilderManagers['MAIN'].Position then
        return aiBrain.BuilderManagers['MAIN'].Position
    end

    local acu = aiBrain:GetListOfUnits(categories.COMMAND, false, true)
    if acu and table.getn(acu) > 0 then
        return acu[1]:GetPosition()
    end

    return false
end

local function SplitUnits(units, firstCount)
    local first = {}
    local second = {}
    local cap = math.max(0, math.floor(firstCount or 0))
    local n = 0
    for _, unit in units do
        if n < cap then
            table.insert(first, unit)
        else
            table.insert(second, unit)
        end
        n = n + 1
    end
    return first, second
end

local function PartitionLandUnits(units)
    local direct = {}
    local aa = {}
    local indirect = {}
    local other = {}
    for _, unit in units do
        if unit and not unit.Dead then
            if EntityCategoryContains(LandIndirectCategory, unit) then
                table.insert(indirect, unit)
            elseif EntityCategoryContains(LandAACategory, unit) then
                table.insert(aa, unit)
            elseif EntityCategoryContains(LandDirectEscortCategory, unit) then
                table.insert(direct, unit)
            else
                table.insert(other, unit)
            end
        end
    end
    return direct, aa, indirect, other
end

local function GetNearestEnemyBasePosition(aiBrain, ownPos)
    local nearestPos = false
    local nearestDist = 100000

    for _, enemyBrain in ArmyBrains do
        local isEnemy = false
        if IsEnemy then
            isEnemy = IsEnemy(enemyBrain:GetArmyIndex(), aiBrain:GetArmyIndex())
        end

        if enemyBrain ~= aiBrain and IsBrainValid(enemyBrain) and isEnemy then
            local enemyPos = GetBrainAnchorPosition(enemyBrain)
            if enemyPos then
                local dist = Distance2D(ownPos, enemyPos)
                if dist < nearestDist then
                    nearestDist = dist
                    nearestPos = enemyPos
                end
            end
        end
    end

    return nearestPos
end

local function GetStrongestNearbyEnemyPosition(aiBrain, ownPos)
    local enemyUnits = aiBrain:GetUnitsAroundPoint(categories.MOBILE - categories.SCOUT, ownPos, 170, 'Enemy')
    if enemyUnits and table.getn(enemyUnits) > 0 and enemyUnits[1] then
        return enemyUnits[1]:GetPosition()
    end

    return false
end

local function SelectPressureTarget(runtime, ownPos, defaultEnemyPos)
    local goal = runtime.StrategyGoal or 'hold'
    local zone = runtime.ZoneModel or {}

    if goal == 'raid' and zone.BestRaidPos then
        return zone.BestRaidPos
    end
    if goal == 'expand' and zone.BestExpansionPos then
        return LerpPos(ownPos, zone.BestExpansionPos, 0.85)
    end
    if goal == 'all_in' and defaultEnemyPos then
        return defaultEnemyPos
    end
    if zone.BestRaidPos then
        return zone.BestRaidPos
    end
    if zone.BestExpansionPos then
        return zone.BestExpansionPos
    end
    return defaultEnemyPos
end

local function GetUnitsCentroid(units)
    local sx = 0
    local sz = 0
    local n = 0
    for _, unit in units do
        if unit and not unit.Dead and unit.GetPosition then
            local pos = unit:GetPosition()
            if pos then
                sx = sx + (pos[1] or 0)
                sz = sz + (pos[3] or 0)
                n = n + 1
            end
        end
    end
    if n <= 0 then
        return false
    end
    return { sx / n, 0, sz / n }
end

local function MergeUnitTables(a, b, c)
    local out = {}
    for _, unit in a or {} do
        table.insert(out, unit)
    end
    for _, unit in b or {} do
        table.insert(out, unit)
    end
    for _, unit in c or {} do
        table.insert(out, unit)
    end
    return out
end

local function GetUnitsAroundPointSafe(aiBrain, category, pos, radius, alliance)
    if not pos then
        return {}
    end
    local units = aiBrain:GetUnitsAroundPoint(category, pos, radius, alliance)
    return units or {}
end

local function GetLocalLandStrength(aiBrain, pos, radius, alliance)
    local units = GetUnitsAroundPointSafe(aiBrain, LandPressureCategory, pos, radius, alliance)
    return OvermindRoleWeights.SumUnitStrength(units), units
end

local function SelectReadyUnitsFromList(units, maxCount)
    local selected = {}
    local limit = math.max(0, math.floor(maxCount or 0))
    for _, unit in units or {} do
        if unit and not unit.Dead then
            local q = unit.GetCommandQueue and unit:GetCommandQueue() or false
            local qLen = q and table.getn(q) or 0
            if qLen <= 1 then
                table.insert(selected, unit)
                if limit > 0 and table.getn(selected) >= limit then
                    break
                end
            end
        end
    end
    return selected
end

local function ResolveTaskUnits(task, fallbackUnits, maxCount)
    local taskUnits = {}
    if task and task.AssignedUnitRefs then
        taskUnits = task.AssignedUnitRefs
    else
        taskUnits = fallbackUnits or {}
    end
    return SelectReadyUnitsFromList(taskUnits, maxCount)
end

local function ResolvePersistentTaskUnits(task, fallbackUnits, maxCount)
    local selected = {}
    local limit = math.max(0, math.floor(maxCount or 0))
    if limit <= 0 then
        return selected
    end
    local taskUnits = (task and task.AssignedUnitRefs) or fallbackUnits or {}
    for _, unit in taskUnits do
        if unit and not unit.Dead then
            local q = unit.GetCommandQueue and unit:GetCommandQueue() or false
            local qLen = q and table.getn(q) or 0
            if qLen <= 4 or unit:IsUnitState('Moving') then
                table.insert(selected, unit)
                if table.getn(selected) >= limit then
                    break
                end
            end
        end
    end
    return selected
end

local function SetTaskExecution(task, now, executionState, orderClass, targetPos, stagePos, issuedCount)
    if not task then
        return
    end
    task.ExecutionState = executionState or task.ExecutionState or 'idle'
    task.LastIssuedAt = now
    task.LastCommand = orderClass or task.LastCommand or 'none'
    task.LastIssuedTarget = targetPos and { targetPos[1] or 0, targetPos[2] or 0, targetPos[3] or 0 } or task.LastIssuedTarget
    task.LastStagePos = stagePos and { stagePos[1] or 0, stagePos[2] or 0, stagePos[3] or 0 } or task.LastStagePos
    task.LastIssuedCount = issuedCount or task.LastIssuedCount or 0
end

local function GetGraphAdvanceTarget(runtime, routeName, fallbackPos)
    local graph = runtime and runtime.ZoneGraph or {}
    local path = false
    if routeName == 'raid' then
        path = graph.PathToRaid
    elseif routeName == 'expansion' then
        path = graph.PathToExpansion
    elseif routeName == 'front' then
        path = graph.PathToFront
    else
        path = graph.PathToEnemy
    end

    if path and table.getn(path) >= 2 then
        return path[math.min(2, table.getn(path))]
    end
    return fallbackPos
end

local function SelectIdlePressureUnits(aiBrain, maxCount, ownPos, targetPos)
    local units = aiBrain:GetListOfUnits(LandPressureCategory, false, true)
    if not units or table.getn(units) == 0 then
        return {}
    end

    local staging = targetPos and LerpPos(ownPos, targetPos, 0.4) or ownPos
    local selected = {}
    local selectedCount = 0

    for _, unit in units do
        if unit and not unit.Dead then
            local cmdQueue = false
            if unit.GetCommandQueue then
                cmdQueue = unit:GetCommandQueue()
            end

            if not cmdQueue or table.getn(cmdQueue) == 0 then
                local skip = false
                local isIndirect = EntityCategoryContains(LandIndirectCategory, unit)
                if isIndirect then
                    local pos = unit:GetPosition()
                    if pos then
                        local escort = aiBrain:GetNumUnitsAroundPoint(LandDirectEscortCategory + LandAACategory, pos, 24, 'Ally') or 0
                        local enemies = aiBrain:GetNumUnitsAroundPoint(LandPressureCategory, pos, 26, 'Enemy') or 0
                        if escort < 2 or enemies > (escort + 1) then
                            if IssueMove and staging then
                                IssueMove({ unit }, staging)
                            end
                            skip = true
                        end
                    end
                elseif EntityCategoryContains(LandHeavyCategory, unit) then
                    local pos = unit:GetPosition()
                    if pos then
                        local directEscort = aiBrain:GetNumUnitsAroundPoint(LandDirectEscortCategory, pos, 24, 'Ally') or 0
                        local aaEscort = aiBrain:GetNumUnitsAroundPoint(LandAACategory, pos, 24, 'Ally') or 0
                        local enemies = aiBrain:GetNumUnitsAroundPoint(LandPressureCategory, pos, 28, 'Enemy') or 0
                        local support = math.max(0, directEscort - 1) + aaEscort
                        if support < 2 and (enemies > 0 or Distance2D(pos, staging) > 26) then
                            if IssueMove and staging then
                                IssueMove({ unit }, staging)
                            end
                            skip = true
                        end
                    end
                end

                if not skip then
                    table.insert(selected, unit)
                    selectedCount = selectedCount + 1
                    if selectedCount >= maxCount then
                        break
                    end
                end
            end
        end
    end

    return selected
end

local function ManageIndirectStandoff(aiBrain, ownPos, targetPos, directUnits, aaUnits, indirectUnits, defensive)
    if not indirectUnits or table.getn(indirectUnits) <= 0 then
        return 0
    end

    local escorts = table.getn(directUnits or {}) + table.getn(aaUnits or {})
    local issued = 0
    local defaultRear = LerpPos(ownPos, targetPos, defensive and 0.22 or 0.42)
    for _, unit in indirectUnits do
        if unit and not unit.Dead and unit.GetPosition then
            local pos = unit:GetPosition()
            if pos then
                local enemies = aiBrain:GetUnitsAroundPoint(LandPressureCategory, pos, 68, 'Enemy')
                local enemyCount = enemies and table.getn(enemies) or 0
                local enemyPos = false
                if enemyCount > 0 and enemies[1] and enemies[1].GetPosition then
                    enemyPos = enemies[1]:GetPosition()
                end

                if enemyPos then
                    local dist = Distance2D(pos, enemyPos)
                    local desiredMin = 36
                    local desiredMax = 55
                    if dist < desiredMin then
                        local retreat = MoveAwayFromEnemy(pos, enemyPos, desiredMin - dist + 10)
                        if IssueMove then
                            IssueMove({ unit }, retreat)
                            issued = issued + 1
                        end
                    elseif dist <= desiredMax then
                        if IssueAggressiveMove then
                            IssueAggressiveMove({ unit }, enemyPos)
                            issued = issued + 1
                        end
                    else
                        local closeIn = LerpPos(pos, enemyPos, 0.4)
                        if IssueMove then
                            IssueMove({ unit }, closeIn)
                            issued = issued + 1
                        end
                    end

                    if enemyCount > math.max(3, escorts + 1) and dist < 44 then
                        local panicBack = MoveAwayFromEnemy(pos, enemyPos, 16)
                        if IssueMove then
                            IssueMove({ unit }, panicBack)
                            issued = issued + 1
                        end
                    end
                else
                    if IssueMove and defaultRear then
                        IssueMove({ unit }, defaultRear)
                        issued = issued + 1
                    end
                end
            end
        end
    end

    return issued
end

local HasUnsupportedAAPosture

local function IssueCohesiveLandOrders(aiBrain, ownPos, targetPos, allUnits, defensive)
    if not allUnits or table.getn(allUnits) <= 0 or not targetPos then
        return false
    end
    local direct, aa, indirect, other = PartitionLandUnits(allUnits)
    local comp = {
        Direct = table.getn(direct),
        AA = table.getn(aa),
        Indirect = table.getn(indirect),
        Heavy = 0,
    }
    for _, unit in direct do
        if unit and not unit.Dead and EntityCategoryContains(LandHeavyCategory, unit) then
            comp.Heavy = comp.Heavy + 1
        end
    end
    local frontT = defensive and 0.36 or 0.58
    local rearT = defensive and 0.22 or 0.42
    local flankT = defensive and 0.3 or 0.5
    local front = LerpPos(ownPos, targetPos, frontT)
    local rear = LerpPos(ownPos, targetPos, rearT)
    local flank = LerpPos(ownPos, targetPos, flankT)
    local directAttackPos = (not defensive and Distance2D(front, targetPos) <= 28) and targetPos or front
    local unsupportedAA = HasUnsupportedAAPosture and HasUnsupportedAAPosture(comp, defensive)

    if table.getn(direct) > 0 then
        if IssueMove then
            IssueMove(direct, front)
        end
        if IssueAggressiveMove then
            IssueAggressiveMove(direct, directAttackPos)
        end
    end

    if table.getn(aa) > 0 then
        if table.getn(direct) > 0 and not unsupportedAA then
            if IssueMove then
                IssueMove(aa, flank)
            end
            if not defensive and IssueAggressiveMove then
                IssueAggressiveMove(aa, flank)
            end
        else
            if IssueMove then
                IssueMove(aa, rear)
            end
        end
    end

    if table.getn(indirect) > 0 then
        ManageIndirectStandoff(aiBrain, ownPos, targetPos, direct, aa, indirect, defensive)
    end

    if table.getn(other) > 0 and IssueMove then
        IssueMove(other, front)
    end

    return true
end

local function CountLandComposition(units)
    local out = {
        Tank = 0,
        Direct = 0,
        Heavy = 0,
        AA = 0,
        Indirect = 0,
        Total = table.getn(units),
    }

    for _, unit in units do
        if unit and not unit.Dead then
            if EntityCategoryContains(LandIndirectCategory, unit) then
                out.Indirect = out.Indirect + 1
            elseif EntityCategoryContains(LandAACategory, unit) then
                out.AA = out.AA + 1
            elseif EntityCategoryContains(LandDirectEscortCategory, unit) then
                out.Direct = out.Direct + 1
                out.Tank = out.Tank + 1
                if EntityCategoryContains(LandHeavyCategory, unit) then
                    out.Heavy = out.Heavy + 1
                end
            end
        end
    end

    return out
end

local function GetDirectEscortSupport(comp)
    local direct = comp.Direct or comp.Tank or 0
    local heavy = comp.Heavy or 0
    local aa = comp.AA or 0
    return math.max(0, direct - heavy) + aa
end

local function HasIndirectEscortGap(comp)
    local indirect = comp.Indirect or 0
    if indirect <= 0 then
        return false
    end
    return GetDirectEscortSupport(comp) < math.max(2, indirect * 2)
end

local function HasHeavyEscortGap(comp)
    local heavy = comp.Heavy or 0
    if heavy <= 0 then
        return false
    end
    local support = GetDirectEscortSupport(comp)
    local aa = comp.AA or 0
    return support < math.max(2, heavy + 1) or (heavy >= 2 and aa < 1)
end

HasUnsupportedAAPosture = function(comp, defensive)
    local aa = comp.AA or 0
    if aa <= 0 then
        return false
    end

    local direct = comp.Direct or comp.Tank or 0
    local indirect = comp.Indirect or 0
    local heavy = comp.Heavy or 0
    if defensive then
        return direct <= 0 and indirect <= 0 and heavy <= 0
    end
    if direct <= 0 and indirect <= 0 and heavy <= 0 then
        return true
    end
    if direct <= 1 and aa >= math.max(3, indirect + heavy + 2) then
        return true
    end
    return aa >= math.max(4, direct + heavy + 2)
end

local function EvaluateLandCohortPosture(aiBrain, ownPos, targetPos, units, comp, defensive)
    if not units or table.getn(units) <= 0 or not targetPos then
        return 'hold', ownPos
    end

    local centroid = GetUnitsCentroid(units) or ownPos
    local stagePos = LerpPos(ownPos, targetPos, defensive and 0.28 or 0.4)
    local frontPos = LerpPos(ownPos, targetPos, defensive and 0.34 or 0.56)

    if HasIndirectEscortGap(comp) or HasHeavyEscortGap(comp) or HasUnsupportedAAPosture(comp, defensive) then
        return 'regroup', stagePos
    end

    local ownStrength = OvermindRoleWeights.SumUnitStrength(units)
    local enemyFrontStrength = GetLocalLandStrength(aiBrain, frontPos, defensive and 46 or 52, 'Enemy')
    local enemyCentroidStrength = GetLocalLandStrength(aiBrain, centroid, 36, 'Enemy')
    local nearbyAlliedStrength = GetLocalLandStrength(aiBrain, centroid, 34, 'Ally')
    local localAdvantage = ownStrength + math.max(0, (nearbyAlliedStrength or 0) - ownStrength)
    local strongestEnemy = math.max(enemyFrontStrength or 0, enemyCentroidStrength or 0)

    if strongestEnemy > (localAdvantage * (defensive and 1.32 or 1.18)) then
        return defensive and 'retreat' or 'regroup', stagePos
    end

    return 'commit', frontPos
end

local function RegroupIsolatedLand(aiBrain, ownPos, targetPos, maxCount, inRecovery)
    local units = aiBrain:GetListOfUnits(LandPressureCategory, false, true)
    if not units or table.getn(units) == 0 then
        return 0
    end

    local regroup = {}
    local stagedTarget = targetPos and LerpPos(ownPos, targetPos, 0.35) or ownPos
    for _, unit in units do
        if unit and not unit.Dead then
            local q = unit.GetCommandQueue and unit:GetCommandQueue() or false
            local qLen = q and table.getn(q) or 0
            if qLen <= 1 then
                local pos = unit:GetPosition()
                if pos then
                    local distHome = Distance2D(pos, ownPos)
                    local alliesNearby = aiBrain:GetNumUnitsAroundPoint(LandPressureCategory, pos, 24, 'Ally') or 0
                    local enemiesNearby = aiBrain:GetNumUnitsAroundPoint(PressureCategory, pos, 28, 'Enemy') or 0
                    local tooFarSolo = distHome > 72 and alliesNearby <= 2
                    local exposed = enemiesNearby > alliesNearby and distHome > 48
                    if tooFarSolo and (inRecovery or exposed or enemiesNearby > 0) then
                        table.insert(regroup, unit)
                        if table.getn(regroup) >= maxCount then
                            break
                        end
                    end
                end
            end
        end
    end

    if table.getn(regroup) <= 0 then
        return 0
    end

    if IssueMove then
        IssueMove(regroup, stagedTarget)
    end
    return table.getn(regroup)
end


function RunPressureCycle(aiBrain, now)
    local runtime = aiBrain.OvermindRuntime
    if not runtime then
        return
    end

    local ownPos = runtime.OwnMainPos or GetBrainAnchorPosition(aiBrain)
    local primaryEnemyPos = runtime.PrimaryEnemyPos
    if not ownPos then
        return
    end

    if not primaryEnemyPos then
        primaryEnemyPos = GetNearestEnemyBasePosition(aiBrain, ownPos)
        runtime.PrimaryEnemyPos = primaryEnemyPos
    end

    if not primaryEnemyPos then
        return
    end

    local aggression = runtime.Aggression or 1
    local ecoState = runtime.EcoState or {}
    local combatMomentum = runtime.CombatMomentum or 0
    local opp = runtime.OpponentModel or {}
    local intel = runtime.IntelModel or {}
    local force = runtime.ForceDirector or runtime.ForceManager or {}
    local groups = force.Groups or {}
    local tasks = force.Tasks or {}
    local frontTask = tasks.front_hold
    local artilleryTask = tasks.artillery_support
    local baseTask = tasks.base_guard
    local escortTask = tasks.acu_escort
    local acuEmergencyTask = tasks.acu_emergency_intercept
    local interceptTask = tasks.intercept_cluster
    local raidTask = tasks.raid
    local homeThreat = (runtime.ZoneModel and runtime.ZoneModel.HomeThreat) or 0
    local recovery = runtime.Recovery or {}
    local inRecovery = recovery.ForceFactoryRecovery or recovery.ForceBaseEngineerRecovery or (recovery.StagnationTime or 0) > 90
    local clusterState = runtime.EnemyClusterTracker or {}
    local approachCluster = clusterState.ApproachCluster or false
    local regrouped = RegroupIsolatedLand(aiBrain, ownPos, primaryEnemyPos, inRecovery and 8 or 4, inRecovery)

    local maxUnits = math.min(78, math.floor(12 + aggression * 18))
    if runtime.StrategyGoal == 'hold' then
        maxUnits = math.floor(maxUnits * 0.7)
    elseif runtime.StrategyGoal == 'all_in' then
        maxUnits = math.floor(maxUnits * 1.15)
    elseif runtime.StrategyGoal == 'raid' then
        maxUnits = math.floor(maxUnits * 0.9)
    end
    if ecoState.StallingMass then
        maxUnits = math.max(8, math.floor(maxUnits * 0.8))
    end
    if inRecovery then
        maxUnits = math.max(6, math.floor(maxUnits * 0.55))
    end

    local frontReady = ResolveTaskUnits(frontTask, groups.MainLine or {}, maxUnits)
    local remainingSlots = math.max(0, maxUnits - table.getn(frontReady))
    local artilleryReady = ResolveTaskUnits(artilleryTask, groups.Artillery or {}, remainingSlots)
    local pressureUnits = MergeUnitTables(frontReady, artilleryReady, {})
    local pressureCount = table.getn(pressureUnits)
    if pressureCount <= 0 then
        pressureUnits = SelectIdlePressureUnits(aiBrain, maxUnits, ownPos, primaryEnemyPos)
        pressureCount = table.getn(pressureUnits)
    end
    local baseGuardLimit = math.max(4, math.floor(maxUnits * 0.38))
    local guardReady = ResolveTaskUnits(baseTask, groups.BaseGuard or {}, baseGuardLimit)
    local escortReady = ResolveTaskUnits(escortTask, groups.ACUEscort or {}, math.max(0, baseGuardLimit - table.getn(guardReady)))
    local baseGuardUnits = MergeUnitTables(guardReady, escortReady, {})
    local baseGuardCount = table.getn(baseGuardUnits)
    local acuEmergencyUnits = ResolvePersistentTaskUnits(acuEmergencyTask, groups.ACUEmergency or {}, math.max(8, math.floor(maxUnits * 0.52)))
    local acuEmergencyCount = table.getn(acuEmergencyUnits)
    local raidUnits = ResolveTaskUnits(raidTask, groups.Raiders or {}, math.max(2, math.floor(maxUnits * 0.24)))
    local raidCount = table.getn(raidUnits)
    local interceptUnits = ResolveTaskUnits(interceptTask, groups.Intercept or {}, math.max(3, math.floor(maxUnits * 0.3)))
    local interceptCount = table.getn(interceptUnits)
    local frontPos = (frontTask and frontTask.TargetPos) or intel.FrontLinePos or (runtime.ZoneModel and runtime.ZoneModel.FrontLinePos) or LerpPos(ownPos, primaryEnemyPos, 0.45)
    local rearGuardPos = (baseTask and (baseTask.TargetPos or baseTask.AnchorPos)) or intel.RearGuardPos or (runtime.ZoneModel and runtime.ZoneModel.RearGuardPos) or ownPos
    local acuPos = GetBrainAnchorPosition(aiBrain) or ownPos
    local acuEnemyUnits = aiBrain:GetUnitsAroundPoint(categories.MOBILE - categories.SCOUT, acuPos, 60, 'Enemy')
    local acuEnemyPos = (acuEmergencyTask and acuEmergencyTask.TargetPos)
        or (acuEnemyUnits and table.getn(acuEnemyUnits) > 0 and acuEnemyUnits[1] and acuEnemyUnits[1]:GetPosition())
        or GetStrongestNearbyEnemyPosition(aiBrain, ownPos)
    local raidTarget = (raidTask and raidTask.TargetPos) or intel.BestRaidPos or (runtime.ZoneModel and runtime.ZoneModel.BestRaidPos) or primaryEnemyPos
    local acuEmergencyActive = acuEnemyPos and acuEmergencyCount > 0
    if pressureCount <= 0 then
        if acuEmergencyActive and IssueCohesiveLandOrders then
            IssueCohesiveLandOrders(aiBrain, ownPos, acuEnemyPos, acuEmergencyUnits, true)
            SetTaskExecution(acuEmergencyTask, now, 'intercepting', 'cohesive-defend', acuEnemyPos, acuPos, acuEmergencyCount)
        end
        if baseGuardCount > 0 and frontPos and IssueMove then
            IssueMove(baseGuardUnits, rearGuardPos)
            SetTaskExecution(baseTask, now, 'holding', 'move', rearGuardPos, rearGuardPos, baseGuardCount)
        end
        if raidCount > 0 and raidTarget and IssueMove then
            local raidStage = (raidTask and raidTask.StagingPos) or LerpPos(ownPos, raidTarget, 0.42)
            IssueMove(raidUnits, raidStage)
            SetTaskExecution(raidTask, now, 'staging', 'move', raidTarget, raidStage, raidCount)
        end
        SetTaskExecution(frontTask, now, 'forming', 'hold', frontPos, frontPos, pressureCount)
        SetTaskExecution(artilleryTask, now, 'screening', 'hold', frontPos, frontPos, table.getn(artilleryReady))
        return
    end

    runtime.PressurePathState = runtime.PressurePathState or {
        LastCentroid = false,
        LastMoveTime = now,
        LastReplanTime = -999,
        SideBias = 1,
    }
    local pathState = runtime.PressurePathState
    local centroid = GetUnitsCentroid(pressureUnits)
    if centroid then
        local moved = pathState.LastCentroid and Distance2D(centroid, pathState.LastCentroid) or 9
        if moved >= 3.2 then
            pathState.LastMoveTime = now
            pathState.LastCentroid = centroid
        elseif not pathState.LastCentroid then
            pathState.LastCentroid = centroid
            pathState.LastMoveTime = now
        end
    end

    local toEnemy = Distance2D(ownPos, primaryEnemyPos)
    local stuckFar = centroid
        and (Distance2D(centroid, primaryEnemyPos) > math.max(52, toEnemy * 0.42))
        and ((now - (pathState.LastMoveTime or now)) >= 14)
    if stuckFar and pressureCount >= 6 and (now - (pathState.LastReplanTime or -999)) >= 11 then
        local detour = BuildDetourPoint(centroid, primaryEnemyPos, pathState.SideBias or 1)
        pathState.SideBias = math.mod((pathState.SideBias or 1), 2) + 1
        pathState.LastReplanTime = now
        pathState.LastMoveTime = now
        pathState.LastCentroid = centroid
        if IssueMove then
            IssueMove(pressureUnits, detour)
        end
        if IssueAggressiveMove then
            IssueAggressiveMove(pressureUnits, primaryEnemyPos)
        end
        runtime.LastPressureOrder = 'RepathStuck'
        return
    end

    local comp = CountLandComposition(pressureUnits)

    local enemyNearBase = GetStrongestNearbyEnemyPosition(aiBrain, ownPos)
    local clusterInterceptPos = approachCluster and (approachCluster.StagePos or approachCluster.Pos) or false
    local clusterConfidence = approachCluster and (approachCluster.ContactConfidence or 0) or 0
    local clusterConfirmed = approachCluster
        and (((approachCluster.ConfirmedUnits or 0) > 0) or ((approachCluster.MemoryThreat or 0) >= 1.2))
    local selectedTarget = SelectPressureTarget(runtime, ownPos, primaryEnemyPos)
    if runtime.StrategyGoal == 'hold' and frontPos then
        selectedTarget = frontPos
    elseif runtime.StrategyGoal == 'raid' and raidTarget then
        selectedTarget = raidTarget
    end
    local minCommit = math.max(8, math.floor(10 + aggression * 5))
    if (opp.RelativePower or 1) < 0.9 then
        minCommit = minCommit + 2
    end
    if now < 540 then
        minCommit = minCommit + 2
    end
    if opp.T2Push == true or opp.IndirectHeavy == true then
        minCommit = math.max(8, minCommit - 1)
    end

    local routeName = 'front'
    if runtime.StrategyGoal == 'raid' then
        routeName = 'raid'
    elseif runtime.StrategyGoal == 'expand' then
        routeName = 'expansion'
    end
    local graphAdvance = GetGraphAdvanceTarget(runtime, routeName, selectedTarget)
    local stagingPos = (frontTask and frontTask.StagingPos) or LerpPos(ownPos, graphAdvance or selectedTarget, 0.36)
    local cohortPosture, cohortAnchor = EvaluateLandCohortPosture(aiBrain, ownPos, selectedTarget, pressureUnits, comp, false)
    if acuEmergencyActive then
        IssueCohesiveLandOrders(aiBrain, ownPos, acuEnemyPos, acuEmergencyUnits, true)
        SetTaskExecution(acuEmergencyTask, now, 'intercepting', 'cohesive-defend', acuEnemyPos, acuPos, acuEmergencyCount)
        local emergencyReinforce = {}
        if pressureCount > 0 then
            emergencyReinforce = MergeUnitTables(emergencyReinforce, pressureUnits, {})
        end
        if baseGuardCount > 0 then
            emergencyReinforce = MergeUnitTables(emergencyReinforce, baseGuardUnits, {})
        end
        if raidCount > 0 then
            emergencyReinforce = MergeUnitTables(emergencyReinforce, raidUnits, {})
        end
        if interceptCount > 0 then
            emergencyReinforce = MergeUnitTables(emergencyReinforce, interceptUnits, {})
        end
        if table.getn(emergencyReinforce) >= 6 then
            IssueCohesiveLandOrders(aiBrain, ownPos, acuEnemyPos, emergencyReinforce, true)
            SetTaskExecution(frontTask, now, 'intercepting', 'cohesive-defend', acuEnemyPos, acuPos, table.getn(emergencyReinforce))
            SetTaskExecution(artilleryTask, now, 'screening', 'cohesive-defend', acuEnemyPos, acuPos, table.getn(artilleryReady))
        elseif baseGuardCount > 0 then
            IssueCohesiveLandOrders(aiBrain, ownPos, acuEnemyPos, baseGuardUnits, true)
            SetTaskExecution(baseTask, now, 'defending', 'cohesive-defend', acuEnemyPos, rearGuardPos, baseGuardCount)
        end
        if raidCount > 0 and IssueCohesiveLandOrders then
            IssueCohesiveLandOrders(aiBrain, ownPos, acuEnemyPos, raidUnits, true)
            SetTaskExecution(raidTask, now, 'recalling', 'cohesive-defend', acuEnemyPos, acuPos, raidCount)
        end
        if interceptCount > 0 then
            IssueCohesiveLandOrders(aiBrain, ownPos, acuEnemyPos, interceptUnits, true)
            SetTaskExecution(interceptTask, now, 'intercepting', 'cohesive-defend', acuEnemyPos, acuPos, interceptCount)
        end
        runtime.LastPressureOrder = 'ACUEmergencyIntercept'
        return
    end
    if cohortPosture == 'regroup' and IssueMove then
        IssueMove(pressureUnits, cohortAnchor or stagingPos)
        runtime.LastPressureOrder = HasIndirectEscortGap(comp) and 'RegroupEscort'
            or (HasHeavyEscortGap(comp) and 'RegroupHeavy'
            or (HasUnsupportedAAPosture(comp, false) and 'RegroupAA' or 'Regroup'))
        SetTaskExecution(frontTask, now, 'regrouping', 'move', selectedTarget, cohortAnchor or stagingPos, pressureCount)
        SetTaskExecution(artilleryTask, now, 'screening', 'move', selectedTarget, cohortAnchor or stagingPos, table.getn(artilleryReady))
        return
    elseif cohortPosture == 'retreat' and IssueMove then
        IssueMove(pressureUnits, cohortAnchor or stagingPos)
        runtime.LastPressureOrder = 'RetreatDisadvantage'
        SetTaskExecution(frontTask, now, 'retreating', 'move', selectedTarget, cohortAnchor or stagingPos, pressureCount)
        SetTaskExecution(artilleryTask, now, 'screening', 'move', selectedTarget, cohortAnchor or stagingPos, table.getn(artilleryReady))
        return
    end

    if pressureCount < minCommit then
        if enemyNearBase and baseGuardCount >= 3 then
            IssueCohesiveLandOrders(aiBrain, ownPos, enemyNearBase, baseGuardUnits, true)
            SetTaskExecution(baseTask, now, 'defending', 'cohesive-defend', enemyNearBase, rearGuardPos, baseGuardCount)
        elseif enemyNearBase and pressureCount >= 4 then
            IssueCohesiveLandOrders(aiBrain, ownPos, enemyNearBase, pressureUnits, true)
            SetTaskExecution(frontTask, now, 'defending', 'cohesive-defend', enemyNearBase, frontPos, pressureCount)
            SetTaskExecution(artilleryTask, now, 'screening', 'cohesive-defend', enemyNearBase, frontPos, table.getn(artilleryReady))
        elseif IssueMove then
            IssueMove(pressureUnits, frontPos or stagingPos)
            SetTaskExecution(frontTask, now, 'forming', 'move', frontPos or selectedTarget, frontPos or stagingPos, pressureCount)
            SetTaskExecution(artilleryTask, now, 'screening', 'move', frontPos or selectedTarget, frontPos or stagingPos, table.getn(artilleryReady))
        elseif regrouped > 0 then
            runtime.LastPressureOrder = 'Regroup'
            SetTaskExecution(frontTask, now, 'regrouping', 'regroup', frontPos or selectedTarget, stagingPos, pressureCount)
        end
        if raidCount > 0 and raidTarget and not enemyNearBase then
            if raidCount >= 3 then
                IssueCohesiveLandOrders(aiBrain, ownPos, raidTarget, raidUnits, false)
                runtime.LastRaidOrder = 'Raid'
                SetTaskExecution(raidTask, now, 'raiding', 'cohesive-raid', raidTarget, raidTask and raidTask.StagingPos or ownPos, raidCount)
            elseif IssueMove then
                local raidStage = GetGraphAdvanceTarget(runtime, 'raid', (raidTask and raidTask.StagingPos) or LerpPos(ownPos, raidTarget, 0.52))
                IssueMove(raidUnits, raidStage)
                runtime.LastRaidOrder = 'RaidStage'
                SetTaskExecution(raidTask, now, 'staging', 'move', raidTarget, raidStage, raidCount)
            end
        end
        return
    end

    local shouldDefend = enemyNearBase and (combatMomentum < -0.15 or aggression < 0.95 or homeThreat > 9 or inRecovery)
    local shouldSplit = shouldDefend
        and pressureCount >= 14
        and runtime.StrategyGoal ~= 'hold'
        and not (opp.T2Push == true or opp.IndirectHeavy == true)
    local shouldInterceptCluster = not enemyNearBase
        and approachCluster
        and clusterInterceptPos
        and clusterConfirmed
        and clusterConfidence >= 0.38
        and (approachCluster.Approaching or (approachCluster.HomeDistance or 999) < 220)
        and (approachCluster.TotalThreat or 0) >= 4.5
        and (approachCluster.HomeDistance or 999) < 280
        and (interceptCount >= 3 or pressureCount >= 16 or not (opp.T2Push == true or opp.IndirectHeavy == true))
    if shouldInterceptCluster then
        local activeInterceptUnits = interceptCount > 0 and interceptUnits or pressureUnits
        local activeInterceptCount = table.getn(activeInterceptUnits)
        if IssueMove and activeInterceptCount > 0 then
            IssueMove(activeInterceptUnits, clusterInterceptPos)
        end
        if (approachCluster.HomeDistance or 999) < 150 and activeInterceptCount > 0 then
            IssueCohesiveLandOrders(aiBrain, ownPos, approachCluster.Pos or clusterInterceptPos, activeInterceptUnits, true)
            SetTaskExecution(interceptTask, now, 'intercepting', 'cohesive-intercept', approachCluster.Pos or clusterInterceptPos, clusterInterceptPos, activeInterceptCount)
            if activeInterceptUnits == pressureUnits then
                SetTaskExecution(frontTask, now, 'intercepting', 'cohesive-intercept', approachCluster.Pos or clusterInterceptPos, clusterInterceptPos, pressureCount)
                SetTaskExecution(artilleryTask, now, 'screening', 'cohesive-intercept', approachCluster.Pos or clusterInterceptPos, clusterInterceptPos, table.getn(artilleryReady))
            end
        else
            SetTaskExecution(interceptTask, now, 'intercepting', 'move', approachCluster.Pos or clusterInterceptPos, clusterInterceptPos, activeInterceptCount)
            if activeInterceptUnits == pressureUnits then
                SetTaskExecution(frontTask, now, 'intercepting', 'move', approachCluster.Pos or clusterInterceptPos, clusterInterceptPos, pressureCount)
                SetTaskExecution(artilleryTask, now, 'screening', 'move', approachCluster.Pos or clusterInterceptPos, clusterInterceptPos, table.getn(artilleryReady))
            end
        end
        if activeInterceptUnits ~= pressureUnits and pressureCount > 0 then
            if IssueMove then
                IssueMove(pressureUnits, frontPos or stagingPos)
            end
            SetTaskExecution(frontTask, now, 'holding', 'cluster-cover', selectedTarget, frontPos or stagingPos, pressureCount)
            SetTaskExecution(artilleryTask, now, 'screening', 'cluster-cover', selectedTarget, frontPos or stagingPos, table.getn(artilleryReady))
        end
        if baseGuardCount > 0 and IssueMove then
            IssueMove(baseGuardUnits, rearGuardPos)
            SetTaskExecution(baseTask, now, 'holding', 'move', rearGuardPos, rearGuardPos, baseGuardCount)
        end
        runtime.LastPressureOrder = 'InterceptCluster'
        return
    end
    if shouldDefend then
        if enemyNearBase then
            local closeThreat = aiBrain:GetThreatAtPosition(enemyNearBase, 2, true, 'AntiSurface') or 0
            if closeThreat > 1 then
                OvermindMemory.RecordThreatSpike(aiBrain, enemyNearBase, closeThreat)
            end
        end
        if baseGuardCount > 0 then
            IssueCohesiveLandOrders(aiBrain, ownPos, enemyNearBase, baseGuardUnits, true)
            SetTaskExecution(baseTask, now, 'defending', 'cohesive-defend', enemyNearBase, rearGuardPos, baseGuardCount)
        end
        if shouldSplit then
            local defenders, attackers = SplitUnits(pressureUnits, math.floor(pressureCount * 0.58))
            if table.getn(defenders) > 0 then
                IssueCohesiveLandOrders(aiBrain, ownPos, enemyNearBase, defenders, true)
            end
            if table.getn(attackers) > 0 then
                local staging = GetGraphAdvanceTarget(runtime, 'front', LerpPos(ownPos, frontPos or selectedTarget, 0.55))
                if IssueMove then
                    IssueMove(attackers, staging)
                elseif IssueAggressiveMove then
                    IssueAggressiveMove(attackers, selectedTarget)
                end
                SetTaskExecution(frontTask, now, 'staging', 'split-stage', selectedTarget, staging, table.getn(attackers))
                SetTaskExecution(artilleryTask, now, 'screening', 'split-stage', selectedTarget, staging, table.getn(artilleryReady))
            end
        else
            IssueCohesiveLandOrders(aiBrain, ownPos, enemyNearBase, pressureUnits, true)
            SetTaskExecution(frontTask, now, 'defending', 'cohesive-defend', enemyNearBase, frontPos, pressureCount)
            SetTaskExecution(artilleryTask, now, 'screening', 'cohesive-defend', enemyNearBase, frontPos, table.getn(artilleryReady))
        end
        runtime.LastPressureOrder = shouldSplit and 'DefendSplit' or 'Defend'
    else
        local distance = Distance2D(ownPos, selectedTarget)
        local farTarget = distance > 150
        if farTarget and IssueMove then
            local attackStage = GetGraphAdvanceTarget(runtime, routeName, LerpPos(ownPos, selectedTarget, 0.62))
            IssueMove(pressureUnits, attackStage)
            SetTaskExecution(frontTask, now, 'staging', 'move', selectedTarget, attackStage, pressureCount)
            SetTaskExecution(artilleryTask, now, 'screening', 'move', selectedTarget, attackStage, table.getn(artilleryReady))
        end
        IssueCohesiveLandOrders(aiBrain, ownPos, selectedTarget, pressureUnits, false)
        runtime.LastPressureOrder = farTarget and 'StageAttack' or 'Attack'
        SetTaskExecution(frontTask, now, 'attacking', 'cohesive-attack', selectedTarget, stagingPos, pressureCount)
        SetTaskExecution(artilleryTask, now, 'screening', 'cohesive-attack', selectedTarget, stagingPos, table.getn(artilleryReady))
        if baseGuardCount > 0 and IssueMove then
            IssueMove(baseGuardUnits, rearGuardPos)
            SetTaskExecution(baseTask, now, 'holding', 'move', rearGuardPos, rearGuardPos, baseGuardCount)
        end
    end

    if raidCount > 0 and raidTarget and not shouldDefend then
        if raidCount >= 3 then
            IssueCohesiveLandOrders(aiBrain, ownPos, raidTarget, raidUnits, false)
            runtime.LastRaidOrder = 'Raid'
            SetTaskExecution(raidTask, now, 'raiding', 'cohesive-raid', raidTarget, raidTask and raidTask.StagingPos or ownPos, raidCount)
        elseif IssueMove then
            local raidStage = GetGraphAdvanceTarget(runtime, 'raid', (raidTask and raidTask.StagingPos) or LerpPos(ownPos, raidTarget, 0.5))
            IssueMove(raidUnits, raidStage)
            runtime.LastRaidOrder = 'RaidStage'
            SetTaskExecution(raidTask, now, 'staging', 'move', raidTarget, raidStage, raidCount)
        end
    elseif raidCount > 0 and baseGuardCount <= 0 and enemyNearBase and IssueCohesiveLandOrders then
        IssueCohesiveLandOrders(aiBrain, ownPos, enemyNearBase, raidUnits, true)
        runtime.LastRaidOrder = 'RaidRecall'
        SetTaskExecution(raidTask, now, 'recalling', 'cohesive-defend', enemyNearBase, rearGuardPos, raidCount)
    end

    runtime.LastPressureTime = now
    runtime.LastPressureCount = pressureCount
end

return {
    RunPressureCycle = RunPressureCycle,
}
