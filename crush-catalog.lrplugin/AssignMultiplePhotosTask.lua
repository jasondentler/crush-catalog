local LrApplication = import 'LrApplication'
local LrDialogs = import 'LrDialogs'
local LrLocalization = import 'LrLocalization'
local LrProgressScope = import 'LrProgressScope'
local LrTasks = import 'LrTasks'

local IdentificationSearchDialog = require 'IdentificationSearchDialog'
local PhotoMetadata = require 'PhotoMetadata'

local function trace(message)
    if type(PhotoMetadata.trace) == 'function' then
        PhotoMetadata.trace(message)
    end
end

local function photoLabel(photo)
    return photo:getFormattedMetadata('preservedFileName')
        or photo:getFormattedMetadata('fileName')
        or tostring(photo)
end

local function waitWhilePaused(progress)
    local reportedPaused = false

    while progress:isPaused() and not progress:isCanceled() do
        if not reportedPaused then
            progress:setCaption(LOC '$$$/CrushCatalog/AssignMultiplePaused=Assignment paused')
            trace('Assignment paused')
            reportedPaused = true
        end

        LrTasks.sleep(0.2)
    end

    if reportedPaused and not progress:isCanceled() then
        trace('Assignment resumed')
    end
end

local function showFailures(failures)
    if #failures > 0 then
        LrDialogs.message(
            LOC '$$$/CrushCatalog/AssignMultipleErrorsTitle=Some photos could not be assigned',
            table.concat(failures, '\n'),
            'warning'
        )
    end
end

local function assignMultiplePhotos()
    local photos = LrApplication.activeCatalog():getTargetPhotos()
    trace('Beginning multiple assignment; selected photos=' .. tostring(#photos))

    if #photos == 0 then
        trace('Multiple assignment skipped; no selected photos')
        return
    end

    local searchResult = IdentificationSearchDialog.show({
        commonNameLanguage = LrLocalization.currentLanguage(),
    })

    if searchResult == nil or searchResult.action ~= 'manual' then
        trace('Multiple assignment skipped; search action='
            .. tostring(searchResult and searchResult.action))
        return
    end

    local detections = { {
        disposition = 'manual',
        selectedPrediction = searchResult.selectedPrediction,
    } }
    local progress = LrProgressScope {
        title = LOC '$$$/CrushCatalog/AssignMultipleProgress=Assigning species to selected photos',
    }
    local failures = {}

    progress:setCancelable(true)
    progress:setPausable(true)

    for index, photo in ipairs(photos) do
        waitWhilePaused(progress)

        if progress:isCanceled() then
            trace('Multiple assignment canceled from progress scope')
            break
        end

        local label = photoLabel(photo)
        progress:setCaption(string.format(
            LOC '$$$/CrushCatalog/AssignMultipleProgressCaption=Assigning %s (%d of %d)',
            label,
            index,
            #photos
        ))
        progress:setPortionComplete(index - 1, #photos)

        local succeeded, message = LrTasks.pcall(
            PhotoMetadata.record,
            photo,
            detections,
            true
        )

        if not succeeded then
            failures[#failures + 1] = label .. ': ' .. tostring(message)
            trace('Multiple assignment failure: ' .. failures[#failures])
        end

        progress:setPortionComplete(index, #photos)
    end

    progress:done()
    showFailures(failures)
    trace('Finished multiple assignment; failures=' .. tostring(#failures))
end

LrTasks.startAsyncTask(assignMultiplePhotos)

return {
    assignMultiplePhotos = assignMultiplePhotos,
    photoLabel = photoLabel,
    waitWhilePaused = waitWhilePaused,
}
