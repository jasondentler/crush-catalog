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
