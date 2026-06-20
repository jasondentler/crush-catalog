local PhotoMetadataLogic = {}

local function copyArray(values)
    local copy = {}

    for index, value in ipairs(values or {}) do
        copy[index] = value
    end

    return copy
end

local function addDistinct(values, seen, value)
    if value == nil or value == '' or seen[value] then
        return
    end

    seen[value] = true
    values[#values + 1] = value
end

local function alphabetical(left, right)
    local normalizedLeft = left:lower()
    local normalizedRight = right:lower()

    if normalizedLeft == normalizedRight then
        return left < right
    end

    return normalizedLeft < normalizedRight
end

function PhotoMetadataLogic.summarize(detections, taxonomyNames)
    detections = detections or {}
    local commonNames = {}
    local commonNamesSeen = {}
    local scientificNames = {}
    local scientificNamesSeen = {}
    local summary = {
        detectionCount = #detections,
        topSuggestionCount = 0,
        otherSuggestionCount = 0,
        unsureCount = 0,
        detectionFalsePositivesCount = 0,
        taxonomies = {},
        commonNameTaxonomies = {},
    }
    local topConfidence = #detections > 0 and 0 or nil

    for _, detection in ipairs(detections) do
        local prediction = detection.selectedPrediction
        local predictionIndex = detection.selectedPredictionIndex

        for _, value in ipairs(detection.predictionConfidences or {}) do
            local confidence = tonumber(value)

            if confidence ~= nil and confidence > topConfidence then
                topConfidence = confidence
            end
        end

        if detection.disposition == 'unsure' then
            summary.unsureCount = summary.unsureCount + 1
        elseif detection.disposition == 'not_an_animal' then
            summary.detectionFalsePositivesCount = summary.detectionFalsePositivesCount + 1
        end

        if prediction ~= nil and predictionIndex ~= nil then
            addDistinct(commonNames, commonNamesSeen, taxonomyNames.commonName(prediction))
            addDistinct(
                scientificNames,
                scientificNamesSeen,
                taxonomyNames.scientificName(prediction)
            )
            summary.taxonomies[#summary.taxonomies + 1] = copyArray(prediction.taxonomy)
            summary.commonNameTaxonomies[#summary.commonNameTaxonomies + 1] = copyArray(
                prediction.commonNameTaxonomy
            )

            if predictionIndex == 1 then
                summary.topSuggestionCount = summary.topSuggestionCount + 1
            else
                summary.otherSuggestionCount = summary.otherSuggestionCount + 1
            end

            if detection.predictionConfidences == nil then
                local confidence = tonumber(prediction.confidence)

                if confidence ~= nil and confidence > topConfidence then
                    topConfidence = confidence
                end
            end
        end
    end

    table.sort(commonNames, alphabetical)
    table.sort(scientificNames, alphabetical)
    summary.commonNames = table.concat(commonNames, ', ')
    summary.scientificNames = table.concat(scientificNames, ', ')
    summary.topSuggestionConfidence = topConfidence == nil
        and ''
        or string.format('%.1f', topConfidence * 100)

    return summary
end

function PhotoMetadataLogic.metadataValues(summary)
    return {
        commonNames = summary.commonNames,
        scientificNames = summary.scientificNames,
        detectionCount = tostring(summary.detectionCount),
        topSuggestionCount = tostring(summary.topSuggestionCount),
        otherSuggestionCount = tostring(summary.otherSuggestionCount),
        unsureCount = tostring(summary.unsureCount),
        detectionFalsePositivesCount = tostring(summary.detectionFalsePositivesCount),
        topSuggestionConfidence = summary.topSuggestionConfidence,
    }
end

return PhotoMetadataLogic
