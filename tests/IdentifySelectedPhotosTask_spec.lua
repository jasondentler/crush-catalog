describe('IdentifySelectedPhotosTask', function()
    local originalImport
    local originalApi
    local originalAutomaticModesDialog
    local originalDialog
    local originalLoc
    local originalPhotoMetadata

    before_each(function()
        originalImport = _G.import
        originalApi = package.loaded.WildCatalogApi
        originalAutomaticModesDialog = package.loaded.AutomaticModesDialog
        originalDialog = package.loaded.IdentificationDialog
        originalPhotoMetadata = package.loaded.PhotoMetadata
        originalLoc = _G.LOC
        _G.LOC = function(value)
            return value:match('=(.*)$') or value
        end
    end)

    after_each(function()
        _G.import = originalImport
        package.loaded.WildCatalogApi = originalApi
        package.loaded.AutomaticModesDialog = originalAutomaticModesDialog
        package.loaded.IdentificationDialog = originalDialog
        package.loaded.PhotoMetadata = originalPhotoMetadata
        _G.LOC = originalLoc
    end)

    it('identifies each selected photo with its Lightroom metadata', function()
        local identifyCalls = {}
        local batchOptions = { mode = 'manual', threshold = 90, reprocess = true }
        local dialogCalls = {}
        local dialogAction = 'continue'
        local protectedCalls = 0
        local recordCalls = {}
        local recordsToFail = 0
        local messages = {}
        local traceCalls = {}
        local selectedPhotos
        local task
        local progress = {
            portions = {},
        }
        local photo = {
            raw = {
                path = '/photos/bird-renamed.jpg',
                gps = { latitude = 29.573361, longitude = -94.389507 },
                dateTimeOriginalISO8601 = '2026-05-01T12:30:00Z',
            },
            formatted = {
                preservedFileName = 'bird.jpg',
            },
            requestedRawKeys = {},
            requestedFormattedKeys = {},
        }

        function photo:getRawMetadata(key)
            self.requestedRawKeys[#self.requestedRawKeys + 1] = key
            return self.raw[key]
        end

        function photo:getFormattedMetadata(key)
            self.requestedFormattedKeys[#self.requestedFormattedKeys + 1] = key
            return self.formatted[key]
        end

        function photo:getPropertyForPlugin(_, key)
            return self.pluginMetadata and self.pluginMetadata[key]
        end

        selectedPhotos = { photo }

        function progress:setCancelable(value)
            self.cancelable = value
        end

        progress.isCanceled = function()
            return false
        end

        function progress:setCaption(value)
            self.caption = value
        end

        function progress:setPortionComplete(completed, total)
            self.portions[#self.portions + 1] = { completed, total }
        end

        function progress:done()
            self.completed = true
        end

        function progress:cancel()
            self.wasCanceled = true
        end

        package.loaded.WildCatalogApi = {
            JSON = {
                encode = function(_, value)
                    if value.action ~= nil then
                        return 'dialog:' .. value.action
                    end

                    return 'backend-response'
                end,
            },
            identify = function(path, options)
                identifyCalls[#identifyCalls + 1] = { path = path, options = options }
                return {
                    result = { results = {} },
                    detectedImages = { { bytes = 'jpeg bytes', contentType = 'image/jpeg' } },
                }
            end,
        }
        package.loaded.IdentificationDialog = {
            showForResponse = function(
                selectedPhoto,
                response,
                imageIndex,
                imageCount,
                options
            )
                dialogCalls[#dialogCalls + 1] = {
                    photo = selectedPhoto,
                    response = response,
                    imageIndex = imageIndex,
                    imageCount = imageCount,
                    options = options,
                }
                return dialogAction, { { disposition = 'confirmed' } }
            end,
        }
        package.loaded.AutomaticModesDialog = {
            show = function()
                return batchOptions
            end,
        }
        package.loaded.PhotoMetadata = {
            record = function(selectedPhoto, dispositions, reprocessing)
                recordCalls[#recordCalls + 1] = {
                    photo = selectedPhoto,
                    dispositions = dispositions,
                    reprocessing = reprocessing,
                }

                if recordsToFail > 0 then
                    recordsToFail = recordsToFail - 1
                    error('write timeout')
                end
            end,
            trace = function(message)
                traceCalls[#traceCalls + 1] = message
            end,
        }

        _G.import = function(name)
            local imports = {
                LrApplication = {
                    activeCatalog = function()
                        return {
                            getTargetPhotos = function()
                                return selectedPhotos
                            end,
                        }
                    end,
                },
                LrDialogs = {
                    message = function(title, message)
                        messages[#messages + 1] = { title = title, message = message }
                    end,
                },
                LrLocalization = { currentLanguage = function() return 'en-US' end },
                LrProgressScope = function() return progress end,
                LrTasks = {
                    pcall = function(...)
                        protectedCalls = protectedCalls + 1
                        return pcall(...)
                    end,
                    startAsyncTask = function(callback)
                        task = callback
                    end,
                },
            }

            return assert(imports[name], 'Unexpected Lightroom import: ' .. tostring(name))
        end

        local component = assert(
            loadfile('crush-catalog.lrplugin/IdentifySelectedPhotosTask.lua')
        )()
        task()

        assert.is_true(progress.cancelable)
        assert.is_true(progress.completed)
        assert.same({ { 0, 1 }, { 1, 1 } }, progress.portions)
        assert.are.equal('bird.jpg', progress.caption)
        assert.are.equal('/photos/bird-renamed.jpg', identifyCalls[1].path)
        assert.are.equal('bird.jpg', identifyCalls[1].options.originalFilename)
        assert.are.equal('2026-05-01T12:30:00Z', identifyCalls[1].options.exifOverride.captured_at)
        assert.same(
            { 'gps', 'dateTimeOriginalISO8601', 'path' },
            photo.requestedRawKeys
        )
        assert.same({ 'preservedFileName' }, photo.requestedFormattedKeys)
        assert.same(
            { latitude = 29.573361, longitude = -94.389507 },
            identifyCalls[1].options.exifOverride.gps_coordinates
        )
        assert.is_true(identifyCalls[1].options.return_detected_images)
        assert.are.equal('en-US', identifyCalls[1].options.common_name_language)
        assert.are.equal(photo, dialogCalls[1].photo)
        assert.are.equal(1, dialogCalls[1].imageIndex)
        assert.are.equal(1, dialogCalls[1].imageCount)
        assert.are.equal('manual', dialogCalls[1].options.mode)
        assert.are.equal(3, protectedCalls)
        assert.are.equal(photo, recordCalls[1].photo)
        assert.are.equal('confirmed', recordCalls[1].dispositions[1].disposition)
        assert.is_false(recordCalls[1].reprocessing)
        assert.same({
            'Beginning identification; selected photos=1',
            'Using manual mode for single-photo selection',
            'Photos eligible for identification=1',
            'Backend API response JSON for bird.jpg: backend-response',
            'Dialog result JSON for bird.jpg: dialog:continue',
            'Finished identification; failures=0',
        }, traceCalls)

        batchOptions = nil
        identifyCalls = {}
        selectedPhotos = { photo, photo }
        component.identifySelectedPhotos()
        assert.are.equal(0, #identifyCalls)

        batchOptions = { mode = 'assisted', threshold = 90, reprocess = false }
        photo.pluginMetadata = { detectionCount = '1', unsureCount = '0' }
        component.identifySelectedPhotos()
        assert.are.equal(0, #identifyCalls)

        photo.pluginMetadata.unsureCount = '1'
        dialogAction = 'next_image'
        identifyCalls = {}
        component.identifySelectedPhotos()
        assert.are.equal(2, #identifyCalls)
        assert.are.equal(1, #recordCalls)

        batchOptions.reprocess = true
        dialogAction = 'continue'
        identifyCalls = {}
        recordCalls = {}
        recordsToFail = 1
        selectedPhotos = { photo, photo }
        component.identifySelectedPhotos()
        assert.are.equal(2, #identifyCalls)
        assert.are.equal(2, #recordCalls)
        assert.matches('write timeout', messages[#messages].message)

        dialogAction = 'stop'
        identifyCalls = {}
        selectedPhotos = { photo, photo }
        component.identifySelectedPhotos()
        assert.are.equal(1, #identifyCalls)
        assert.is_true(progress.wasCanceled)
    end)
end)
