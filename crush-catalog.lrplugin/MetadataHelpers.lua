local LrTasks = import 'LrTasks'
local LrLogger = import 'LrLogger'

local catalog = import "LrApplication".activeCatalog()

local myLogger = LrLogger( 'com.jasondentler.crushcatalog.MetadataHelpers' )
myLogger:enable( "logfile" )

local MetadataHelpers = {}

local function outputToLog( message )
	myLogger:trace( message )
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

local function createKeyword(keywordName, synonyms, parent)
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

local function addGeneralBirdKeyword(photo)
    local animalsKeyword = addKeywordPathIfMissing(photo, { "Animals" })
    addKeywordIfMissing(photo, "bird", { "birds" }, animalsKeyword)
end

local function addSpeciesKeywords(photo, bird)
    local birdsKeyword = addKeywordPathIfMissing(photo, { "Crush Catalog", "Animals", "Birds" })
    if not birdsKeyword then
        return
    end

    outputToLog(string.format("Adding common name keyword for bird: %s (%s) with confidence %.1f%%", bird.commonName, bird.scientificName, bird.confidence))
    addKeywordIfMissing(photo, bird.commonName, { bird.scientificName }, birdsKeyword)

    outputToLog(string.format("Adding scientific name keyword for bird: %s (%s) with confidence %.1f%%", bird.commonName, bird.scientificName, bird.confidence))
    addKeywordIfMissing(photo, bird.scientificName, { bird.commonName }, birdsKeyword)
end

function MetadataHelpers.writeBirdReview(birds, photoPath, reviewStats)
    outputToLog("Writing bird review metadata for photo: " .. photoPath)
    LrTasks.startAsyncTask(function()
        outputToLog("Started async task to write bird review metadata")
        catalog:withWriteAccessDo("Add Bird Review Metadata", function()
            outputToLog("Acquired write access to catalog")
            local photo = catalog:findPhotoByPath(photoPath)
            if not photo then
                outputToLog("Could not find photo in catalog for path: " .. photoPath)
                return
            else
                outputToLog("Writing bird metadata to photo: " .. photoPath)
            end

            for _, bird in ipairs(birds) do
                outputToLog("Validating bird")
                validateBird(bird)

                outputToLog("Adding bird keyword")
                addGeneralBirdKeyword(photo)

                addSpeciesKeywords(photo, bird)
            end

            writeReviewStats(photo, birds, reviewStats)
        end)
    end)
end

function MetadataHelpers.writeBirds(birds, photoPath)
    MetadataHelpers.writeBirdReview(birds, photoPath, nil)
end

return MetadataHelpers
