-- Render an owned JPEG from a disposable, reset Lightroom virtual copy.
local Render = {}
local COLLECTION = 'Crush Catalog - Temporary Virtual Copies'
local PREFIX = 'Crush Catalog temporary '

-- SDK imports are lazy: the normal original-file path does not need an export.
function Render.create()
    local files = import 'LrFileUtils'
    local paths = import 'LrPathUtils'
    local uuid = import 'LrUUID'
    local tasks = import 'LrTasks'
    local exportSession = import 'LrExportSession'
    local selection = import 'LrSelection'
    local view = import 'LrApplicationView'
    local develop = import 'LrDevelopController'
    local dialogs = import 'LrDialogs'
    local owned, collection, collectionCatalog, originalState
    local restorationPending = false
    local untracked = false
    local logger
    local imported, factory = pcall(import, 'LrLogger')
    if imported then
        local created, value = pcall(factory, 'CrushCatalogRender')
        if created then
            logger = value
            pcall(logger.enable, logger, 'logfile')
        end
    end
    local function trace(message)
        if logger then pcall(logger.trace, logger, tostring(message)) end
    end
    local function write(catalog, label, callback)
        local status = catalog:withWriteAccessDo(label, callback, { timeout = 30 })
        trace(label .. ': ' .. tostring(status))
        return status == 'executed'
    end

    local function id(photo)
        return photo and photo:getRawMetadata('uuid')
    end

    local function matchesSelection(catalog, photos)
        local actual = catalog:getTargetPhotos() or {}
        if #actual ~= #photos then return false end
        local expected = {}
        for _, photo in ipairs(photos) do expected[id(photo)] = true end
        for _, photo in ipairs(actual) do
            if not expected[id(photo)] then return false end
            expected[id(photo)] = nil
        end
        return next(expected) == nil
    end

    -- Source/module changes and selection updates can settle asynchronously.
    local function waitFor(check)
        for attempt = 1, 21 do
            if check() then return true end
            if attempt < 21 then tasks.sleep(0.1) end
        end
        return false
    end

    local function selectPhotos(catalog, active, photos, restoring)
        local others = {}
        for _, photo in ipairs(photos) do
            if id(photo) ~= id(active) then others[#others + 1] = photo end
        end
        catalog:setSelectedPhotos(active, others)
        if waitFor(function()
            return id(catalog:getTargetPhoto()) == id(active)
                and matchesSelection(catalog, photos)
        end) then return true end
        local samePhotos = matchesSelection(catalog, photos)
        local sameActive = id(catalog:getTargetPhoto()) == id(active)
        trace('Selection mismatch: expected=' .. tostring(#photos)
            .. '; actual=' .. tostring(#(catalog:getTargetPhotos() or {}))
            .. '; same photos=' .. tostring(samePhotos)
            .. '; same active=' .. tostring(sameActive))
        -- A different highlighted photo in an otherwise identical restored
        -- selection is cosmetic. Never relax selection checks for mutation.
        return restoring == true and samePhotos
    end

    local function selectOnly(catalog, photo)
        return selectPhotos(catalog, photo, { photo })
    end

    local function switchModule(module)
        if view.getCurrentModuleName() ~= module then view.switchToModule(module) end
        return waitFor(function() return view.getCurrentModuleName() == module end)
    end

    local function setSources(catalog, sources)
        if catalog:setActiveSources(sources) == false then return false end
        -- Give the filmstrip time to rebuild before changing the selection.
        tasks.sleep(0.25)
        return waitFor(function()
            local actual = catalog:getActiveSources() or {}
            local expected = type(sources) == 'string' and { sources } or sources
            if #actual ~= #expected then return false end
            local wanted = {}
            for _, source in ipairs(expected) do wanted[source] = true end
            for _, source in ipairs(actual) do
                if not wanted[source] then return false end
            end
            return true
        end)
    end

    local function isTemporary(copy)
        if not copy or copy:getRawMetadata('isVirtualCopy') ~= true then return false end
        local master = copy:getRawMetadata('masterPhoto')
        local name = copy:getFormattedMetadata('copyName')
        return id(copy) ~= nil and id(master) ~= nil and id(master) ~= id(copy)
            and type(name) == 'string' and name:sub(1, #PREFIX) == PREFIX
            and name:sub(#PREFIX + 1):match('^[%x%-]+$') ~= nil
    end

    local function capture(catalog)
        return {
            active = catalog:getTargetPhoto(), selected = catalog:getTargetPhotos() or {},
            sources = catalog:getActiveSources(), module = view.getCurrentModuleName(),
        }
    end

    local function restore(catalog, state)
        if not switchModule('library') or not setSources(catalog, state.sources) then
            trace('Unable to restore original source')
            return false
        end
        if not state.active then
            selection.selectNone()
            if not waitFor(function() return catalog:getTargetPhoto() == nil end) then
                return false
            end
        elseif not selectPhotos(catalog, state.active, state.selected, true) then
            return false
        end
        return switchModule(state.module)
    end

    local function ensureCollection(catalog)
        if collection then
            if collectionCatalog ~= catalog then return false end
        else
            local success = write(catalog, 'Crush Catalog: temporary collection', function()
                collection = catalog:createCollection(COLLECTION, nil, true)
            end)
            if collection then collectionCatalog = catalog end
            if not success or not collection then return false end
        end
        return not collection:isSmartCollection()
    end

    local function cleanup()
        if not owned then return true end
        if files.exists(owned) and not files.delete(owned) then return false end
        owned = nil
        return true
    end
    local function render(photo)
        if untracked then error('Temporary virtual copy tracking failed', 0) end
        if not cleanup() then error('Temporary rendition cleanup failed', 0) end
        local directory = paths.child(paths.getStandardFilePath('temp'),
            'crush-render-' .. uuid.generateUUID())
        if files.exists(directory) then return nil end
        if not files.createAllDirectories(directory) then return nil end
        owned = directory
        local catalog = photo.catalog
        local state = restorationPending and originalState or capture(catalog)
        originalState = state
        local sourceId = id(photo)
        local copyName = PREFIX .. uuid.generateUUID()
        local copies = {}
        local function isOwnedCopy(copy)
            if not isTemporary(copy) or id(copy) == sourceId then return false end
            local master = copy:getRawMetadata('masterPhoto')
            return master ~= nil and id(master) == sourceId
                and copy:getFormattedMetadata('copyName') == copyName
        end
        local stage = 'check prerequisites'
        local ok, path = tasks.pcall(function()
            if type(selection.removeFromCatalog) ~= 'function'
                or type(develop.resetAllDevelopAdjustments) ~= 'function'
                or type(catalog.createVirtualCopies) ~= 'function'
                or not state.active or not sourceId or type(state.module) ~= 'string'
                or photo:getRawMetadata('isVirtualCopy') ~= false then return nil end
            stage = 'create collection'
            if not ensureCollection(catalog) then error('Unsafe temporary collection', 0) end
            stage = 'select original'
            if not selectOnly(catalog, photo) then return nil end
            stage = 'create virtual copy'
            untracked = true
            copies = catalog:createVirtualCopies(copyName) or {}
            trace('Virtual copies returned: ' .. tostring(#copies))
            stage = 'verify virtual copy'
            if #copies == 0 then untracked = false; return nil end
            for _, copy in ipairs(copies) do
                if not isOwnedCopy(copy) then error('Unexpected virtual copy', 0) end
            end
            stage = 'queue virtual copy'
            local success = write(catalog, 'Crush Catalog: queue virtual copies', function()
                collection:addPhotos(copies)
            end)
            if not success then error('Unable to queue virtual copies', 0) end
            local queued = {}
            for _, copy in ipairs(collection:getPhotos()) do queued[id(copy)] = true end
            for _, copy in ipairs(copies) do
                if not queued[id(copy)] then error('Unable to verify queued copy', 0) end
            end
            untracked = false
            if #copies ~= 1 then return nil end
            local copy = copies[1]
            stage = 'select virtual copy in Develop'
            if not switchModule('library') or not setSources(catalog, { collection })
                or not selectOnly(catalog, copy) or not switchModule('develop')
                or not isOwnedCopy(copy) or not matchesSelection(catalog, { copy })
                or id(catalog:getTargetPhoto()) ~= id(copy) then return nil end
            stage = 'reset virtual copy'
            develop.resetAllDevelopAdjustments()
            stage = 'export virtual copy'
            local session = exportSession({
                photosToExport = { copy },
                exportSettings = {
                    LR_export_destinationType = 'specificFolder',
                    LR_export_destinationPathPrefix = directory,
                    LR_export_useSubfolder = false,
                    LR_format = 'JPEG',
                    LR_jpeg_quality = 1,
                    LR_export_colorSpace = 'sRGB',
                    LR_size_doConstrain = false,
                    LR_outputSharpeningOn = false,
                    LR_useWatermark = false,
                    LR_renamingTokensOn = false,
                    LR_collisionHandling = 'rename',
                    LR_minimizeEmbeddedMetadata = true,
                    LR_removeLocationMetadata = true,
                    LR_removeFaceMetadata = true,
                },
            })
            for _, rendition in session:renditions({ stopIfCanceled = true }) do
                local rendered, result = rendition:waitForRender()
                if rendered and type(result) == 'string'
                    and paths.parent(result) == directory and files.exists(result) == 'file' then
                    return result
                end
                trace('Rendition rejected: ' .. tostring(rendered) .. ' ' .. tostring(result))
            end
        end)
        trace('Render stage: ' .. stage .. '; success=' .. tostring(ok)
            .. '; result=' .. tostring(path))
        local restored, restoreResult = tasks.pcall(restore, catalog, state)
        trace('Render restore: ' .. tostring(restored) .. ' ' .. tostring(restoreResult)
            .. '; untracked=' .. tostring(untracked))
        restorationPending = not restored or not restoreResult
        if untracked then
            cleanup()
            error('Temporary virtual copy tracking or selection restoration failed', 0)
        end
        -- A valid rendition remains usable even if Lightroom cannot restore
        -- its UI selection. Retry restoration at the end of the run.
        if not ok or not path then
            if not cleanup() then error('Temporary rendition cleanup failed', 0) end
            return nil
        end
        return path
    end
    local function finish()
        if not cleanup() then return false end
        if untracked then return false end
        if not collection then return true end
        local catalog = collectionCatalog
        if not catalog or collection:isSmartCollection() then return false end
        local state = restorationPending and originalState or capture(catalog)
        local ok, removed = tasks.pcall(function()
            local copies, unexpected, keep, approved = {}, {}, {}, {}
            for _, photo in ipairs(collection:getPhotos()) do
                if isTemporary(photo) then
                    copies[#copies + 1] = photo
                elseif photo:getRawMetadata('isVirtualCopy') == true and id(photo) then
                    unexpected[#unexpected + 1] = photo
                else
                    keep[#keep + 1] = photo
                end
            end
            for _, copy in ipairs(unexpected) do
                local copyId = id(copy)
                local name = copy:getFormattedMetadata('fileName') or copyId
                local label = copy:getFormattedMetadata('copyName') or '(unnamed)'
                local answer = dialogs.confirm('Unexpected virtual copy',
                    tostring(name) .. ' — ' .. tostring(label)
                        .. '\n\nRemove this virtual copy from the catalog? '
                        .. 'Keep Copy preserves it in the catalog and removes it only '
                        .. 'from the temporary collection.',
                    'Keep Copy', 'Cancel', 'Remove Virtual Copy')
                if answer == 'other' then
                    approved[copyId] = true
                    copies[#copies + 1] = copy
                else
                    keep[#keep + 1] = copy
                end
            end
            if #copies > 0 then
                if not switchModule('library') then return false end
                local ids = {}
                for _, copy in ipairs(copies) do ids[#ids + 1] = id(copy) end
                local members = {}
                for _, photo in ipairs(collection:getPhotos()) do members[id(photo)] = true end
                for _, copyId in ipairs(ids) do
                    if not members[copyId] then return false end
                end
                -- Remove from the catalog, not merely from the collection.
                if not setSources(catalog, catalog.kAllPhotos) then return false end
                view.gridView()
                if not selectPhotos(catalog, copies[1], copies) then return false end
                for _, copy in ipairs(catalog:getTargetPhotos()) do
                    if copy:getRawMetadata('isVirtualCopy') ~= true
                        or not (isTemporary(copy) or approved[id(copy)]) then return false end
                end
                selection.removeFromCatalog()
                if not waitFor(function()
                    for _, copyId in ipairs(ids) do
                        if catalog:findPhotoByUuid(copyId) then return false end
                    end
                    return true
                end) then
                    trace('Virtual copies remain in catalog after removal')
                    -- Keep any surviving copies discoverable in the cleanup collection.
                    local remaining, queued = {}, {}
                    for _, copy in ipairs(collection:getPhotos()) do queued[id(copy)] = true end
                    for _, copyId in ipairs(ids) do
                        local copy = catalog:findPhotoByUuid(copyId)
                        if copy and not queued[copyId]
                            and copy:getRawMetadata('isVirtualCopy') == true then
                            remaining[#remaining + 1] = copy
                        end
                    end
                    if #remaining > 0 then
                        write(catalog, 'Crush Catalog: retain remaining copies',
                            function() collection:addPhotos(remaining) end)
                    end
                    return false
                end
            end
            -- Remove kept photos from the collection only, never from the catalog.
            if #keep > 0 then
                local remaining = {}
                for _, photo in ipairs(collection:getPhotos()) do remaining[id(photo)] = true end
                local members = {}
                for _, photo in ipairs(keep) do
                    if id(photo) and remaining[id(photo)] then members[#members + 1] = photo end
                end
                if #members > 0 then
                    if not write(catalog, 'Crush Catalog: clear temporary collection',
                        function() collection:removePhotos(members) end) then return false end
                end
            end
            return #collection:getPhotos() == 0
        end)
        local restored, restoreResult = tasks.pcall(restore, catalog, state)
        trace('Finish: ' .. tostring(ok) .. ' ' .. tostring(removed)
            .. '; restore=' .. tostring(restored) .. ' ' .. tostring(restoreResult))
        if not ok or not removed then return false end
        if not restored or not restoreResult then
            trace('Unable to fully restore the original Lightroom selection')
            -- Do not leave an empty cleanup collection or report a false
            -- processing failure because of a cosmetic UI problem.
            if type(dialogs.message) == 'function' then
                tasks.pcall(dialogs.message, 'Photo selection changed',
                    'Lightroom could not restore your previous photo selection. '
                        .. 'Please select your photos again if needed.', 'info')
            end
        end
        if not write(catalog, 'Crush Catalog: remove temporary collection', function()
            if #collection:getPhotos() ~= 0 then error('Temporary collection not empty', 0) end
            collection:delete()
        end) then return false end
        collection, collectionCatalog, originalState = nil, nil, nil
        restorationPending = false
        return true
    end
    return render, cleanup, finish
end

return Render
