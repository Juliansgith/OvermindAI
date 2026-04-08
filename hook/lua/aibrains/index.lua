keyToBrain = keyToBrain or {}

local fallbackBrain =
    keyToBrain['medium'] or
    keyToBrain['sorian'] or
    keyToBrain['easy'] or
    keyToBrain['adaptive']

if fallbackBrain then
    keyToBrain['overmind'] = fallbackBrain
    keyToBrain['overmindcheat'] = fallbackBrain
end
