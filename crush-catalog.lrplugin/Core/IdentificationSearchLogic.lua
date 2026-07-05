local IdentificationSearchLogic = {}

local function nonempty(value)
    return value ~= nil and value ~= ''
end

local function commonNameTaxonomy(result)
    return result.commonNameTaxonomy
        or result.taxonomyCommonNames
        or result.taxonomy_common_names
        or {}
end

local function taxonomy(result)
    return result.taxonomy or {}
end

local function displayLevels(result)
    local commonNames = commonNameTaxonomy(result)
    local scientificNames = taxonomy(result)
    local levels = {}

    for index = 1, math.max(#commonNames, #scientificNames) do
        local value = commonNames[index]

        if not nonempty(value) then
            value = scientificNames[index]
        end

        if nonempty(value) then
            levels[#levels + 1] = value
        end
    end

    return levels
end

function IdentificationSearchLogic.resultTitle(result)
    local levels = displayLevels(result)
    local first = math.max(1, #levels - 2)
    local values = {}

    for index = first, #levels do
        values[#values + 1] = levels[index]
    end

    if #values == 0 then
        return 'Unknown'
    end

    return table.concat(values, ' > ')
end

function IdentificationSearchLogic.resultItems(results, emptyTitle)
    local items = {}

    for index, result in ipairs(results or {}) do
        items[#items + 1] = {
            title = IdentificationSearchLogic.resultTitle(result),
            value = index,
        }
    end

    if #items == 0 then
        items[1] = {
            title = emptyTitle or 'No results',
            value = 0,
        }
    end

    return items
end

function IdentificationSearchLogic.taxonomyTree(result)
    if result == nil then
        return ''
    end

    local commonNames = commonNameTaxonomy(result)
    local scientificNames = taxonomy(result)
    local lines = {}

    for index = 1, math.max(#commonNames, #scientificNames) do
        local commonName = commonNames[index]
        local scientificName = scientificNames[index]
        local label

        if nonempty(commonName) and nonempty(scientificName) then
            label = commonName .. ' (' .. scientificName .. ')'
        elseif nonempty(commonName) then
            label = commonName
        elseif nonempty(scientificName) then
            label = scientificName
        end

        if label ~= nil then
            if #lines == 0 then
                lines[#lines + 1] = label
            else
                lines[#lines + 1] = string.rep('   ', #lines)
                    .. '└─► ' .. label
            end
        end
    end

    return table.concat(lines, '\n')
end

return IdentificationSearchLogic
