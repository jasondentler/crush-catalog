local LrApplication = import 'LrApplication'
local LrDialogs = import 'LrDialogs'
local LrProgressScope = import 'LrProgressScope'
local LrTasks = import 'LrTasks'

local PhotoMetadata = require 'PhotoMetadata'

local function photoLabel(photo)
    return photo:getFormattedMetadata('preservedFileName')
        or photo:getFormattedMetadata('fileName')
        or tostring(photo)
end

local function clearSelectedPhotos()
    local photos = LrApplication.activeCatalog():getTargetPhotos()

    if #photos == 0 then
        return
    end

    local result = LrDialogs.confirm(
        LOC '$$$/CrushCatalog/ClearTitle=Clear Data from Selected Photos?',
        string.format(
            LOC '$$$/CrushCatalog/ClearPrompt=Clear Crush Catalog data from %d selected photo(s)? This is permanent.',
            #photos
        ),
        LOC '$$$/CrushCatalog/ClearButton=Clear Selected Photos',
        LOC '$$$/CrushCatalog/CancelButton=Cancel'
    )

    if result ~= 'ok' then
        return
    end

    local progress = LrProgressScope {
        title = LOC '$$$/CrushCatalog/ClearProgress=Clearing data from selected photos',
    }
    local failures = {}
    progress:setCancelable(true)

    for index, photo in ipairs(photos) do
        if progress:isCanceled() then
            break
        end

        local label = photoLabel(photo)
        progress:setCaption(string.format(
            LOC '$$$/CrushCatalog/ClearProgressCaption=Clearing %s (%d of %d)',
            label,
            index,
            #photos
        ))
        progress:setPortionComplete(index - 1, #photos)

        local succeeded, message = LrTasks.pcall(PhotoMetadata.clear, photo)

        if not succeeded then
            failures[#failures + 1] = label .. ': ' .. tostring(message)
        end

        progress:setPortionComplete(index, #photos)
    end

    progress:done()

    if #failures > 0 then
        LrDialogs.message(
            LOC '$$$/CrushCatalog/ClearErrorsTitle=Some photos could not be cleared',
            table.concat(failures, '\n'),
            'warning'
        )
    end
end

LrTasks.startAsyncTask(clearSelectedPhotos)

return {
    clearSelectedPhotos = clearSelectedPhotos,
    photoLabel = photoLabel,
}
