-- A read-only view of the existing scientific keyword hierarchy.
local Summary = {}

local function normalize(name)
    return name:lower():gsub('%s+', ' '):match('^%s*(.-)%s*$')
end

local function childNamed(keywords, name)
    for _, keyword in ipairs(keywords) do
        if keyword:getName() == name then return keyword end
    end
end

-- Historical scientific keywords used lowercase species epithets, but
-- often carried only a vernacular synonym (or none at all). Newer writes
-- also supply a compound scientific synonym. Neither stores an explicit rank.
local function genusLike(name)
    return name:match('^[A-Z][%a%-]+$')
end

local function epithetLike(name)
    return name:match('^[a-z][a-z%-]+$')
        and name ~= 'unknown' and name ~= 'unidentified'
        and name ~= 'indeterminate' and name ~= 'unspecified'
        and name ~= 'spp' and name ~= 'sp'
end

local function nonSpecies(name)
    local value = ' ' .. normalize(name) .. ' '
    return value:find(' complex ', 1, true)
        or value:find(' group ', 1, true)
        or value:find(' and allies ', 1, true)
        or value:find(' hybrid ', 1, true)
        or value:find(' hybrids ', 1, true)
end

local function speciesName(keyword, ancestors)
    local name = keyword:getName()
    local synonyms = keyword:getSynonyms() or {}
    if nonSpecies(name) then return end
    for _, synonym in ipairs(synonyms) do
        if nonSpecies(synonym) then return end
    end

    local genus, epithet
    local fullGenus, fullEpithet = name:match('^([A-Z][%a%-]+) ([%a%-]+)$')
    if fullGenus then
        -- Legacy title-cased binomials also represent species complexes.
        -- A title-cased node with descendants is not a species marker:
        -- visit its children instead of absorbing their photo memberships.
        -- Bare title-cased leaves without synonyms remain supported.
        if not epithetLike(fullEpithet)
            and (#synonyms > 0 or #keyword:getChildren() > 0) then return end
        for _, ancestor in ipairs(ancestors) do
            if ancestor == fullGenus then
                genus, epithet = fullGenus, fullEpithet:lower()
                break
            end
        end
    elseif epithetLike(name) then
        epithet = name
        -- Prefer an explicit scientific synonym matching the ancestor
        -- sequence, including older compound names with intermediate ranks.
        for index, ancestor in ipairs(ancestors) do
            if genusLike(ancestor) then
                local compound = table.concat(ancestors, ' ', index) .. ' ' .. epithet
                local binomial = ancestor .. ' ' .. epithet
                for _, synonym in ipairs(synonyms) do
                    local normalized = normalize(synonym)
                    if normalized == normalize(compound) or normalized == normalize(binomial) then
                        genus = ancestor
                        break
                    end
                end
                if genus then break end
            end
        end
        -- An intervening named species complex can identify the genus
        -- even when subgenera or sections occur between it and the species.
        if not genus then
            for index = #ancestors, 1, -1 do
                local candidate = ancestors[index]:match('^([A-Z][%a%-]+) [%a%-]+')
                if candidate then
                    for earlier = 1, index - 1 do
                        if ancestors[earlier] == candidate then
                            genus = candidate
                            break
                        end
                    end
                end
                if genus then break end
            end
        end
        -- Without a rank marker, use the closest genus-like ancestor.
        if not genus then
            for index = #ancestors, 1, -1 do
                if genusLike(ancestors[index]) then
                    genus = ancestors[index]
                    break
                end
            end
        end
    end
    if not genus or not epithet or not epithetLike(epithet) then return end

    local binomial = genus .. ' ' .. epithet
    local commonName
    for _, synonym in ipairs(synonyms) do
        local normalized = normalize(synonym)
        local scientific = normalized == normalize(binomial) or normalized == normalize(name)
        if not scientific then
            for index, ancestor in ipairs(ancestors) do
                if genusLike(ancestor) and normalized == normalize(
                    table.concat(ancestors, ' ', index) .. ' ' .. epithet
                ) then
                    scientific = true
                    break
                end
            end
        end
        if not scientific and normalized ~= '' and not commonName then
            commonName = synonym
        end
    end
    return binomial, commonName or binomial
end

local function photoId(photo)
    return photo.localIdentifier or photo
end

-- Store catalog presence and counts for only the requested photos, not a
-- second catalog or a list of every photograph in memory.
function Summary.snapshot(catalog, writtenPhotos)
    local selected = {}
    for _, photo in ipairs(writtenPhotos or {}) do selected[photoId(photo)] = true end
    local species = {}
    local root = childNamed(catalog:getKeywords(), 'Crush Catalog')
    local scientific = root and childNamed(root:getChildren(), 'Scientific Names')
    if not scientific then return species end

    local function collectPhotos(keyword, entry)
        local photos = keyword:getPhotos()
        if #photos > 0 then entry.present = true end
        for _, photo in ipairs(photos) do
            local id = photoId(photo)
            if selected[id] then entry.photos[id] = true end
        end
        for _, child in ipairs(keyword:getChildren()) do collectPhotos(child, entry) end
    end

    local function visit(keyword, ancestors)
        local binomial, commonName = speciesName(keyword, ancestors)
        if binomial then
            local key = normalize(binomial)
            local entry = species[key] or {
                scientificName = binomial, name = commonName, present = false, photos = {},
                paths = {},
            }
            species[key] = entry
            if entry.name == entry.scientificName then entry.name = commonName end
            local path = normalize(table.concat(ancestors, ' > ') .. ' > ' .. keyword:getName())
            local membership = { present = false, photos = entry.photos }
            collectPhotos(keyword, membership)
            if membership.present then
                entry.present = true
                entry.paths[path] = true
            end
            return
        end
        ancestors[#ancestors + 1] = keyword:getName()
        for _, child in ipairs(keyword:getChildren()) do visit(child, ancestors) end
        ancestors[#ancestors] = nil
    end
    for _, keyword in ipairs(scientific:getChildren()) do visit(keyword, {}) end
    return species
end

function Summary.compare(before, after)
    if not after then return {} end
    local result = { catalogTotal = 0, ranked = {}, lifers = before and {} or nil }
    local previousPaths = {}
    for _, entry in pairs(before or {}) do
        if entry.present then
            for path in pairs(entry.paths or {}) do previousPaths[path] = true end
        end
    end
    for key, entry in pairs(after) do
        if entry.present then
            result.catalogTotal = result.catalogTotal + 1
            local count = 0
            for _ in pairs(entry.photos) do count = count + 1 end
            if count > 0 then
                local row = { name = entry.name, scientificName = entry.scientificName, count = count }
                result.ranked[#result.ranked + 1] = row
                local previouslyPresent = before and before[key] and before[key].present
                -- Adding a scientific synonym to an old keyword can refine its
                -- inferred binomial without changing its actual catalog membership.
                for path in pairs(entry.paths or {}) do
                    if previousPaths[path] then previouslyPresent = true; break end
                end
                if before and not previouslyPresent then
                    result.lifers[#result.lifers + 1] = row
                end
            end
        end
    end
    local function alphabetical(a, b)
        if a.name:lower() ~= b.name:lower() then return a.name:lower() < b.name:lower() end
        return a.scientificName < b.scientificName
    end
    table.sort(result.ranked, function(a, b)
        if a.count ~= b.count then return a.count > b.count end
        return alphabetical(a, b)
    end)
    if result.lifers then table.sort(result.lifers, alphabetical) end
    return result
end

function Summary.elapsed(seconds)
    local whole = math.max(0, math.floor(seconds + 0.5))
    local hours = math.floor(whole / 3600)
    local minutes = math.floor(whole / 60) % 60
    local remainder = whole % 60
    if hours > 0 then return string.format('%dh %dm %ds', hours, minutes, remainder) end
    if minutes > 0 then return string.format('%dm %ds', minutes, remainder) end
    return string.format('%ds', remainder)
end

return Summary
