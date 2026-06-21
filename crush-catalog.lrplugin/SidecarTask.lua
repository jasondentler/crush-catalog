local LrApplication = import 'LrApplication'
local LrDialogs = import 'LrDialogs'
local LrPathUtils = import 'LrPathUtils'
local LrProgressScope = import 'LrProgressScope'
local LrTasks = import 'LrTasks'

local PhotoMetadata = require 'PhotoMetadata'
local SidecarFiles = require 'SidecarFiles'

local SidecarTask = {}

local function details(photo)
    local path = photo:getRawMetadata('path')
    return path, LrPathUtils.leafName(path)
end

local function withoutVirtualCopies(photos)
    local originals = {}

    for _, photo in ipairs(photos) do
        if not photo:getRawMetadata('isVirtualCopy') then
            originals[#originals + 1] = photo
        end
    end

    return originals
end

local function waitWhilePaused(progress, caption)
    while progress:isPaused() and not progress:isCanceled() do
        progress:setCaption(caption .. ' - Paused')
        LrTasks.sleep(0.2)
    end

    if not progress:isCanceled() then
        progress:setCaption(caption)
    end
end

local function run(operation)
    local photos = withoutVirtualCopies(
        LrApplication.activeCatalog():getTargetPhotos()
    )

    if #photos == 0 then
        return
    end

    local importing = operation == 'import'
    local title = importing and 'Restoring Crush Catalog identifications'
        or 'Backing Up Crush Catalog identifications'
    local progress = LrProgressScope { title = title }
    local failures = {}
    progress:setCancelable(true)
    progress:setPausable(true)

    for index, photo in ipairs(photos) do
        local verb = importing and 'Restoring' or 'Backing up'
        local label = photo:getFormattedMetadata('preservedFileName')
            or photo:getFormattedMetadata('fileName')
            or tostring(photo)
        local caption = string.format(
            '%s identification data for %s (%d of %d)',
            verb,
            label,
            index,
            #photos
        )

        waitWhilePaused(progress, caption)

        if progress:isCanceled() then
            break
        end

        progress:setCaption(caption)
        progress:setPortionComplete(index - 1, #photos)
        local path
        local sourceFile
        local succeeded, message = LrTasks.pcall(function()
            path, sourceFile = details(photo)

            if importing then
                PhotoMetadata.write(
                    photo,
                    SidecarFiles.import(path, sourceFile)
                )
            else
                SidecarFiles.export(path, sourceFile, PhotoMetadata.read(photo))
            end
        end)

        if not succeeded then
            failures[#failures + 1] = (sourceFile or tostring(photo))
                .. ': ' .. tostring(message)
        end

        progress:setPortionComplete(index, #photos)
    end

    progress:done()

    if #failures > 0 then
        LrDialogs.message(
            'Some Crush Catalog identifications could not be '
                .. (importing and 'restored' or 'backed up'),
            table.concat(failures, '\n'),
            'warning'
        )
    end
end

function SidecarTask.exportSelectedPhotos()
    run('export')
end

function SidecarTask.importSelectedPhotos()
    run('import')
end

SidecarTask.waitWhilePaused = waitWhilePaused
SidecarTask.withoutVirtualCopies = withoutVirtualCopies

return SidecarTask
