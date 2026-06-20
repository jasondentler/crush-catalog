local LrApplication = import 'LrApplication'
local LrDialogs = import 'LrDialogs'
local LrLocalization = import 'LrLocalization'
local LrProgressScope = import 'LrProgressScope'
local LrTasks = import 'LrTasks'

local IdentificationDialog = require 'IdentificationDialog'
local PhotoMetadata = require 'PhotoMetadata'
local WildCatalogApi = require 'WildCatalogApi'

local function firstAvailableMetadata(photo, accessor, keys)
    for _, key in ipairs(keys) do
        local value = photo[accessor](photo, key)

        if value ~= nil and value ~= '' then
            return value
        end
    end

    return nil
end

local function metadataForPhoto(photo)
    local gps = photo:getRawMetadata('gps')
    local exifOverride = {}
    local captureDateTime = photo:getRawMetadata('dateTimeOriginalISO8601')

    if captureDateTime ~= nil then
        exifOverride.captured_at = captureDateTime
    end

    if gps ~= nil and gps.latitude ~= nil and gps.longitude ~= nil then
        exifOverride.gps_coordinates = {
            latitude = gps.latitude,
            longitude = gps.longitude,
        }
    end

    return {
        path = photo:getRawMetadata('path'),
        originalFilename = firstAvailableMetadata(
            photo,
            'getFormattedMetadata',
            { 'preservedFileName', 'fileName' }
        ),
        exifOverride = exifOverride,
    }
end

local function appendFailure(failures, metadata, failure)
    failures[#failures + 1] = (metadata.originalFilename or metadata.path or '<unknown>')
        .. ': ' .. tostring(failure)
end

local function traceJson(label, value)
    if type(PhotoMetadata.trace) ~= 'function' then
        return
    end

    local encoded, json = pcall(
        WildCatalogApi.JSON.encode,
        WildCatalogApi.JSON,
        value
    )

    if encoded then
        PhotoMetadata.trace(label .. ': ' .. json)
    else
        PhotoMetadata.trace(label .. ' could not be encoded: ' .. tostring(json))
    end
end

local function showFailures(failures)
    if #failures > 0 then
        LrDialogs.message(
            LOC '$$$/CrushCatalog/IdentifyErrorsTitle=Some images could not be identified',
            table.concat(failures, '\n'),
            'warning'
        )
    end
end

local function createProgress()
    local progress = LrProgressScope {
        title = LOC '$$$/CrushCatalog/IdentifyProgress=Identifying selected images',
    }

    progress:setCancelable(true)

    return progress
end

local function identifySelectedPhotos()
    local photos = LrApplication.activeCatalog():getTargetPhotos()
    local progress = createProgress()
    local failures = {}

    for index, photo in ipairs(photos) do
        if progress:isCanceled() then
            break
        end

        local metadata = metadataForPhoto(photo)
        local stop = false
        progress:setCaption(metadata.originalFilename or metadata.path or '')
        progress:setPortionComplete(index - 1, #photos)

        local succeeded, response = LrTasks.pcall(WildCatalogApi.identify, metadata.path, {
            originalFilename = metadata.originalFilename,
            exifOverride = metadata.exifOverride,
            return_detected_images = true,
            common_name_language = LrLocalization.currentLanguage(),
        })

        if succeeded then
            traceJson(
                'Backend API response JSON for '
                    .. (metadata.originalFilename or metadata.path or '<unknown>'),
                response.result
            )
            local processed, action, dispositions = LrTasks.pcall(
                IdentificationDialog.showForResponse,
                photo,
                response,
                index,
                #photos
            )

            if processed then
                traceJson(
                    'Dialog result JSON for '
                        .. (metadata.originalFilename or metadata.path or '<unknown>'),
                    {
                        action = action,
                        dispositions = dispositions or {},
                    }
                )
                stop = action == 'stop'

                if action == 'continue' then
                    local recorded, recordError = LrTasks.pcall(
                        PhotoMetadata.record,
                        photo,
                        dispositions
                    )

                    if not recorded then
                        appendFailure(failures, metadata, recordError)
                    end
                end
            else
                appendFailure(failures, metadata, action)
            end
        else
            appendFailure(failures, metadata, response)
        end

        progress:setPortionComplete(index, #photos)

        if stop then
            progress:cancel()
            break
        end
    end

    progress:done()
    showFailures(failures)
end

LrTasks.startAsyncTask(identifySelectedPhotos)

return {
    identifySelectedPhotos = identifySelectedPhotos,
    metadataForPhoto = metadataForPhoto,
}
