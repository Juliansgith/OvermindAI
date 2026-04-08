-- Loaded by /lua/ui/lobby/aitypes.lua, which scans /lua/AI/CustomAIs_v2/.
AI = {
    Name = 'OvermindAI',
    Version = '1',
    AIList = {
        {
            key = 'overmind',
            name = '<LOC overmind_0001>AI: Overmind',
            rating = 1200,
            ratingCheatMultiplier = 0.0,
            ratingBuildMultiplier = 0.0,
            ratingOmniBonus = 0,
        },
    },
    CheatAIList = {
        {
            key = 'overmindcheat',
            name = '<LOC overmind_0002>AIx: Overmind',
            rating = 1200,
            ratingCheatMultiplier = 1250.0,
            ratingBuildMultiplier = 1000.0,
            ratingNegativeThreshold = 200,
            ratingOmniBonus = 50,
        },
    },
}
