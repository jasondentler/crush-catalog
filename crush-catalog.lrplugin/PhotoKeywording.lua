local PhotoKeywording = {}
local ROOT_KEYWORDS = {}

local logger
local protectedCall = pcall

if type(import) == 'function' then
    local imported, LrTasks = pcall(import, 'LrTasks')

    if imported and type(LrTasks.pcall) == 'function' then
        protectedCall = LrTasks.pcall
    end
end

local function diagnosticLogger()
    if logger ~= nil then
        return logger or nil
    end

    if type(import) ~= 'function' then
        logger = false
        return nil
    end

    local imported, LrLogger = pcall(import, 'LrLogger')

    if not imported then
        logger = false
        return nil
    end

    local created, value = pcall(LrLogger, 'CrushCatalogKeywording')

    if not created then
        logger = false
        return nil
    end

    logger = value
    pcall(logger.enable, logger, 'logfile')
    return logger
end

local function log(level, message)
    local value = diagnosticLogger()

    if value ~= nil and type(value[level]) == 'function' then
        pcall(value[level], value, message)
    end
end

local function joined(values)
    return table.concat(values or {}, ', ')
end

local function photoLabel(photo)
    if type(photo.getFormattedMetadata) ~= 'function' then
        return '<unknown photo>'
    end

    local succeeded, value = pcall(
        photo.getFormattedMetadata,
        photo,
        'preservedFileName'
    )
    return succeeded and value ~= nil and tostring(value) or '<unknown photo>'
end

local function normalizedRank(rank)
    return tostring(rank or ''):lower()
end

local function nonempty(value)
    return type(value) == 'string' and value ~= ''
end

local function sameName(left, right)
    return nonempty(left)
        and nonempty(right)
        and left:lower() == right:lower()
end

local function contains(values, expected)
    for _, value in ipairs(values or {}) do
        if value == expected then
            return true
        end
    end

    return false
end

local function ensureSynonyms(keyword, synonyms)
    log('trace', 'Reading synonyms for keyword ' .. tostring(keyword))
    local read, existing = protectedCall(keyword.getSynonyms, keyword)

    if not read then
        local message = 'Could not read Crush Catalog keyword synonyms: '
            .. tostring(existing)
        log('error', message)
        error(message)
    end

    existing = existing or {}
    local changed = false

    for _, synonym in ipairs(synonyms) do
        if nonempty(synonym) and not contains(existing, synonym) then
            existing[#existing + 1] = synonym
            changed = true
        end
    end

    if changed then
        log('trace', 'Updating keyword ' .. tostring(keyword)
            .. ' synonyms=[' .. joined(existing) .. ']')
        local succeeded, message = protectedCall(
            keyword.setAttributes,
            keyword,
            { synonyms = existing }
        )

        if not succeeded then
            local errorMessage = 'Could not update Crush Catalog keyword synonyms: '
                .. tostring(message)
            log('error', errorMessage)
            error(errorMessage)
        end
    end
end

local function keyword(catalog, keywordCache, synonymUpdates, name, synonyms, parent)
    local parentKey = parent or ROOT_KEYWORDS
    local siblings = keywordCache[parentKey]

    if siblings == nil then
        siblings = {}
        keywordCache[parentKey] = siblings
    end

    local normalizedName = name:lower()
    local cached = siblings[normalizedName]

    if cached ~= nil then
        log('trace', 'Reusing transaction keyword name="' .. name
            .. '" parent=' .. tostring(parent))
        return cached
    end

    log('trace', 'Creating or finding keyword name="' .. name
        .. '" parent=' .. tostring(parent)
        .. ' synonyms=[' .. joined(synonyms) .. ']')
    local succeeded, result = protectedCall(
        catalog.createKeyword,
        catalog,
        name,
        synonyms,
        true,
        parent,
        true
    )

    if not succeeded then
        local message = 'Could not create Crush Catalog keyword "' .. name
            .. '": ' .. tostring(result)
        log('error', message)
        error(message)
    end

    if result == nil or result == false then
        local message = 'Lightroom did not return the Crush Catalog keyword "'
            .. name .. '"'
        log('error', message)
        error(message)
    end

    log('trace', 'Keyword ready name="' .. name .. '" object=' .. tostring(result))
    siblings[normalizedName] = result

    if #synonyms > 0 then
        synonymUpdates[#synonymUpdates + 1] = {
            keyword = result,
            synonyms = synonyms,
        }
    end

    return result
end

local function compoundScientificName(taxonomy, ranks, lastRank)
    local names = {}
    local foundGenus = false

    for index, name in ipairs(taxonomy) do
        local rank = normalizedRank(ranks[index])

        if rank == 'genus' then
            foundGenus = true
        end

        if foundGenus and nonempty(name) then
            names[#names + 1] = name
        end

        if rank == lastRank then
            return table.concat(names, ' ')
        end
    end

    return nil
end

local function levelSynonyms(taxonomy, commonNames, ranks, index)
    local scientific = {}
    local common = {}
    local rank = normalizedRank(ranks[index])

    if nonempty(commonNames[index])
        and not sameName(commonNames[index], taxonomy[index])
    then
        scientific[#scientific + 1] = commonNames[index]
    end

    if nonempty(taxonomy[index])
        and not sameName(taxonomy[index], commonNames[index])
    then
        common[#common + 1] = taxonomy[index]
    end

    if rank == 'species' or rank == 'subspecies' then
        local compound = compoundScientificName(taxonomy, ranks, rank)

        if nonempty(compound) and not sameName(compound, taxonomy[index]) then
            scientific[#scientific + 1] = compound
        end
    end

    return scientific, common
end

local function attach(photo, attached, value)
    if value ~= nil and not attached[value] then
        log('trace', 'Attaching keyword ' .. tostring(value)
            .. ' to photo ' .. photoLabel(photo))
        local succeeded, message = protectedCall(photo.addKeyword, photo, value)

        if not succeeded then
            local errorMessage = 'Could not attach Crush Catalog keyword to '
                .. photoLabel(photo) .. ': ' .. tostring(message)
            log('error', errorMessage)
            error(errorMessage)
        end

        attached[value] = true
    end
end

local function createAndAttach(photo, detections)
    local catalog = photo.catalog
    local keywordCache = {}
    local synonymUpdates = {}
    local root = keyword(
        catalog,
        keywordCache,
        synonymUpdates,
        'Crush Catalog',
        {},
        nil
    )
    local all = keyword(catalog, keywordCache, synonymUpdates, 'All', {}, root)
    local commonRoot = keyword(
        catalog,
        keywordCache,
        synonymUpdates,
        'Common Names',
        {},
        root
    )
    local scientificRoot = keyword(
        catalog,
        keywordCache,
        synonymUpdates,
        'Scientific Names',
        {},
        root
    )
    local attached = {}

    for _, detection in ipairs(detections or {}) do
        local prediction = detection.selectedPrediction

        if prediction ~= nil and detection.selectedPredictionIndex ~= nil then
            local taxonomy = prediction.taxonomy or {}
            local ranks = prediction.taxonomyRanks or prediction.taxonomy_ranks or {}
            local commonNames = prediction.commonNameTaxonomy
                or prediction.taxonomyCommonNames
                or prediction.taxonomy_common_names
                or {}
            local commonParent = commonRoot
            local scientificParent = scientificRoot
            local detectedCommonName = commonNames[#commonNames] or prediction.commonName

            if nonempty(detectedCommonName) then
                attach(photo, attached, keyword(
                    catalog,
                    keywordCache,
                    synonymUpdates,
                    detectedCommonName,
                    {},
                    all
                ))
            end

            for index, scientificName in ipairs(taxonomy) do
                local scientificSynonyms, commonSynonyms = levelSynonyms(
                    taxonomy,
                    commonNames,
                    ranks,
                    index
                )

                if nonempty(scientificName) then
                    scientificParent = keyword(
                        catalog,
                        keywordCache,
                        synonymUpdates,
                        scientificName,
                        scientificSynonyms,
                        scientificParent
                    )
                    attach(photo, attached, scientificParent)
                end

                if nonempty(commonNames[index]) then
                    commonParent = keyword(
                        catalog,
                        keywordCache,
                        synonymUpdates,
                        commonNames[index],
                        commonSynonyms,
                        commonParent
                    )
                    attach(photo, attached, commonParent)
                end
            end
        end
    end

    return synonymUpdates
end

function PhotoKeywording.record(photo, detections)
    local catalog = photo.catalog
    local synonymUpdates
    local label = photoLabel(photo)

    log('trace', 'Beginning keyword creation for ' .. label)
    local created, creationStatus = protectedCall(
        catalog.withWriteAccessDo,
        catalog,
        'Apply Crush Catalog keywords',
        function()
            synonymUpdates = createAndAttach(photo, detections)
        end
    )

    if not created then
        local message = 'Keyword creation transaction failed for ' .. label
            .. ': ' .. tostring(creationStatus)
        log('error', message)
        error(message)
    end

    log('trace', 'Finished keyword creation for ' .. label
        .. '; synonym updates=' .. tostring(#(synonymUpdates or {})))

    log('trace', 'Beginning synonym updates for ' .. label)
    local updated, status = protectedCall(
        catalog.withWriteAccessDo,
        catalog,
        'Update Crush Catalog synonyms',
        function()
            for _, update in ipairs(synonymUpdates) do
                ensureSynonyms(update.keyword, update.synonyms)
            end
        end
    )

    if not updated then
        local message = 'Synonym update transaction failed for ' .. label
            .. ': ' .. tostring(status)
        log('error', message)
        error(message)
    end

    log('trace', 'Finished synonym updates for ' .. label)
    return status
end

function PhotoKeywording.trace(message)
    log('trace', message)
end

return PhotoKeywording
