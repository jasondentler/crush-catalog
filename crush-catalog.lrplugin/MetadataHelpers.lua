local LrTasks = import 'LrTasks'
local LrLogger = import 'LrLogger'
local LrDialogs = import("LrDialogs")

local catalog = import "LrApplication".activeCatalog()

local myLogger = LrLogger( 'com.jasondentler.crushcatalog.MetadataHelpers' )
myLogger:enable( "logfile" )

local MetadataHelpers = {}
local CATALOG_WRITE_TIMEOUT_SECONDS = 30

local function outputToLog( message )
	myLogger:trace( message )
end

local function alert( message ) 
    LrDialogs.message("Metadata Alert", message)
end

outputToLog("MetadataHelpers loaded")

local function validateBird(bird)
    assert(type(bird.commonName) == "string", "Missing commonName")
    assert(type(bird.scientificName) == "string", "Missing scientificName")
    assert(type(bird.confidence) == "number", "Missing confidence")
    assert(bird.confidence >= 0 and bird.confidence <= 100, "Invalid confidence value")
end

local function numberOrZero(value)
    return tonumber(value) or 0
end

local function joinedUniqueBirdNames(birds, fieldName)
    local names = {}
    local seen = {}

    for _, bird in ipairs(birds or {}) do
        local name = tostring(bird[fieldName] or ""):match("^%s*(.-)%s*$") or ""
        if name ~= "" and not seen[name] then
            table.insert(names, name)
            seen[name] = true
        end
    end

    return table.concat(names, ", ")
end

local function writeReviewStats(photo, birds, reviewStats)
    if not reviewStats then
        return
    end

    local fields = {
        birdDetectionCount = numberOrZero(reviewStats.detectedCount),
        birdCommonNames = joinedUniqueBirdNames(birds, "commonName"),
        birdScientificNames = joinedUniqueBirdNames(birds, "scientificName"),
        birdSuggestedCount = numberOrZero(reviewStats.suggestedCount),
        birdLocalSpeciesCount = numberOrZero(reviewStats.localSpeciesCount),
        birdManualCount = numberOrZero(reviewStats.manualCount),
        birdNotBirdCount = numberOrZero(reviewStats.notBirdCount),
        birdUnsureCount = numberOrZero(reviewStats.unsureCount),
        topSuggestionConfidence = string.format("%.1f", numberOrZero(reviewStats.topSuggestionConfidence)),
        ebirdRegionCode = tostring(reviewStats.ebirdRegionCode or ""),
        ebirdHotspotName = tostring(reviewStats.ebirdHotspotName or ""),
    }

    for fieldId, value in pairs(fields) do
        photo:setPropertyForPlugin(_PLUGIN, fieldId, tostring(value))
    end

    outputToLog(string.format(
        "Wrote review stats detections=%d suggested=%d local=%d manual=%d notBird=%d unsure=%d topConfidence=%s",
        fields.birdDetectionCount,
        fields.birdSuggestedCount,
        fields.birdLocalSpeciesCount,
        fields.birdManualCount,
        fields.birdNotBirdCount,
        fields.birdUnsureCount,
        fields.topSuggestionConfidence
    ))
end

local function photoHasKeyword(photo, targetKeyword)
    local keywords = photo:getRawMetadata("keywords") or {}
    for _, kw in ipairs(keywords) do
        if kw == targetKeyword then
            return true
        end
    end
    return false
end

local function getKeywordName(keyword)
    if not keyword then
        return nil
    end

    local success, name = LrTasks.pcall(function()
        return keyword:getName()
    end)

    if success then
        return name
    end

    outputToLog("Unable to read keyword name: " .. tostring(name))
    return nil
end

local function getKeywordParent(keyword)
    if not keyword then
        return nil
    end

    local success, parent = LrTasks.pcall(function()
        return keyword:getParent()
    end)

    if success then
        return parent
    end

    outputToLog("Unable to read keyword parent: " .. tostring(parent))
    return nil
end

local function isCrushCatalogKeyword(keyword)
    local current = keyword
    local root = nil

    while current do
        root = current
        current = getKeywordParent(current)
    end

    return getKeywordName(root) == "Crush Catalog"
end

local function clearCrushCatalogKeywords(photo)
    local keywords = photo:getRawMetadata("keywords") or {}
    local keywordsToRemove = {}

    for _, keyword in ipairs(keywords) do
        if isCrushCatalogKeyword(keyword) then
            table.insert(keywordsToRemove, keyword)
        end
    end

    for _, keyword in ipairs(keywordsToRemove) do
        outputToLog("Removing previous Crush Catalog keyword: " .. tostring(getKeywordName(keyword)))
        photo:removeKeyword(keyword)
    end

    outputToLog(string.format("Removed %d previous Crush Catalog keyword(s)", #keywordsToRemove))
end

local function createKeyword(keywordName, synonyms, parent)
    if type(synonyms) == "string" then
        synonyms = { synonyms }
    end

    local keyword = catalog:createKeyword(keywordName, synonyms, true, parent, true)
    if keyword then
        outputToLog("Created or found keyword: " .. keywordName)
    else
        outputToLog("Failed to create keyword: " .. keywordName)
    end

    return keyword
end

local function formatKeywordPath(keywordNames)
    return table.concat(keywordNames, " > ")
end

local function createKeywordsInPath(keywordNames)
    local parent = nil
    local keyword = nil
    local keywords = {}

    for _, keywordName in ipairs(keywordNames) do
        keyword = createKeyword(keywordName, {}, parent)
        if not keyword then
            outputToLog("Failed to create keyword path: " .. formatKeywordPath(keywordNames))
            return nil
        end

        table.insert(keywords, {
            name = keywordName,
            keyword = keyword,
        })
        parent = keyword
    end

    return keywords
end

local function addKeywordObjectIfMissing(photo, keyword, keywordName)
    if photoHasKeyword(photo, keyword) then
        outputToLog("Keyword already exists: " .. keywordName)
        return
    end

    outputToLog("Adding keyword: " .. keywordName)
    photo:addKeyword(keyword)
end

local function addKeywordPathIfMissing(photo, keywordNames)
    local keywords = createKeywordsInPath(keywordNames)
    if not keywords then
        return nil
    end

    for _, entry in ipairs(keywords) do
        addKeywordObjectIfMissing(photo, entry.keyword, entry.name)
    end

    return keywords[#keywords].keyword
end

local function addKeywordIfMissing(photo, keywordName, synonyms, parent)
    local keyword = createKeyword(keywordName, synonyms, parent)
    if not keyword then
        return
    end

    addKeywordObjectIfMissing(photo, keyword, keywordName)
end

local function getOrAddChildKeyword(photo, keywordName, synonyms, parentKeyword)
    if type(synonyms) == "string" then
        synonyms = { synonyms }
    end

    -- Ensure your helper function looks like this:

    if not parentKeyword then
        outputToLog("Missing parent keyword for " .. keywordName)
        return nil
    end

    local targetKeyword = catalog:createKeyword(keywordName, synonyms, true, parentKeyword, true)

    if not targetKeyword then
        outputToLog(string.format("Failed to get or create keyword %s under %s.", keywordName, parentKeyword:getName()))
        return nil
    end

    if targetKeyword and photo then
        photo:addKeyword(targetKeyword)
    end

    -- CRITICAL FIX: Always return the keyword object back to the caller!
    return targetKeyword
end

local function addSpeciesKeywords(photo, bird)
    -- Establish the base root path
    local birdsKeyword = addKeywordPathIfMissing(photo, { "Crush Catalog", "Animals", "Birds" })
    if not birdsKeyword then
        outputToLog("Unable to get or create Birds < Animals < Crush Catalog keyword")
        return
    end

    -- Write the common name
    if bird.commonName then
        local commonNamesKeyword = getOrAddChildKeyword(nil, "Common Names", { "common" }, birdsKeyword)
        outputToLog(string.format("Adding common name keyword for bird: %s (%s)", bird.commonName, bird.scientificName))
        addKeywordIfMissing(photo, bird.commonName, { bird.scientificName }, commonNamesKeyword)
    end

    if not bird.scientificName then
        outputToLog(string.format("Bird %s is missing scientific name", bird.commonName))
        return
    end

    local scientificNamesKeyword = getOrAddChildKeyword(nil, "Scientific Names", {"scientific", "latin"}, birdsKeyword)
    if not scientificNamesKeyword then
        scientificNamesKeyword = birdsKeyword
    end

    -- Split the scientific name using Lua pattern matching
    -- %s+ matches one or more spaces; ^%s+ captures everything before the space, etc.
    local genus, species = string.match(bird.scientificName, "^(%S+)%s+(%S+)")

    if not genus or not species then
        -- Fallback safety check if the scientific name isn't formatted properly
        outputToLog(string.format("Scientific name %s is not in the proper format", bird.scientificName))
        addKeywordIfMissing(photo, bird.scientificName, { bird.commonName }, scientificNamesKeyword)
        return
    end

    -- Create the Genus keyword under Birds
    -- Genus names traditionally stand alone as keywords
    local genusKeyword = getOrAddChildKeyword(photo, genus, {}, scientificNamesKeyword)
    if not genusKeyword then
        outputToLog(string.format("Unable to get or create keyword %s under birds", genus))
        genusKeyword = birdsKeyword
    end


    -- Create the Species keyword under Genus
    -- A species tag isn't useful alone (e.g., 'alba'), so its official keyword name is the full scientific name.
    -- We pass the common name as a synonym to this final leaf node.
    addKeywordIfMissing(photo, bird.scientificName, { bird.commonName }, genusKeyword)
end

function MetadataHelpers.writeBirdReview(birds, photoPath, reviewStats)
    outputToLog("Writing bird review metadata for photo: " .. photoPath)
    catalog:withWriteAccessDo("Add Bird Review Metadata", function()
        outputToLog("Acquired write access to catalog")
        local photo = catalog:findPhotoByPath(photoPath)
        if not photo then
            outputToLog("Could not find photo in catalog for path: " .. photoPath)
            return
        else
            outputToLog("Writing bird metadata to photo: " .. photoPath)
        end

        clearCrushCatalogKeywords(photo)

        for _, bird in ipairs(birds) do
            outputToLog("Validating bird")
            validateBird(bird)
            addSpeciesKeywords(photo, bird)
        end

        writeReviewStats(photo, birds, reviewStats)
    end, { timeout = CATALOG_WRITE_TIMEOUT_SECONDS })
end

function MetadataHelpers.writeEbirdLocation(photo, regionCode, hotspotName)
    if not photo then
        return
    end

    catalog:withWriteAccessDo("Update eBird Location Metadata", function()
        photo:setPropertyForPlugin(_PLUGIN, "ebirdRegionCode", tostring(regionCode or ""))
        photo:setPropertyForPlugin(_PLUGIN, "ebirdHotspotName", tostring(hotspotName or ""))
    end, { timeout = CATALOG_WRITE_TIMEOUT_SECONDS })
end

function MetadataHelpers.writeBirds(birds, photoPath)
    MetadataHelpers.writeBirdReview(birds, photoPath, nil)
end

return MetadataHelpers
