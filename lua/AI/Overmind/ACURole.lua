local AIUtils = import('/lua/ai/aiutilities.lua')

local StarterPowerCategory = categories.STRUCTURE * categories.ENERGYPRODUCTION * categories.TECH1
local StarterMexCategory = categories.STRUCTURE * categories.MASSEXTRACTION * categories.TECH1
local StarterRadarCategory = categories.STRUCTURE * categories.RADAR * categories.TECH1

local function Distance2D(a, b)
    local dx = (a[1] or 0) - (b[1] or 0)
    local dz = (a[3] or 0) - (b[3] or 0)
    return math.sqrt((dx * dx) + (dz * dz))
end

local function LerpPos(a, b, t)
    if not a then
        return b
    end
    if not b then
        return a
    end
    local clamped = math.max(0, math.min(1, t or 0.5))
    return {
        (a[1] or 0) + (((b[1] or 0) - (a[1] or 0)) * clamped),
        0,
        (a[3] or 0) + (((b[3] or 0) - (a[3] or 0)) * clamped),
    }
end

local function GetACU(aiBrain)
    local acu = aiBrain:GetListOfUnits(categories.COMMAND, false, true)
    if acu and table.getn(acu) > 0 and acu[1] and not acu[1].Dead then
        return acu[1]
    end
    return false
end

local function GetHomePos(aiBrain, runtime)
    if runtime and runtime.OwnMainPos then
        return runtime.OwnMainPos
    end
    if aiBrain.BuilderManagers and aiBrain.BuilderManagers.MAIN and aiBrain.BuilderManagers.MAIN.Position then
        return aiBrain.BuilderManagers.MAIN.Position
    end
    local sx, sz = aiBrain:GetArmyStartPos()
    return { sx, 0, sz }
end

local function GetHealthRatio(acu)
    if not acu or not acu.GetHealth or not acu.GetMaxHealth then
        return 1
    end
    local maxHealth = math.max(1, acu:GetMaxHealth() or 1)
    return (acu:GetHealth() or maxHealth) / maxHealth
end

local function HasNearbyEnemyArmy(aiBrain, position, radius)
    if not aiBrain or not position then
        return false
    end
    local count = aiBrain:GetNumUnitsAroundPoint(
        categories.MOBILE * (categories.LAND + categories.AIR + categories.NAVAL) - categories.ENGINEER - categories.SCOUT,
        position,
        radius or 34,
        'Enemy'
    ) or 0
    return count > 0
end

local function GetQueueLen(unit)
    local q = unit and unit.GetCommandQueue and unit:GetCommandQueue() or false
    return q and table.getn(q) or 0
end

local function IsBuilderBusy(unit)
    if not unit or unit.Dead then
        return false
    end
    if unit:IsUnitState('Building') or unit:IsUnitState('Repairing') or unit:IsUnitState('Upgrading') then
        return true
    end
    return GetQueueLen(unit) > 0
end

local function GetFraction(unit)
    if not unit or unit.Dead then
        return 1
    end
    if unit.GetFractionComplete then
        local ok, fraction = pcall(function()
            return unit:GetFractionComplete()
        end)
        if ok and type(fraction) == 'number' then
            return fraction
        end
    end
    return unit:IsUnitState('BeingBuilt') and 0 or 1
end

local function PickBuildableBlueprint(builder, category)
    if not builder or not category then
        return false
    end
    local options = EntityCategoryGetUnitList(category)
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

local StarterBuildOffsets = {
    { 18, 0 }, { -18, 0 }, { 0, 18 }, { 0, -18 },
    { 28, 12 }, { -28, 12 }, { 12, -28 }, { -12, -28 },
}

local function FindStarterBuildPos(aiBrain, anchorPos, sameCategory, avoidCategory)
    if not aiBrain or not anchorPos then
        return false
    end
    for _, offset in StarterBuildOffsets do
        local pos = { (anchorPos[1] or 0) + offset[1], 0, (anchorPos[3] or 0) + offset[2] }
        local sameNearby = sameCategory and (aiBrain:GetNumUnitsAroundPoint(sameCategory, pos, 8, 'Ally') or 0) or 0
        local avoidNearby = avoidCategory and (aiBrain:GetNumUnitsAroundPoint(avoidCategory, pos, 6, 'Ally') or 0) or 0
        local enemyNear = HasNearbyEnemyArmy(aiBrain, pos, 34)
        if sameNearby <= 0 and avoidNearby <= 0 and not enemyNear then
            return pos
        end
    end
    return false
end

local function FindNearbyStarterStructure(aiBrain, homePos, powerNeeded, radarNeeded, mexPreferred)
    local targets = aiBrain:GetListOfUnits(
        categories.STRUCTURE * (categories.ENERGYPRODUCTION + categories.MASSEXTRACTION + categories.RADAR + categories.FACTORY),
        false,
        true
    ) or {}
    local best = false
    local bestScore = -999999
    for _, unit in targets do
        if unit and not unit.Dead and not unit:IsUnitState('Upgrading') then
            local fraction = GetFraction(unit)
            if fraction < 0.995 then
                local pos = unit.GetPosition and unit:GetPosition() or false
                if pos and Distance2D(pos, homePos) <= 150 and not HasNearbyEnemyArmy(aiBrain, pos, 34) then
                    local score = (fraction * 120) - Distance2D(pos, homePos)
                    if EntityCategoryContains(StarterPowerCategory, unit) then
                        if mexPreferred then
                            score = score + (powerNeeded and 40 or 20)
                        else
                            score = score + (powerNeeded and 260 or 120)
                        end
                    elseif EntityCategoryContains(StarterRadarCategory, unit) then
                        score = score + (radarNeeded and 220 or 80)
                    elseif EntityCategoryContains(StarterMexCategory, unit) then
                        if mexPreferred then
                            score = score + 260
                        else
                            score = score + ((not powerNeeded and 160) or 40)
                        end
                    elseif EntityCategoryContains(categories.FACTORY, unit) then
                        score = score + 60
                    end
                    if score > bestScore then
                        best = unit
                        bestScore = score
                    end
                end
            end
        end
    end
    return best
end

local function HasFriendlyMexAtPos(aiBrain, pos)
    return (aiBrain:GetNumUnitsAroundPoint(categories.STRUCTURE * categories.MASSEXTRACTION, pos, 8, 'Ally') or 0) > 0
end

local function FindClosestSafeMex(aiBrain, homePos, maxDistance)
    local markers = AIUtils.AIGetMarkerLocations(aiBrain, 'Mass') or {}
    local best = false
    local bestScore = 999999
    for _, marker in markers do
        local pos = marker and marker.Position
        if pos and Distance2D(pos, homePos) <= (maxDistance or 220) and not HasFriendlyMexAtPos(aiBrain, pos) then
            local threat = aiBrain:GetThreatAtPosition(pos, 1, true, 'AntiSurface') or 0
            if threat <= 0.85 and not HasNearbyEnemyArmy(aiBrain, pos, 34) then
                local score = Distance2D(pos, homePos)
                if score < bestScore then
                    best = pos
                    bestScore = score
                end
            end
        end
    end
    return best
end

local function FindSafeMexSequence(aiBrain, homePos, maxDistance, maxCount)
    local markers = AIUtils.AIGetMarkerLocations(aiBrain, 'Mass') or {}
    local candidates = {}
    local limit = math.max(1, math.floor(maxCount or 1))
    for _, marker in markers do
        local pos = marker and marker.Position
        if pos and Distance2D(pos, homePos) <= (maxDistance or 220) and not HasFriendlyMexAtPos(aiBrain, pos) then
            local threat = aiBrain:GetThreatAtPosition(pos, 1, true, 'AntiSurface') or 0
            if threat <= 1.0 and not HasNearbyEnemyArmy(aiBrain, pos, 34) then
                table.insert(candidates, {
                    Pos = pos,
                    Dist = Distance2D(pos, homePos),
                })
            end
        end
    end

    table.sort(candidates, function(a, b)
        return (a.Dist or 999999) < (b.Dist or 999999)
    end)

    local picks = {}
    for _, entry in candidates do
        local pos = entry.Pos
        local duplicate = false
        for _, existing in picks do
            if Distance2D(existing, pos) <= 4 then
                duplicate = true
                break
            end
        end
        if not duplicate then
            table.insert(picks, pos)
            if table.getn(picks) >= limit then
                break
            end
        end
    end
    return picks
end

local function GetStarterFactoryAnchor(aiBrain, homePos)
    local factories = aiBrain:GetListOfUnits(categories.FACTORY * categories.LAND * categories.STRUCTURE, false, true) or {}
    local best = homePos
    local bestDist = 999999
    for _, unit in factories do
        if unit and not unit.Dead and GetFraction(unit) >= 0.95 then
            local pos = unit:GetPosition()
            if pos then
                local dist = Distance2D(pos, homePos)
                if dist < bestDist then
                    best = pos
                    bestDist = dist
                end
            end
        end
    end
    return best
end

local function TryExecuteStarterTask(aiBrain, runtime, acu, homePos, director, constraints, now)
    if not acu or not homePos then
        return false
    end
    local qLen = GetQueueLen(acu)
    if qLen > 0 and not acu:IsUnitState('Building') and not acu:IsUnitState('Repairing') and not acu:IsUnitState('Upgrading') then
        if IssueClearCommands then
            IssueClearCommands({ acu })
        else
            return false
        end
    elseif IsBuilderBusy(acu) then
        return false
    end

    local current = director.Current or {}
    local powerReady = (((current.Eco or {}).Power or {}).Ready) or 0
    local mexReady = (((current.Eco or {}).Mex or {}).Ready) or 0
    local radarReady = (current.Structures and current.Structures.Radar) or 0
    local powerFloor = constraints.StarterPowerFloor or constraints.BootstrapPowerFloor or 2
    local mexFloor = constraints.StarterMexFloor or constraints.BootstrapMexFloor or 4
    local readyLandFactories = 0
    local landFactories = aiBrain:GetListOfUnits(categories.FACTORY * categories.LAND * categories.STRUCTURE, false, true) or {}
    for _, unit in landFactories do
        if unit and not unit.Dead and GetFraction(unit) >= 0.95 then
            readyLandFactories = readyLandFactories + 1
        end
    end
    local radarNeeded = constraints.StarterRadarRequired == true and radarReady <= 0 and powerReady >= math.max(1, powerFloor - 1)
    local powerNeeded = powerReady < powerFloor
    local criticalPowerNeeded = powerReady <= 0
    local starterPowerCount = 0
    local starterPowers = aiBrain:GetListOfUnits(StarterPowerCategory, false, true) or {}
    for _, unit in starterPowers do
        if unit and not unit.Dead then
            starterPowerCount = starterPowerCount + 1
        end
    end
    local starterMexRush = readyLandFactories >= 1
        and powerReady >= 1
        and mexReady < mexFloor
    local mexPreferred = starterMexRush and not criticalPowerNeeded

    if readyLandFactories >= 1 and IssueBuildMobile then
        local issuedStarterQueue = false
        local anchor = GetStarterFactoryAnchor(aiBrain, homePos)

        if starterPowerCount <= 0 then
            local powerBp = PickBuildableBlueprint(acu, StarterPowerCategory)
            local powerPos = powerBp and FindStarterBuildPos(aiBrain, anchor, StarterPowerCategory, categories.FACTORY * categories.STRUCTURE)
            if powerBp and powerPos then
                IssueBuildMobile({ acu }, powerPos, powerBp, {})
                issuedStarterQueue = true
            end
        end

        if mexReady < mexFloor then
            local mexBp = PickBuildableBlueprint(acu, StarterMexCategory)
            local neededMexes = math.min(4, math.max(2, mexFloor - mexReady))
            local mexQueue = mexBp and FindSafeMexSequence(aiBrain, homePos, 220, neededMexes)
            if mexBp and mexQueue and table.getn(mexQueue) > 0 then
                for _, mexPos in mexQueue do
                    IssueBuildMobile({ acu }, mexPos, mexBp, {})
                end
                issuedStarterQueue = true
            end
        end

        if issuedStarterQueue then
            runtime.ACUSafetyLockUntil = math.max(runtime.ACUSafetyLockUntil or -999, now + 6)
            runtime.ACUHardBuildLockUntil = math.max(runtime.ACUHardBuildLockUntil or -999, now + 20)
            return true
        end
    end

    if mexPreferred and IssueBuildMobile then
        local bp = PickBuildableBlueprint(acu, StarterMexCategory)
        local mexQueue = bp and FindSafeMexSequence(aiBrain, homePos, 220, math.min(4, math.max(2, mexFloor - mexReady)))
        if bp and mexQueue and table.getn(mexQueue) > 0 then
            for _, mexPos in mexQueue do
                IssueBuildMobile({ acu }, mexPos, bp, {})
            end
            runtime.ACUSafetyLockUntil = math.max(runtime.ACUSafetyLockUntil or -999, now + 6)
            runtime.ACUHardBuildLockUntil = math.max(runtime.ACUHardBuildLockUntil or -999, now + 18)
            return true
        end
    end

    local repairTarget = FindNearbyStarterStructure(aiBrain, homePos, powerNeeded, radarNeeded, mexPreferred)
    if repairTarget and IssueRepair then
        IssueRepair({ acu }, repairTarget)
        runtime.ACUSafetyLockUntil = math.max(runtime.ACUSafetyLockUntil or -999, now + 6)
        runtime.ACUHardBuildLockUntil = math.max(runtime.ACUHardBuildLockUntil or -999, now + 10)
        return true
    end

    if powerNeeded and IssueBuildMobile then
        local bp = PickBuildableBlueprint(acu, StarterPowerCategory)
        local anchor = GetStarterFactoryAnchor(aiBrain, homePos)
        local buildPos = bp and FindStarterBuildPos(aiBrain, anchor, StarterPowerCategory, categories.FACTORY * categories.STRUCTURE)
        if bp and buildPos then
            IssueBuildMobile({ acu }, buildPos, bp, {})
            runtime.ACUSafetyLockUntil = math.max(runtime.ACUSafetyLockUntil or -999, now + 6)
            runtime.ACUHardBuildLockUntil = math.max(runtime.ACUHardBuildLockUntil or -999, now + 10)
            return true
        end
    end

    if radarNeeded and IssueBuildMobile then
        local bp = PickBuildableBlueprint(acu, StarterRadarCategory)
        local buildPos = bp and FindStarterBuildPos(aiBrain, homePos, StarterRadarCategory, categories.FACTORY * categories.STRUCTURE + StarterMexCategory)
        if bp and buildPos then
            IssueBuildMobile({ acu }, buildPos, bp, {})
            runtime.ACUSafetyLockUntil = math.max(runtime.ACUSafetyLockUntil or -999, now + 6)
            runtime.ACUHardBuildLockUntil = math.max(runtime.ACUHardBuildLockUntil or -999, now + 10)
            return true
        end
    end

    if mexReady < mexFloor and IssueBuildMobile then
        local bp = PickBuildableBlueprint(acu, StarterMexCategory)
        local mexPos = bp and FindClosestSafeMex(aiBrain, homePos, 220)
        if bp and mexPos then
            IssueBuildMobile({ acu }, mexPos, bp, {})
            runtime.ACUSafetyLockUntil = math.max(runtime.ACUSafetyLockUntil or -999, now + 6)
            runtime.ACUHardBuildLockUntil = math.max(runtime.ACUHardBuildLockUntil or -999, now + 10)
            return true
        end
    end

    return false
end

local function DecideRole(now, factories, combat, escort, localThreat, homeThreat, relativePower, healthRatio, distance, underHarass, strictLeash, currentRole)
    if strictLeash then
        local retreatIn = 12
        local retreatOut = 8
        if currentRole == 'retreat' then
            if distance > retreatOut then
                return 'retreat'
            end
            return 'anchor'
        end
        if distance > retreatIn then
            return 'retreat'
        end
        return 'anchor'
    end

    if healthRatio < 0.66 or (localThreat > math.max(4, homeThreat + 2.8) and escort < 5) then
        return 'retreat'
    end

    if underHarass then
        return 'anchor'
    end

    if now < 900 or factories < 5 or combat < 35 then
        return 'anchor'
    end

    if (now > 1860 and relativePower > 1.5 and escort >= 20 and healthRatio > 0.99 and localThreat < (homeThreat + 0.4) and distance < 18) then
        return 'push'
    end

    if relativePower < 1.02 or escort < 7 then
        return 'anchor'
    end

    return 'assist'
end

local function RoleDistance(role)
    if role == 'retreat' then
        return 10
    elseif role == 'anchor' then
        return 16
    elseif role == 'assist' then
        return 24
    elseif role == 'push' then
        return 30
    end
    return 18
end

local function GetGraphAdvanceTarget(runtime, routeName, fallbackPos)
    local graph = runtime and runtime.ZoneGraph or {}
    local path = false
    if routeName == 'front' then
        path = graph.PathToFront
    elseif routeName == 'scout' then
        path = graph.PathToScout
    else
        path = graph.PathToEnemy
    end

    if path and table.getn(path) >= 2 then
        return path[math.min(2, table.getn(path))]
    end

    return fallbackPos
end

local function ShouldDoEarlyAnchorWork(now, factories, combat, healthRatio, distance, localThreat, homeThreat, underHarass)
    if now > 420 then
        return false
    end
    if underHarass then
        return false
    end
    if healthRatio < 0.82 then
        return false
    end
    if factories >= 4 and combat >= 20 then
        return false
    end
    if distance > 18 then
        return false
    end
    if localThreat > (homeThreat + 1.6) then
        return false
    end
    return true
end

function Update(aiBrain, now)
    local runtime = aiBrain.OvermindRuntime
    if not runtime then
        return
    end

    if now - (runtime.LastACURoleUpdateTime or -999) < 3 then
        return
    end
    runtime.LastACURoleUpdateTime = now

    local acu = GetACU(aiBrain)
    if not acu then
        return
    end

    local homePos = GetHomePos(aiBrain, runtime)
    local acuPos = acu:GetPosition()
    if not homePos or not acuPos then
        return
    end

    local distance = Distance2D(acuPos, homePos)
    local factories = aiBrain:GetCurrentUnits(categories.FACTORY * categories.STRUCTURE) or 0
    local combat = aiBrain:GetCurrentUnits(categories.MOBILE * (categories.LAND + categories.AIR) - categories.ENGINEER - categories.SCOUT - categories.COMMAND) or 0
    local escort = aiBrain:GetNumUnitsAroundPoint(categories.MOBILE * (categories.LAND + categories.AIR) - categories.ENGINEER - categories.SCOUT - categories.COMMAND, acuPos, 36, 'Ally') or 0
    local localThreat = aiBrain:GetThreatAtPosition(acuPos, 2, true, 'AntiSurface') or 0
    local homeThreat = aiBrain:GetThreatAtPosition(homePos, 2, true, 'AntiSurface') or 0
    local relativePower = (runtime.OpponentModel and runtime.OpponentModel.RelativePower) or 1
    local healthRatio = GetHealthRatio(acu)
    local raid = runtime.RaidDefense or {}
    local underHarass = raid.UnderLandHarass or raid.UnderAirHarass
    local director = runtime.ProductionDirector or {}
    local macro = runtime.MacroController or {}
    local constraints = director.ConstraintState or {}
    local macroObjective = macro.Phase or director.MacroObjective or 'land_factory_floor'
    local transitionAnchor = macro.TransitionLocked == true and macroObjective ~= 'surplus_scale'
    local forceStats = ((runtime.ForceDirector or {}).Stats) or {}
    local strictLeash = now < (runtime.ACUStrictLeashUntil or -999)
    local engState = runtime.EngineerState or {}
    local factoryTask = engState.UnfinishedFactoryTask or {}
    local openingFactoryFloor = factoryTask.Active == true
        and (factoryTask.ReadyFactories or 0) <= 0
        and distance <= 10
        and healthRatio >= 0.85
        and not underHarass
        and not HasNearbyEnemyArmy(aiBrain, acuPos, 34)
    local starterPhaseLock = constraints.StarterPhase == true
        and healthRatio >= 0.85
        and not underHarass
        and not HasNearbyEnemyArmy(aiBrain, acuPos, 38)
    local insideDefendedSpace = distance <= 13
        and (escort >= 3 or (forceStats.BaseGuard or 0) >= 4)
        and localThreat <= (homeThreat + 1.1)

    local roleState = runtime.ACURoleState or {
        Current = 'anchor',
        LastSwitch = -999,
        RetreatBurst = 0,
        LastRetreatTrigger = -999,
        RetreatEscalatedUntil = -999,
    }
    local recentDamage = (runtime.LastAcuDamageTime or -999) >= (now - 20)
    local acuCrisisActive = now < (runtime.ACUCrisisUntil or -999)
    local acuCrisisEscalated = now < (runtime.ACUCrisisEscalatedUntil or -999)
    local desired = DecideRole(now, factories, combat, escort, localThreat, homeThreat, relativePower, healthRatio, distance, underHarass, strictLeash, roleState.Current)
    local rawDesired = desired
    if acuCrisisActive then
        desired = 'retreat'
        rawDesired = 'retreat'
    elseif rawDesired == 'retreat' then
        if (now - (roleState.LastRetreatTrigger or -999)) <= 30 then
            roleState.RetreatBurst = (roleState.RetreatBurst or 0) + 1
        else
            roleState.RetreatBurst = 1
        end
        roleState.LastRetreatTrigger = now
        if (roleState.RetreatBurst or 0) >= 2 then
            roleState.RetreatEscalatedUntil = math.max(roleState.RetreatEscalatedUntil or -999, now + 42)
            runtime.ACUStrictLeashUntil = math.max(runtime.ACUStrictLeashUntil or -999, now + 70)
        elseif recentDamage then
            roleState.RetreatEscalatedUntil = math.max(roleState.RetreatEscalatedUntil or -999, now + 26)
            runtime.ACUStrictLeashUntil = math.max(runtime.ACUStrictLeashUntil or -999, now + 40)
        end
    elseif (roleState.LastRetreatTrigger or -999) < (now - 34) and not recentDamage and healthRatio >= 0.90 then
        roleState.RetreatBurst = 0
    end
    local retreatEscalated = now < (roleState.RetreatEscalatedUntil or -999)
    if acuCrisisActive then
        desired = 'retreat'
    elseif openingFactoryFloor then
        desired = 'anchor'
    elseif starterPhaseLock then
        desired = 'anchor'
    elseif transitionAnchor then
        desired = 'anchor'
    elseif insideDefendedSpace and desired == 'retreat' and not retreatEscalated and not acuCrisisActive and healthRatio >= 0.8 and not underHarass and localThreat <= (homeThreat + 1.8) then
        desired = 'anchor'
    end

    if roleState.Current == 'retreat' and desired == 'anchor' then
        if acuCrisisActive or retreatEscalated or distance > 8 or localThreat > (homeThreat + 1.5) then
            desired = 'retreat'
        end
    elseif roleState.Current == 'anchor' and desired == 'retreat' then
        if not acuCrisisActive and not retreatEscalated and distance < 13 and localThreat <= (homeThreat + 2.8) and escort >= 3 then
            desired = 'anchor'
        end
    end

    if desired ~= roleState.Current and (now - (roleState.LastSwitch or -999)) >= 12 then
        roleState.Current = desired
        roleState.LastSwitch = now
        LOG(string.format('*OVERMIND ACU ROLE A%d t=%.1f role=%s hp=%.2f dist=%.1f esc=%d pwr=%.2f',
            aiBrain:GetArmyIndex(),
            now,
            desired,
            healthRatio,
            distance,
            escort,
            relativePower))
    end

    runtime.ACURoleState = roleState
    runtime.ACURole = roleState.Current
    runtime.ACURoleMaxDistance = RoleDistance(roleState.Current)
    if transitionAnchor then
        runtime.ACURoleMaxDistance = math.min(runtime.ACURoleMaxDistance, 10)
    end
    if strictLeash or retreatEscalated or acuCrisisActive then
        runtime.ACURoleMaxDistance = math.min(runtime.ACURoleMaxDistance, 16)
    end
    if retreatEscalated or acuCrisisEscalated then
        runtime.ACURoleMaxDistance = math.min(runtime.ACURoleMaxDistance, 12)
    end
    if acuCrisisActive then
        runtime.ACURoleMaxDistance = math.min(runtime.ACURoleMaxDistance, acuCrisisEscalated and 8 or 10)
    end

    if acuCrisisActive then
        return
    end

    local actionInterval = 7
    if now - (runtime.LastACURoleActionTime or -999) < actionInterval then
        return
    end
    runtime.LastACURoleActionTime = now

    if now < math.max(runtime.ACUSafetyLockUntil or -999, runtime.ACUHardBuildLockUntil or -999) then
        return
    end

    if openingFactoryFloor then
        return
    end

    if starterPhaseLock or (transitionAnchor and now < 360 and healthRatio >= 0.80 and not underHarass) then
        if distance > 14 then
            if GetQueueLen(acu) <= 0 and IssueMove then
                IssueMove({ acu }, homePos)
            end
            return
        end
        if TryExecuteStarterTask(aiBrain, runtime, acu, homePos, director, constraints, now) then
            return
        end
        return
    end

    local canDoEarlyAnchorWork = ShouldDoEarlyAnchorWork(now, factories, combat, healthRatio, distance, localThreat, homeThreat, underHarass)
        and not strictLeash
        and not HasNearbyEnemyArmy(aiBrain, acuPos, 34)
        and GetQueueLen(acu) <= 0

    if roleState.Current == 'retreat' or roleState.Current == 'anchor' then
        if canDoEarlyAnchorWork and TryExecuteStarterTask(aiBrain, runtime, acu, homePos, director, constraints, now) then
            return
        end
        local anchorMaxDistance = math.min(runtime.ACURoleMaxDistance or 18, 16)
        if distance > (anchorMaxDistance + 1.5) then
            local q = acu.GetCommandQueue and acu:GetCommandQueue() or false
            local qLen = q and table.getn(q) or 0
            if qLen <= 0 and IssueMove then
                IssueMove({ acu }, homePos)
            end
        end
        return
    end

    if roleState.Current == 'assist' and distance > (runtime.ACURoleMaxDistance + 8) then
        local assistPos = GetGraphAdvanceTarget(runtime, 'front', LerpPos(homePos, runtime.PrimaryEnemyPos, 0.28))
        local q = acu.GetCommandQueue and acu:GetCommandQueue() or false
        local qLen = q and table.getn(q) or 0
        if qLen <= 0 and IssueMove then
            IssueMove({ acu }, assistPos or homePos)
        end
        return
    end

    if roleState.Current == 'push' then
        local pushPos = GetGraphAdvanceTarget(runtime, 'enemy', LerpPos(homePos, runtime.PrimaryEnemyPos, 0.55))
        if localThreat > (homeThreat + 2.2) or escort < 6 then
            if IssueClearCommands then
                IssueClearCommands({ acu })
            end
            if IssueMove then
                IssueMove({ acu }, homePos)
            end
            runtime.ACURole = 'anchor'
            return
        end

        if pushPos and escort >= 8 and localThreat < (homeThreat + 3.5) and distance < (runtime.ACURoleMaxDistance + 10) then
            local q = acu.GetCommandQueue and acu:GetCommandQueue() or false
            if not q or table.getn(q) == 0 then
                if IssueAggressiveMove then
                    IssueAggressiveMove({ acu }, pushPos)
                elseif IssueMove then
                    IssueMove({ acu }, pushPos)
                end
            end
        end
    end
end
