local PhotoMetadata = {}
local WRITE_TIMEOUT_SECONDS = 30

local function pluginPath()
    if _PLUGIN ~= nil and _PLUGIN.path ~= nil then
        return _PLUGIN.path
    end

    local source = debug.getinfo(1, 'S').source
    return source:match('^@(.+)/[^/]+$') or '.'
end

local PhotoMetadataLogic = assert(
    loadfile(pluginPath() .. '/Core/PhotoMetadataLogic.lua')
)()
local TaxonomyNames = assert(loadfile(pluginPath() .. '/Core/TaxonomyNames.lua'))()
local PhotoKeywording = assert(loadfile(pluginPath() .. '/PhotoKeywording.lua'))()

local FIELD_IDS = {
    'commonNames',
    'scientificNames',
    'detectionCount',
    'topSuggestionCount',
    'otherSuggestionCount',
    'manualCount',
    'unsureCount',
    'detectionFalsePositivesCount',
    'topSuggestionConfidence',
}

local function writeValues(photo, values)
    PhotoKeywording.trace('Beginning private metadata write')
    local writeStatus = photo.catalog:withPrivateWriteAccessDo(function()
        for _, fieldId in ipairs(FIELD_IDS) do
            photo:setPropertyForPlugin(_PLUGIN, fieldId, values[fieldId])
        end
    end, { timeout = WRITE_TIMEOUT_SECONDS })

    if writeStatus ~= 'executed' then
        error('Private metadata write timed out after '
            .. tostring(WRITE_TIMEOUT_SECONDS) .. ' seconds')
    end

    PhotoKeywording.trace('Finished private metadata write')
    return writeStatus
end

function PhotoMetadata.record(photo, detections, reprocessing)
    local summary = PhotoMetadataLogic.summarize(detections, TaxonomyNames)
    local values = PhotoMetadataLogic.metadataValues(summary)
    writeValues(photo, values)
    local status = PhotoKeywording.record(photo, detections, reprocessing)

    return summary, status
end

-- All approved entries must be completely resolved before opening a write gate.
function PhotoMetadata.recordBatch(entries, validate)
    local prepared, seen = {}, {}
    for _, entry in ipairs(entries) do
        assert(not seen[entry.photo], 'Duplicate photo in batch write')
        seen[entry.photo] = true
        local positive = false
        for _, detection in ipairs(entry.dispositions) do
            local prediction = detection.selectedPrediction
            if (detection.disposition == 'confirmed' and detection.selectedPredictionIndex
                or detection.disposition == 'manual') and prediction
                and type(prediction.taxonomy) == 'table' and #prediction.taxonomy > 0 then
                positive = true
            elseif detection.disposition ~= 'not_an_animal' or prediction ~= nil then
                error('Unresolved detection in batch write', 0)
            end
        end
        assert(positive, 'Batch write requires a confirmed species')
        prepared[#prepared + 1] = {
            photo = entry.photo, dispositions = entry.dispositions,
            reprocessing = entry.reprocessing,
            values = PhotoMetadataLogic.metadataValues(
                PhotoMetadataLogic.summarize(entry.dispositions, TaxonomyNames)),
        }
    end
    return PhotoKeywording.recordBatch(prepared, validate, function(entry)
        for _, fieldId in ipairs(FIELD_IDS) do
            entry.photo:setPropertyForPlugin(_PLUGIN, fieldId, entry.values[fieldId])
        end
    end)
end

function PhotoMetadata.clear(photo)
    PhotoKeywording.clear(photo)
    return writeValues(photo, {})
end

function PhotoMetadata.read(photo)
    local values = {}

    for _, fieldId in ipairs(FIELD_IDS) do
        values[fieldId] = photo:getPropertyForPlugin(_PLUGIN, fieldId)
    end

    return values
end

function PhotoMetadata.write(photo, values)
    return writeValues(photo, values)
end

function PhotoMetadata.summarize(detections)
    return PhotoMetadataLogic.summarize(detections, TaxonomyNames)
end

function PhotoMetadata.trace(message)
    PhotoKeywording.trace(message)
end

return PhotoMetadata
