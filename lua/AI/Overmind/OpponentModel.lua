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
local EnemyExperimentalCategory = categories.EXPERIMENTAL
local EnemyDefenseCategory = categories.DEFENSE * categories.STRUCTURE
local EnemyT3MexCategory = categories.MASSEXTRACTION * categories.TECH3
local EnemyNavalCategory = categories.NAVAL * categories.MOBILE

local TheaterOrder = { 'Home', 'Front', 'Enemy', 'Navy' }

local function Clamp(v, minV, maxV)
    if v < minV then
        return minV
    end
    if v > maxV then
        return maxV
    end
    return v
end

local function Round(v)
    if v <= 0 then
        return 0
    end
    return math.floor(v + 0.5)
end

local function TableCount(t)
    return t and table.getn(t) or 0
end

local function Mean(values)
    if not values or table.getn(values) <= 0 then
        return 0
    end
    local total = 0
    for _, value in values do
        total = total + (value or 0)
    end
    return total / math.max(1, table.getn(values))
end

local function DampedSampleSum(values)
    if not values or table.getn(values) <= 0 then
        return 0
    end
    table.sort(values, function(a, b)
        return (a or 0) > (b or 0)
    end)
    local weights = { 1.0, 0.65, 0.45, 0.3, 0.22, 0.16 }
    local total = 0
    for index, value in values do
        local weight = weights[index] or 0.1
        total = total + ((value or 0) * weight)
    end
    return total
end

local function CountOwnUnits(aiBrain, category)
    if not aiBrain or not category then
        return 0
    end
    return aiBrain:GetCurrentUnits(category) or 0
end

local function EmptySampleSet()
    return {
        Land = {},
        Direct = {},
        Indirect = {},
        LandAA = {},
        T2Land = {},
        Air = {},
        Bomber = {},
        Navy = {},
        Defense = {},
        T3Mex = {},
        Experimental = {},
        Threat = {},
        AirThreat = {},
        StructureThreat = {},
        FriendlyLand = {},
        FriendlyStructures = {},
        Freshness = {},
    }
end

local function EnsureTheaterSamples(theaters, key)
    theaters[key] = theaters[key] or {
        Key = key,
        Samples = EmptySampleSet(),
        NodeCount = 0,
        ClusterThreat = 0,
        ClusterMemoryThreat = 0,
        ClusterLand = 0,
        ClusterAir = 0,
        ClusterConfidence = 0,
        ClusterApproaching = false,
    }
    return theaters[key]
end

local function TheaterKeyFromClassification(classification, medium)
    if medium == 'water' then
        return 'Navy'
    end
    if classification == 'core' or classification == 'rear' then
        return 'Home'
    end
    if classification == 'front' or classification == 'contested' then
        return 'Front'
    end
    return 'Enemy'
end

local function PushSample(samples, field, value)
    if not samples or not field or (value or 0) <= 0 then
        return
    end
    local list = samples[field]
    if not list then
        return
    end
    table.insert(list, value)
end

local function GatherTheaterSamples(aiBrain, runtime)
    local graph = runtime.ZoneGraph or {}
    local nodes = graph.Nodes or {}
    local theaters = {}
    for _, key in TheaterOrder do
        EnsureTheaterSamples(theaters, key)
    end

    for _, node in nodes do
        if node and node.Pos then
            local theaterKey = TheaterKeyFromClassification(node.Classification, node.Medium)
            local theater = EnsureTheaterSamples(theaters, theaterKey)
            local samples = theater.Samples
            theater.NodeCount = theater.NodeCount + 1

            local radius = (node.Medium == 'water') and 96 or 72
            local freshness = Clamp(node.Freshness or 0, 0, 1)
            local freshnessDebt = 1 - freshness

            PushSample(samples, 'Threat', node.Threat or 0)
            PushSample(samples, 'AirThreat', node.AirThreat or 0)
            PushSample(samples, 'StructureThreat', node.StructureThreat or 0)
            PushSample(samples, 'FriendlyLand', node.FriendlyLand or 0)
            PushSample(samples, 'FriendlyStructures', node.FriendlyStructures or 0)
            table.insert(samples.Freshness, freshness)

            if node.Medium == 'water' then
                local navy = aiBrain:GetNumUnitsAroundPoint(EnemyNavalCategory, node.Pos, math.max(92, radius), 'Enemy') or 0
                PushSample(samples, 'Navy', navy)
            else
                local land = aiBrain:GetNumUnitsAroundPoint(EnemyLandCategory, node.Pos, radius, 'Enemy') or node.EnemyLand or 0
                local air = aiBrain:GetNumUnitsAroundPoint(EnemyAirCategory, node.Pos, radius + 12, 'Enemy') or 0
                local direct = 0
                local indirect = 0
                local landAA = 0
                local t2Land = 0
                local bomber = 0
                local defense = aiBrain:GetNumUnitsAroundPoint(EnemyDefenseCategory, node.Pos, 72, 'Enemy') or node.EnemyStructures or 0
                local t3Mex = aiBrain:GetNumUnitsAroundPoint(EnemyT3MexCategory, node.Pos, 46, 'Enemy') or 0
                local experimental = aiBrain:GetNumUnitsAroundPoint(EnemyExperimentalCategory, node.Pos, 90, 'Enemy') or 0

                if land > 0 or freshnessDebt >= 0.22 or theaterKey ~= 'Home' then
                    direct = aiBrain:GetNumUnitsAroundPoint(EnemyLandDirectCategory, node.Pos, radius, 'Enemy') or 0
                    indirect = aiBrain:GetNumUnitsAroundPoint(EnemyLandIndirectCategory, node.Pos, radius, 'Enemy') or 0
                    landAA = aiBrain:GetNumUnitsAroundPoint(EnemyLandAACategory, node.Pos, radius, 'Enemy') or 0
                    t2Land = aiBrain:GetNumUnitsAroundPoint(EnemyT2LandCategory, node.Pos, radius, 'Enemy') or 0
                end
                if air > 0 or freshnessDebt >= 0.3 or theaterKey ~= 'Home' then
                    bomber = aiBrain:GetNumUnitsAroundPoint(EnemyBomberCategory, node.Pos, radius + 16, 'Enemy') or 0
                end

                PushSample(samples, 'Land', land)
                PushSample(samples, 'Direct', direct)
                PushSample(samples, 'Indirect', indirect)
                PushSample(samples, 'LandAA', landAA)
                PushSample(samples, 'T2Land', t2Land)
                PushSample(samples, 'Air', air)
                PushSample(samples, 'Bomber', bomber)
                PushSample(samples, 'Defense', defense)
                PushSample(samples, 'T3Mex', t3Mex)
                PushSample(samples, 'Experimental', experimental)
            end
        end
    end

    return theaters
end

local function ApplyClusterEvidence(theaters, clusters)
    if not theaters then
        return
    end

    for _, cluster in (clusters and clusters.Clusters or {}) do
        if cluster and cluster.Pos then
            local key = TheaterKeyFromClassification(cluster.Classification, 'land')
            local theater = EnsureTheaterSamples(theaters, key)
            theater.ClusterThreat = math.max(theater.ClusterThreat or 0, cluster.TotalThreat or 0)
            theater.ClusterMemoryThreat = math.max(theater.ClusterMemoryThreat or 0, cluster.MemoryThreat or 0)
            theater.ClusterLand = math.max(theater.ClusterLand or 0, cluster.EnemyLand or 0)
            theater.ClusterAir = math.max(theater.ClusterAir or 0, cluster.EnemyAir or 0)
            theater.ClusterConfidence = math.max(theater.ClusterConfidence or 0, cluster.ContactConfidence or 0)
            if cluster.Approaching then
                theater.ClusterApproaching = true
            end
        end
    end
end

local function CollapseTheater(theater)
    local samples = theater.Samples or EmptySampleSet()
    local confirmed = {
        Land = Round(DampedSampleSum(samples.Land)),
        Direct = Round(DampedSampleSum(samples.Direct)),
        Indirect = Round(DampedSampleSum(samples.Indirect)),
        LandAA = Round(DampedSampleSum(samples.LandAA)),
        T2Land = Round(DampedSampleSum(samples.T2Land)),
        Air = Round(DampedSampleSum(samples.Air)),
        Bomber = Round(DampedSampleSum(samples.Bomber)),
        Navy = Round(DampedSampleSum(samples.Navy)),
        Defense = Round(DampedSampleSum(samples.Defense)),
        T3Mex = Round(DampedSampleSum(samples.T3Mex)),
        Experimental = Round(DampedSampleSum(samples.Experimental)),
    }

    confirmed.Land = math.max(confirmed.Land, theater.ClusterLand or 0)
    confirmed.Air = math.max(confirmed.Air, theater.ClusterAir or 0)

    local threatEstimate = DampedSampleSum(samples.Threat)
    local airThreatEstimate = DampedSampleSum(samples.AirThreat)
    local structureThreatEstimate = DampedSampleSum(samples.StructureThreat)
    local friendlyLandEstimate = DampedSampleSum(samples.FriendlyLand)
    local friendlyStructureEstimate = DampedSampleSum(samples.FriendlyStructures)
    local averageFreshness = Mean(samples.Freshness)
    local freshnessDebt = Clamp(1 - averageFreshness, 0, 1)

    local inferredLand = math.max(0,
        ((threatEstimate - (confirmed.Land * 0.78) - (confirmed.T2Land * 0.12)) * (0.32 + (freshnessDebt * 0.82)))
            + ((theater.ClusterMemoryThreat or 0) * 0.42))
    local inferredAir = math.max(0,
        ((airThreatEstimate - (confirmed.Air * 0.75)) * (0.28 + (freshnessDebt * 0.78)))
            + ((theater.ClusterAir or 0) > 0 and (theater.ClusterConfidence or 0) < 0.55 and 0.4 or 0))
    local inferredDefense = math.max(0,
        (structureThreatEstimate - (confirmed.Defense * 0.7)) * (0.2 + (freshnessDebt * 0.45)))
    local inferredNavy = math.max(0,
        ((confirmed.Navy > 0) and 0 or 1) * ((theater.ClusterThreat or 0) * 0.08))

    local confirmedStrength = confirmed.Land
        + confirmed.Air
        + confirmed.Navy
        + (confirmed.Defense * 0.6)
        + (confirmed.Experimental * 10)
    local inferredStrength = inferredLand
        + inferredAir
        + inferredNavy
        + (inferredDefense * 0.55)
    local pressure = math.max(confirmedStrength + (inferredStrength * 0.72), theater.ClusterThreat or 0)
    local visibleShare = confirmedStrength / math.max(1, confirmedStrength + inferredStrength)
    local confidence = Clamp(
        0.18
            + (averageFreshness * 0.34)
            + (visibleShare * 0.32)
            + ((theater.ClusterConfidence or 0) * 0.16)
            + math.min(0.1, theater.NodeCount * 0.02),
        0,
        1)
    local control = Clamp(
        0.5 + (((friendlyLandEstimate * 0.72) + (friendlyStructureEstimate * 0.38) - pressure) / math.max(10, friendlyLandEstimate + friendlyStructureEstimate + pressure + 4)) * 0.9,
        0,
        1)

    return {
        Key = theater.Key,
        Confirmed = confirmed,
        Inferred = {
            Land = Round(inferredLand),
            Air = Round(inferredAir),
            Navy = Round(inferredNavy),
            Defense = Round(inferredDefense),
        },
        ThreatEstimate = Round(threatEstimate),
        AirThreatEstimate = Round(airThreatEstimate),
        StructureThreatEstimate = Round(structureThreatEstimate),
        FriendlyLandEstimate = Round(friendlyLandEstimate),
        FriendlyStructureEstimate = Round(friendlyStructureEstimate),
        AvgFreshness = averageFreshness,
        Confidence = confidence,
        Pressure = Round(pressure * 10) / 10,
        Control = control,
        NodeCount = theater.NodeCount or 0,
        ClusterThreat = theater.ClusterThreat or 0,
        ClusterMemoryThreat = theater.ClusterMemoryThreat or 0,
        ClusterConfidence = theater.ClusterConfidence or 0,
        Approaching = theater.ClusterApproaching and true or false,
    }
end

local function UpdateScalarTrend(previousTrend, previousValue, currentValue, dt)
    local minutes = math.max(0.15, dt / 60)
    local instantaneous = (currentValue - previousValue) / minutes
    local alpha = Clamp(dt / 45, 0.12, 0.4)
    return (previousTrend or 0) + ((instantaneous - (previousTrend or 0)) * alpha)
end

local function UpdateTheaterHistory(model, key, current, dt)
    model.Theaters = model.Theaters or {}
    local theater = model.Theaters[key] or { Key = key, Trend = {} }
    theater.Key = key
    theater.Confirmed = current.Confirmed
    theater.Inferred = current.Inferred
    theater.Pressure = current.Pressure
    theater.Control = current.Control
    theater.Confidence = current.Confidence
    theater.AvgFreshness = current.AvgFreshness
    theater.NodeCount = current.NodeCount
    theater.ClusterThreat = current.ClusterThreat
    theater.ClusterMemoryThreat = current.ClusterMemoryThreat
    theater.ClusterConfidence = current.ClusterConfidence
    theater.Approaching = current.Approaching
    theater.Trend = theater.Trend or {}
    theater.PressureEMA = (theater.PressureEMA or current.Pressure) + ((current.Pressure - (theater.PressureEMA or current.Pressure)) * Clamp(dt / 40, 0.12, 0.4))
    theater.ControlEMA = (theater.ControlEMA or current.Control) + ((current.Control - (theater.ControlEMA or current.Control)) * Clamp(dt / 40, 0.12, 0.4))
    theater.Trend.Pressure = UpdateScalarTrend(theater.Trend.Pressure, theater.LastPressure or current.Pressure, current.Pressure, dt)
    theater.Trend.Control = UpdateScalarTrend(theater.Trend.Control, theater.LastControl or current.Control, current.Control, dt)
    theater.LastPressure = current.Pressure
    theater.LastControl = current.Control
    theater.LastUpdate = model.Time or 0
    model.Theaters[key] = theater
    return theater
end

local function InferComposition(model)
    local land = math.max(1, model.Land or 0)
    local air = model.Air or 0
    local bombers = model.Bomber or 0
    local direct = model.LandDirect or 0
    local indirect = model.LandIndirect or 0
    local t2Land = model.T2Land or 0
    local front = (model.Theaters and model.Theaters.Front) or {}
    local frontConfidence = front.Confidence or 0

    local indirectShare = indirect / land
    local t2Share = t2Land / land
    local lowAirThreat = bombers <= 1
        and air <= math.max(5, math.floor(land * 0.28))
        and ((model.Confidence and model.Confidence.Air) or 0) >= 0.28
    local indirectHeavy = indirect >= math.max(4, math.floor(land * 0.18))
        or (land >= 12 and indirectShare >= 0.24)
        or ((front.PressureEMA or 0) >= 6 and indirectShare >= 0.18 and frontConfidence >= 0.42)
    local t2Push = t2Land >= math.max(4, math.floor(land * 0.16))
        or (t2Land >= 3 and indirectHeavy)
        or ((model.Trends and (model.Trends.T2Land or 0) > 0.9) and (front.PressureEMA or 0) >= 5 and frontConfidence >= 0.38)
    local skirmisherHeavy = t2Push and indirectHeavy
    local counterAirWindow = t2Push
        and lowAirThreat
        and direct <= math.max(28, indirect + t2Land + 10)
        and (((model.Confidence and model.Confidence.Front) or 0) >= 0.35 or ((model.Confidence and model.Confidence.Global) or 0) >= 0.45)

    model.LandIndirectShare = indirectShare
    model.T2LandShare = t2Share
    model.LowAirThreat = lowAirThreat and true or false
    model.IndirectHeavy = indirectHeavy and true or false
    model.T2Push = t2Push and true or false
    model.SkirmisherHeavy = skirmisherHeavy and true or false
    model.CounterAirWindow = counterAirWindow and true or false
end

local function InferLikelyPivot(model)
    local trends = model.Trends or {}
    local theaters = model.Theaters or {}
    local home = theaters.Home or {}
    local front = theaters.Front or {}
    local navy = theaters.Navy or {}

    local airSwitchScore =
        math.max(0, trends.Air or 0) * 0.55
        + math.max(0, trends.Bomber or 0) * 0.85
        + (((model.Confidence and model.Confidence.Air) or 0) * 1.3)
        + ((model.Air >= math.max(4, math.floor((model.Land or 0) * 0.18))) and 0.6 or 0)
    local greedyTechScore =
        math.max(0, trends.T3Mex or 0) * 1.6
        + ((model.T3Mex >= 2) and 1.1 or 0)
        + (((front.PressureEMA or 0) < 4) and 0.7 or 0)
        + (((home.PressureEMA or 0) < 3) and 0.5 or 0)
    local navyScore =
        math.max(0, trends.Navy or 0) * 0.8
        + math.max(0, (navy.PressureEMA or 0) - 2) * 0.3
        + (((model.Confidence and model.Confidence.Navy) or 0) * 1.1)
    local turtleScore =
        math.max(0, trends.Defense or 0) * 0.9
        + ((model.Defense >= 6) and 0.9 or 0)
        + (((model.Mobile or 0) < 24) and 0.45 or 0)
        + (((front.PressureEMA or 0) < 4.5) and 0.45 or 0)
    local pushScore =
        math.max(0, trends.FrontPressure or 0) * 0.55
        + math.max(0, trends.Land or 0) * 0.35
        + math.max(0, trends.T2Land or 0) * 0.75
        + ((front.Approaching or false) and 1.0 or 0)
        + (((front.PressureEMA or 0) >= 5) and 0.9 or 0)

    local bestPivot = 'balanced'
    local bestScore = 0
    local candidates = {
        air_switch = airSwitchScore,
        greedy_tech = greedyTechScore,
        navy_commitment = navyScore,
        turtle = turtleScore,
        push_window = pushScore,
    }
    for pivot, score in candidates do
        if score > bestScore then
            bestPivot = pivot
            bestScore = score
        end
    end

    if bestScore < 1.35 then
        bestPivot = 'balanced'
    end

    model.LikelyPivot = bestPivot
    model.PivotConfidence = Clamp(bestScore / 4.6, 0, 1)
    model.PivotScores = candidates
end

local function InferPosture(model)
    local front = (model.Theaters and model.Theaters.Front) or {}
    local home = (model.Theaters and model.Theaters.Home) or {}
    local globalConfidence = (model.Confidence and model.Confidence.Global) or 0

    if (model.Mobile or 0) <= 8 and (model.Time or 0) < 300 and globalConfidence < 0.5 then
        return 'no_presence'
    end
    if (model.Experimental or 0) > 0 then
        return 'experimental'
    end
    if model.LikelyPivot == 'navy_commitment' then
        return 'navy_pivot'
    end
    if model.LikelyPivot == 'greedy_tech' then
        return 'eco_greed'
    end
    if model.LikelyPivot == 'turtle' then
        return 'turtle'
    end
    if (model.Air or 0) > math.max(16, (model.Land or 0) * 1.05) and ((model.Confidence and model.Confidence.Air) or 0) >= 0.4 then
        return 'air_rush'
    end
    if model.LikelyPivot == 'push_window'
        or (front.PressureEMA or 0) >= 5.2
        or ((model.T2Push == true or model.IndirectHeavy == true) and (front.Confidence or 0) >= 0.35)
        or ((model.Land or 0) >= 70 and (model.Air or 0) < 40) then
        return 'land_push'
    end
    if (home.PressureEMA or 0) >= 6.5 and (model.RelativePower or 1) < 0.9 then
        return 'land_push'
    end
    return 'balanced'
end

function Update(aiBrain, now)
    aiBrain.OvermindRuntime = aiBrain.OvermindRuntime or {}
    local runtime = aiBrain.OvermindRuntime
    runtime.OpponentModel = runtime.OpponentModel or {
        Theaters = {},
        Trends = {},
        Confidence = {},
        LastLogTime = -999,
    }

    local model = runtime.OpponentModel
    local dt = math.max(1, (now or 0) - (model.LastUpdate or (now or 0)))
    model.Time = now or 0

    local theaterSamples = GatherTheaterSamples(aiBrain, runtime)
    ApplyClusterEvidence(theaterSamples, runtime.EnemyClusterTracker or {})

    local aggregated = {}
    for _, key in TheaterOrder do
        aggregated[key] = CollapseTheater(EnsureTheaterSamples(theaterSamples, key))
    end

    local ownMobile = CountOwnUnits(aiBrain, categories.MOBILE - categories.ENGINEER - categories.SCOUT) or 1
    local ownLand = CountOwnUnits(aiBrain, categories.LAND * categories.MOBILE - categories.ENGINEER - categories.SCOUT) or 1
    local ownAir = CountOwnUnits(aiBrain, categories.AIR * categories.MOBILE - categories.SCOUT) or 1
    local ownNavy = CountOwnUnits(aiBrain, categories.NAVAL * categories.MOBILE) or 1
    local ownDefense = CountOwnUnits(aiBrain, categories.DEFENSE * categories.STRUCTURE) or 0

    local confirmedLand = 0
    local confirmedDirect = 0
    local confirmedIndirect = 0
    local confirmedLandAA = 0
    local confirmedT2Land = 0
    local confirmedAir = 0
    local confirmedBomber = 0
    local confirmedNavy = 0
    local confirmedDefense = 0
    local confirmedT3Mex = 0
    local confirmedExperimental = 0
    local inferredLand = 0
    local inferredAir = 0
    local inferredNavy = 0
    local inferredDefense = 0
    local confidenceSum = 0
    local confidenceWeight = 0
    local airConfidenceSum = 0
    local airConfidenceWeight = 0

    for _, key in TheaterOrder do
        local theater = UpdateTheaterHistory(model, key, aggregated[key], dt)
        confirmedLand = confirmedLand + (theater.Confirmed.Land or 0)
        confirmedDirect = confirmedDirect + (theater.Confirmed.Direct or 0)
        confirmedIndirect = confirmedIndirect + (theater.Confirmed.Indirect or 0)
        confirmedLandAA = confirmedLandAA + (theater.Confirmed.LandAA or 0)
        confirmedT2Land = confirmedT2Land + (theater.Confirmed.T2Land or 0)
        confirmedAir = confirmedAir + (theater.Confirmed.Air or 0)
        confirmedBomber = confirmedBomber + (theater.Confirmed.Bomber or 0)
        confirmedNavy = confirmedNavy + (theater.Confirmed.Navy or 0)
        confirmedDefense = confirmedDefense + (theater.Confirmed.Defense or 0)
        confirmedT3Mex = confirmedT3Mex + (theater.Confirmed.T3Mex or 0)
        confirmedExperimental = confirmedExperimental + (theater.Confirmed.Experimental or 0)
        inferredLand = inferredLand + ((theater.Inferred and theater.Inferred.Land) or 0)
        inferredAir = inferredAir + ((theater.Inferred and theater.Inferred.Air) or 0)
        inferredNavy = inferredNavy + ((theater.Inferred and theater.Inferred.Navy) or 0)
        inferredDefense = inferredDefense + ((theater.Inferred and theater.Inferred.Defense) or 0)
        confidenceSum = confidenceSum + ((theater.Confidence or 0) * math.max(1, theater.NodeCount or 0))
        confidenceWeight = confidenceWeight + math.max(1, theater.NodeCount or 0)
        airConfidenceSum = airConfidenceSum + ((theater.Confidence or 0) * ((theater.Confirmed.Air or 0) + ((theater.Inferred and theater.Inferred.Air) or 0) + 1))
        airConfidenceWeight = airConfidenceWeight + ((theater.Confirmed.Air or 0) + ((theater.Inferred and theater.Inferred.Air) or 0) + 1)
    end

    local estimatedLand = confirmedLand + inferredLand
    local estimatedAir = confirmedAir + inferredAir
    local estimatedNavy = confirmedNavy + inferredNavy
    local estimatedDefense = confirmedDefense + inferredDefense
    local estimatedT3Mex = confirmedT3Mex
    local landIndirectShare = confirmedIndirect / math.max(1, confirmedLand)
    local landT2Share = confirmedT2Land / math.max(1, confirmedLand)
    local landAAShare = confirmedLandAA / math.max(1, confirmedLand)
    local bomberShare = confirmedBomber / math.max(1, confirmedAir)

    local frontPressure = ((model.Theaters.Front or {}).PressureEMA) or (aggregated.Front and aggregated.Front.Pressure) or 0
    local homePressure = ((model.Theaters.Home or {}).PressureEMA) or (aggregated.Home and aggregated.Home.Pressure) or 0

    local estimatedIndirect = confirmedIndirect + Round(inferredLand * Clamp(math.max(landIndirectShare, ((frontPressure >= 5) and 0.16 or 0.08)), 0, 0.4))
    local estimatedT2Land = confirmedT2Land + Round(inferredLand * Clamp(math.max(landT2Share, (((now or 0) >= 420 and frontPressure >= 5) and 0.14 or 0.06)), 0, 0.35))
    local estimatedLandAA = confirmedLandAA + Round(inferredLand * Clamp(math.max(landAAShare, ((estimatedAir > 0) and 0.06 or 0.03)), 0, 0.18))
    local estimatedDirect = math.max(0, estimatedLand - estimatedIndirect - estimatedLandAA)
    local estimatedBomber = confirmedBomber + Round(inferredAir * Clamp(math.max(bomberShare, ((estimatedAir > 0 and homePressure >= 3) and 0.14 or 0.05)), 0, 0.35))
    local estimatedMobile = estimatedLand + estimatedAir + estimatedNavy

    model.Confirmed = {
        Land = confirmedLand,
        Direct = confirmedDirect,
        Indirect = confirmedIndirect,
        LandAA = confirmedLandAA,
        T2Land = confirmedT2Land,
        Air = confirmedAir,
        Bomber = confirmedBomber,
        Navy = confirmedNavy,
        Defense = confirmedDefense,
        T3Mex = confirmedT3Mex,
        Experimental = confirmedExperimental,
        Mobile = confirmedLand + confirmedAir + confirmedNavy,
    }
    model.Inferred = {
        Land = inferredLand,
        Air = inferredAir,
        Navy = inferredNavy,
        Defense = inferredDefense,
        Mobile = inferredLand + inferredAir + inferredNavy,
    }

    model.Air = estimatedAir
    model.Bomber = estimatedBomber
    model.Land = estimatedLand
    model.LandDirect = estimatedDirect
    model.LandIndirect = estimatedIndirect
    model.LandAA = estimatedLandAA
    model.T2Land = estimatedT2Land
    model.Navy = estimatedNavy
    model.Experimental = confirmedExperimental
    model.Defense = estimatedDefense
    model.T3Mex = estimatedT3Mex
    model.Mobile = estimatedMobile

    model.OwnMobile = ownMobile
    model.OwnLand = ownLand
    model.OwnAir = ownAir
    model.OwnNavy = ownNavy
    model.OwnDefense = ownDefense
    model.RelativeMilitary = ownMobile / math.max(1, estimatedMobile)
    model.RelativeLand = ownLand / math.max(1, estimatedLand)
    model.RelativeAir = ownAir / math.max(1, estimatedAir)
    model.RelativeNavy = ownNavy / math.max(1, estimatedNavy)

    local enemyPower =
        (estimatedLand * 1.0)
        + (estimatedAir * 1.1)
        + (estimatedNavy * 1.15)
        + (confirmedExperimental * 24)
        + (estimatedDefense * 0.3)
    local ownPower =
        (ownLand * 1.0)
        + (ownAir * 1.05)
        + (ownNavy * 1.1)
        + (ownDefense * 0.28)
    model.RelativePower = ownPower / math.max(1, enemyPower)

    model.Trends = model.Trends or {}
    model.Trends.Land = UpdateScalarTrend(model.Trends.Land, model.LastLand or estimatedLand, estimatedLand, dt)
    model.Trends.Air = UpdateScalarTrend(model.Trends.Air, model.LastAir or estimatedAir, estimatedAir, dt)
    model.Trends.Bomber = UpdateScalarTrend(model.Trends.Bomber, model.LastBomber or estimatedBomber, estimatedBomber, dt)
    model.Trends.Navy = UpdateScalarTrend(model.Trends.Navy, model.LastNavy or estimatedNavy, estimatedNavy, dt)
    model.Trends.Defense = UpdateScalarTrend(model.Trends.Defense, model.LastDefense or estimatedDefense, estimatedDefense, dt)
    model.Trends.T2Land = UpdateScalarTrend(model.Trends.T2Land, model.LastT2Land or estimatedT2Land, estimatedT2Land, dt)
    model.Trends.T3Mex = UpdateScalarTrend(model.Trends.T3Mex, model.LastT3Mex or estimatedT3Mex, estimatedT3Mex, dt)
    model.Trends.Mobile = UpdateScalarTrend(model.Trends.Mobile, model.LastMobile or estimatedMobile, estimatedMobile, dt)
    model.Trends.FrontPressure = UpdateScalarTrend(model.Trends.FrontPressure, model.LastFrontPressure or frontPressure, frontPressure, dt)
    model.Trends.HomePressure = UpdateScalarTrend(model.Trends.HomePressure, model.LastHomePressure or homePressure, homePressure, dt)

    model.Confidence = model.Confidence or {}
    model.Confidence.Home = (model.Theaters.Home and model.Theaters.Home.Confidence) or 0
    model.Confidence.Front = (model.Theaters.Front and model.Theaters.Front.Confidence) or 0
    model.Confidence.Enemy = (model.Theaters.Enemy and model.Theaters.Enemy.Confidence) or 0
    model.Confidence.Navy = (model.Theaters.Navy and model.Theaters.Navy.Confidence) or 0
    model.Confidence.Global = Clamp(confidenceSum / math.max(1, confidenceWeight), 0, 1)
    model.Confidence.Air = Clamp(airConfidenceSum / math.max(1, airConfidenceWeight), 0, 1)
    model.ConfirmedStrength = model.Confirmed.Mobile + (confirmedDefense * 0.55) + (confirmedExperimental * 10)
    model.InferredStrength = model.Inferred.Mobile + (inferredDefense * 0.5)

    InferComposition(model)
    InferLikelyPivot(model)
    model.Posture = InferPosture(model)

    model.LastLand = estimatedLand
    model.LastAir = estimatedAir
    model.LastBomber = estimatedBomber
    model.LastNavy = estimatedNavy
    model.LastDefense = estimatedDefense
    model.LastT2Land = estimatedT2Land
    model.LastT3Mex = estimatedT3Mex
    model.LastMobile = estimatedMobile
    model.LastFrontPressure = frontPressure
    model.LastHomePressure = homePressure
    model.LastUpdate = now

    if now - (model.LastLogTime or -999) >= 20 then
        model.LastLogTime = now
        LOG(string.format('*OVERMIND OPP A%d t=%.1f conf=%.2f/%0.2f/%0.2f post=%s pivot=%s:%.2f c=%d/%d/%d/%d i=%d/%d/%d p=%.1f/%.1f rel=%.2f/%.2f',
            aiBrain:GetArmyIndex(),
            now,
            model.Confidence.Global or 0,
            model.Confidence.Front or 0,
            model.Confidence.Air or 0,
            model.Posture or 'unknown',
            model.LikelyPivot or 'balanced',
            model.PivotConfidence or 0,
            model.Land or 0,
            model.Air or 0,
            model.Navy or 0,
            model.Defense or 0,
            model.Inferred.Land or 0,
            model.Inferred.Air or 0,
            model.Inferred.Navy or 0,
            frontPressure,
            homePressure,
            model.RelativeMilitary or 1,
            model.RelativePower or 1))
    end
end
