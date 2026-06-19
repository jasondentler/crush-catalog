local IdentificationLogic = {}

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
    if dialogResult.action == 'ok' then
        local predictionIndex = dialogResult.selectedPredictionIndex
        local prediction = (result.predictions or {})[predictionIndex]

        if prediction == nil then
            return { disposition = 'confirmed' }
        end

        return {
            disposition = 'confirmed',
            selectedPredictionIndex = predictionIndex,
            selectedPrediction = {
                confidence = prediction.confidence,
                taxonomy = prediction.taxonomy or {},
                taxonomyRanks = prediction.taxonomy_ranks or {},
                commonNameTaxonomy = prediction.taxonomy_common_names or {},
            },
        }
    end

    return { disposition = dialogResult.action }
end

return IdentificationLogic
