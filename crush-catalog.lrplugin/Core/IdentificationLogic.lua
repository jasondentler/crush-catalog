local IdentificationLogic = {}

local function predictionConfidences(result)
    local confidences = {}

    for _, prediction in ipairs(result.predictions or {}) do
        confidences[#confidences + 1] = prediction.confidence
    end

    return confidences
end

function IdentificationLogic.predictionItems(predictions, noPredictionsTitle, taxonomyNames)
    local items = {}

    for index, prediction in ipairs(predictions or {}) do
        local confidence = (tonumber(prediction.confidence) or 0) * 100

        items[#items + 1] = {
            title = string.format(
                '%s (%s) %.1f%%',
                taxonomyNames.commonName(prediction),
                taxonomyNames.scientificName(prediction),
                confidence
            ),
            value = index,
        }
    end

    if #items == 0 then
        items[1] = {
            title = noPredictionsTitle or 'No predictions',
            value = 0,
        }
    end

    return items
end

function IdentificationLogic.disposition(dialogResult, result)
    local confidences = predictionConfidences(result)

    if dialogResult.action == 'ok' then
        local predictionIndex = dialogResult.selectedPredictionIndex
        local prediction = (result.predictions or {})[predictionIndex]

        if prediction == nil then
            return {
                disposition = 'confirmed',
                predictionConfidences = confidences,
            }
        end

        return {
            disposition = 'confirmed',
            predictionConfidences = confidences,
            selectedPredictionIndex = predictionIndex,
            selectedPrediction = {
                confidence = prediction.confidence,
                taxonomy = prediction.taxonomy or {},
                taxonomyRanks = prediction.taxonomy_ranks or {},
                commonNameTaxonomy = prediction.taxonomy_common_names or {},
            },
        }
    end

    return {
        disposition = dialogResult.action,
        predictionConfidences = confidences,
    }
end

return IdentificationLogic
