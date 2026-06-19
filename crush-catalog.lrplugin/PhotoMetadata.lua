local PhotoMetadata = {}

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

function PhotoMetadata.record(photo, detections)
    local summary = PhotoMetadataLogic.summarize(detections, TaxonomyNames)
    local values = PhotoMetadataLogic.metadataValues(summary)
    local status = photo.catalog:withPrivateWriteAccessDo(function()
        for _, fieldId in ipairs(FIELD_IDS) do
            photo:setPropertyForPlugin(_PLUGIN, fieldId, values[fieldId])
        end
    end)

    return summary, status
end

function PhotoMetadata.summarize(detections)
    return PhotoMetadataLogic.summarize(detections, TaxonomyNames)
end

return PhotoMetadata
