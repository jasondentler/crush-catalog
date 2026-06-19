local TaxonomyNames = {}

local function lastItem(values)
    if values == nil then
        return nil
    end

    return values[#values]
end

local function taxonomyRanks(prediction)
    return prediction.taxonomyRanks or prediction.taxonomy_ranks or {}
end

local function commonNameTaxonomy(prediction)
    return prediction.commonNameTaxonomy
        or prediction.taxonomyCommonNames
        or prediction.taxonomy_common_names
        or {}
end

local function genusIndex(prediction)
    for index, rank in ipairs(taxonomyRanks(prediction)) do
        if tostring(rank):lower() == 'genus' then
            return index
        end
    end

    local taxonomy = prediction.taxonomy or {}

    for index = #taxonomy, 1, -1 do
        local rankName = taxonomy[index]

        if type(rankName) == 'string' and rankName:match('^[A-Z][%a%-]+$') then
            return index
        end
    end

    return nil
end


function TaxonomyNames.commonName(prediction)
    return lastItem(commonNameTaxonomy(prediction)) or prediction.commonName or 'Unknown'
end

function TaxonomyNames.scientificName(prediction)
    local taxonomy = prediction.taxonomy or {}
    local name = ''
    local firstIndex = genusIndex(prediction)

    if #taxonomy == 0 then
        return prediction.scientificName or 'Unknown'
    end

    if firstIndex == nil then
        return lastItem(taxonomy)
    end

    for index = firstIndex, #taxonomy do
        local rankName = taxonomy[index]

        if name == '' then
            name = rankName
        elseif rankName:sub(1, #name + 1) == name .. ' ' then
            name = rankName
        else
            name = name .. ' ' .. rankName
        end
    end

    if name == '' then
        return 'Unknown'
    end

    return name
end

return TaxonomyNames
