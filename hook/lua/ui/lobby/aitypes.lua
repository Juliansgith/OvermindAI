local function AddAIType(key, name)
    if not aitypes then
        aitypes = {}
    end

    for _, entry in ipairs(aitypes) do
        if entry.key == key then
            return
        end
    end

    table.insert(aitypes, {
        key = key,
        name = name,
    })
end

AddAIType('overmind', '<LOC overmind_0001>AI: Overmind')
AddAIType('overmindcheat', '<LOC overmind_0002>AIx: Overmind')
