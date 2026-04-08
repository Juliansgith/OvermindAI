local EnemyAirCategory = categories.AIR * categories.MOBILE - categories.SCOUT
local EnemyBomberCategory = categories.AIR * categories.MOBILE * categories.BOMBER - categories.SCOUT - categories.TRANSPORTATION - categories.COMMAND
local EnemyLandCategory = categories.LAND * categories.MOBILE - categories.ENGINEER - categories.SCOUT
local EnemyLandDirectCategory = categories.LAND * categories.MOBILE * categories.DIRECTFIRE
    - categories.ENGINEER - categories.SCOUT - categories.ANTIAIR - categories.COMMAND
local EnemyLandIndirectCategory = categories.LAND * categories.MOBILE * categories.INDIRECTFIRE
    - categories.ENGINEER - categories.SCOUT - categories.COMMAND
local EnemyLandAACategory = categories.LAND * categories.MOBILE * categories.ANTIAIR
    - categories.ENGINEER - categories.SCOUT - categories.COMMAND
local EnemyT2LandCategory = categories.LAND * categories.MOBILE * categories.TECH2
    - categories.ENGINEER - categories.SCOUT - categories.COMMAND

local function IsEnemyBrain(aiBrain, otherBrain)
    if not otherBrain or otherBrain == aiBrain or otherBrain:IsDefeated() then
        return false
    end

    if not IsEnemy then
        return false
    end

    return IsEnemy(otherBrain:GetArmyIndex(), aiBrain:GetArmyIndex())
end

local function CountEnemyUnits(aiBrain, category)
    local total = 0
    for _, brain in ArmyBrains do
        if IsEnemyBrain(aiBrain, brain) then
            total = total + (brain:GetCurrentUnits(category) or 0)
        end
    end
    return total
end

local function InferPosture(model)
    if (model.Mobile or 0) <= 8 and (model.Time or 0) < 300 then
        return 'no_presence'
    end

    if (model.Experimental or 0) > 0 then
        return 'experimental'
    end

    if model.Air > math.max(35, model.Land * 1.3) then
        return 'air_rush'
    end

    if model.Navy > math.max(25, model.Land + model.Air) then
        return 'navy_pivot'
    end

    if model.Defense > 28 and model.Mobile < 45 then
        return 'turtle'
    end

    if model.T3Mex >= 4 and model.Mobile < 60 then
        return 'eco_greed'
    end

    if model.Land >= 70 and model.Air < 40 then
        return 'land_push'
    end

    return 'balanced'
end

local function InferComposition(model)
    local land = math.max(1, model.Land or 0)
    local air = model.Air or 0
    local bombers = model.Bomber or 0
    local direct = model.LandDirect or 0
    local indirect = model.LandIndirect or 0
    local t2Land = model.T2Land or 0

    local indirectShare = indirect / land
    local t2Share = t2Land / land
    local lowAirThreat = bombers <= 1 and air <= math.max(5, math.floor(land * 0.28))
    local indirectHeavy = indirect >= math.max(4, math.floor(land * 0.18))
        or (land >= 12 and indirectShare >= 0.24)
    local t2Push = t2Land >= math.max(4, math.floor(land * 0.16))
        or (t2Land >= 3 and indirectHeavy)
    local skirmisherHeavy = t2Push and indirectHeavy
    local counterAirWindow = t2Push and lowAirThreat and direct <= math.max(28, indirect + t2Land + 10)

    model.LandIndirectShare = indirectShare
    model.T2LandShare = t2Share
    model.LowAirThreat = lowAirThreat and true or false
    model.IndirectHeavy = indirectHeavy and true or false
    model.T2Push = t2Push and true or false
    model.SkirmisherHeavy = skirmisherHeavy and true or false
    model.CounterAirWindow = counterAirWindow and true or false
end

function Update(aiBrain, now)
    aiBrain.OvermindRuntime = aiBrain.OvermindRuntime or {}
    local runtime = aiBrain.OvermindRuntime
    runtime.OpponentModel = runtime.OpponentModel or {}

    local model = runtime.OpponentModel
    model.Air = CountEnemyUnits(aiBrain, EnemyAirCategory)
    model.Bomber = CountEnemyUnits(aiBrain, EnemyBomberCategory)
    model.Land = CountEnemyUnits(aiBrain, EnemyLandCategory)
    model.LandDirect = CountEnemyUnits(aiBrain, EnemyLandDirectCategory)
    model.LandIndirect = CountEnemyUnits(aiBrain, EnemyLandIndirectCategory)
    model.LandAA = CountEnemyUnits(aiBrain, EnemyLandAACategory)
    model.T2Land = CountEnemyUnits(aiBrain, EnemyT2LandCategory)
    model.Navy = CountEnemyUnits(aiBrain, categories.NAVAL * categories.MOBILE)
    model.Experimental = CountEnemyUnits(aiBrain, categories.EXPERIMENTAL)
    model.Defense = CountEnemyUnits(aiBrain, categories.DEFENSE * categories.STRUCTURE)
    model.T3Mex = CountEnemyUnits(aiBrain, categories.MASSEXTRACTION * categories.TECH3)
    model.Mobile = model.Air + model.Land + model.Navy

    local ownMobile = aiBrain:GetCurrentUnits(categories.MOBILE - categories.ENGINEER - categories.SCOUT) or 1
    local ownLand = aiBrain:GetCurrentUnits(categories.LAND * categories.MOBILE - categories.ENGINEER - categories.SCOUT) or 1
    local ownAir = aiBrain:GetCurrentUnits(categories.AIR * categories.MOBILE - categories.SCOUT) or 1
    local ownNavy = aiBrain:GetCurrentUnits(categories.NAVAL * categories.MOBILE) or 1
    local ownDefense = aiBrain:GetCurrentUnits(categories.DEFENSE * categories.STRUCTURE) or 0

    model.OwnMobile = ownMobile
    model.OwnLand = ownLand
    model.OwnAir = ownAir
    model.OwnNavy = ownNavy
    model.OwnDefense = ownDefense
    model.RelativeMilitary = ownMobile / math.max(1, model.Mobile)
    model.RelativeLand = ownLand / math.max(1, model.Land)
    model.RelativeAir = ownAir / math.max(1, model.Air)
    model.RelativeNavy = ownNavy / math.max(1, model.Navy)
    model.Time = now or 0
    model.Posture = InferPosture(model)
    InferComposition(model)

    local enemyPower =
        (model.Land * 1.0)
        + (model.Air * 1.1)
        + (model.Navy * 1.15)
        + (model.Experimental * 24)
        + (model.Defense * 0.3)
    local ownPower =
        (ownLand * 1.0)
        + (ownAir * 1.05)
        + (ownNavy * 1.1)
        + (ownDefense * 0.28)
    model.RelativePower = ownPower / math.max(1, enemyPower)

    model.LastUpdate = now
end
