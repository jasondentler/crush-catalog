describe('IdentifySelectedPhotosTask', function()
    local originalImport
    local originalApi
    local originalAutomaticModesDialog
    local originalDialog
    local originalLoc
    local originalPhotoMetadata
    local originalPreparation
    local originalConfirmation

    before_each(function()
        originalImport = _G.import
        originalApi = package.loaded.WildCatalogApi
        originalAutomaticModesDialog = package.loaded.AutomaticModesDialog
        originalDialog = package.loaded.IdentificationDialog
        originalPhotoMetadata = package.loaded.PhotoMetadata
        originalPreparation = package.loaded.BatchPreparation
        originalConfirmation = package.loaded.BatchConfirmation
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
        package.loaded.BatchPreparation = originalPreparation
        package.loaded.BatchConfirmation = originalConfirmation
        _G.LOC = originalLoc
    end)

    it('identifies each selected photo with its Lightroom metadata', function()
        local identifyCalls = {}
        local batchOptions = { mode = 'manual', threshold = 90, processingScope = 'all' }
        local dialogCalls = {}
        local dialogAction = 'continue'
        local protectedCalls = 0
        local recordCalls = {}
        local recordsToFail = 0
        local messages = {}
        local traceCalls = {}
        local selectedPhotos
        local task
        local currentTime = 0
        local sleepCalls = 0
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

        function progress:setPausable(value)
            self.pausable = value
        end

        progress.isCanceled = function()
            return false
        end

        function progress:isPaused()
            return self.paused or false
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
                LrDate = {
                    currentTime = function()
                        local value = currentTime
                        currentTime = currentTime + 900
                        return value
                    end,
                },
                LrFunctionContext = {
                    postAsyncTaskWithContext = function(_, callback) task = callback end,
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
                    sleep = function()
                        sleepCalls = sleepCalls + 1
                        progress.paused = false
                    end,
                },
            }

            return assert(imports[name], 'Unexpected Lightroom import: ' .. tostring(name))
        end

        local component = assert(
            loadfile('crush-catalog.lrplugin/IdentifySelectedPhotosTask.lua')
        )()
        assert.are.equal('15m remaining', component.formatRemaining(15 * 60))
        assert.are.equal('1h 2m remaining', component.formatRemaining(62 * 60))
        assert.are.equal(300, component.estimateRemaining({ 60, 90 }, 4))
        assert.are.equal(60, component.estimateRemaining({
            3600,
            60, 60, 60, 60, 60,
            60, 60, 60, 60, 60,
        }, 1))
        task()

        assert.is_true(progress.cancelable)
        assert.is_true(progress.pausable)
        assert.is_true(progress.completed)
        assert.same({ { 0, 1 }, { 1, 1 } }, progress.portions)
        assert.are.equal('Identifying bird.jpg (1 of 1)', progress.caption)
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
        assert.same(
            { latitude = 29.573361, longitude = -94.389507 },
            dialogCalls[1].options.gpsCoordinates
        )
        assert.are.equal('en-US', dialogCalls[1].options.commonNameLanguage)
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

        progress.paused = true
        component.waitWhilePaused(progress)
        assert.are.equal(1, sleepCalls)
        assert.are.equal('Identification paused', progress.caption)
        assert.are.equal('Identification paused', traceCalls[#traceCalls - 1])
        assert.are.equal('Identification resumed', traceCalls[#traceCalls])

        batchOptions = nil
        identifyCalls = {}
        selectedPhotos = { photo, photo }
        component.identifySelectedPhotos()
        assert.are.equal(0, #identifyCalls)

        batchOptions = { mode = 'assisted', threshold = 90, processingScope = 'new' }
        photo.pluginMetadata = { detectionCount = '1', unsureCount = '0' }
        component.identifySelectedPhotos()
        assert.are.equal(0, #identifyCalls)

        batchOptions.processingScope = 'new_and_unsure'
        photo.pluginMetadata.unsureCount = '1'
        dialogAction = 'next_image'
        identifyCalls = {}
        component.identifySelectedPhotos()
        assert.are.equal(2, #identifyCalls)
        assert.are.equal('Identifying bird.jpg (2 of 2)', progress.caption)
        assert.is_true(identifyCalls[1].options.return_detected_images)
        assert.are.equal(1, #recordCalls)

        batchOptions.mode = 'automatic'
        identifyCalls = {}
        component.identifySelectedPhotos()
        assert.are.equal(2, #identifyCalls)
        assert.are.equal('Identifying bird.jpg (2 of 2) - 15m remaining', progress.caption)
        assert.is_false(identifyCalls[1].options.return_detected_images)

        batchOptions.processingScope = 'all'
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


        -- Multi-photo identification uses the production route without diagnostics.
        local plan = {
            manifest = { frames = {
                { frame_id = 'a', representations = { {}, {} } },
                { frame_id = 'b', representations = { {} } },
            } },
            items = { a = { item = { photo = photo } }, b = { item = { photo = {} } } },
        }
        package.loaded.BatchPreparation = {
            renderRun = function() return { finish = function() return true end } end,
            prepare = function(photos, options)
                assert.are.equal(2, #photos)
                assert.are.equal('en-US', options.language)
                return { plan }, {}
            end,
            isCurrent = function() return true end,
        }
        package.loaded.BatchConfirmation = {
            run = function(receivedPlan, _, options)
                assert.are.equal(plan, receivedPlan)
                assert.are.equal('automatic', options.mode)
                assert.is_nil(receivedPlan.manifest.archive_run_id)
                assert.is_nil(options.onArchive)
                assert.is_nil(options.analysisOnly)
                return {
                    results = { { frame_id = 'a', status = 'identified' },
                        { frame_id = 'b', status = 'no_detection' } },
                    confirmations = { approved = {
                        { frame_id = 'a', dispositions = { { disposition = 'confirmed' } } },
                    } },
                }
            end,
        }
        local batchWrites = 0
        package.loaded.PhotoMetadata.recordBatch = function(entries, validate)
            batchWrites = batchWrites + 1
            assert.are.equal(1, #entries)
            assert.are.equal(photo, entries[1].photo)
            assert.is_true(validate())
            return 'executed'
        end
        batchOptions.engine = 'batch'
        identifyCalls = {}
        component.identifySelectedPhotos()
        assert.are.equal('2 of 2 - 0 remaining', progress.caption)
        assert.are.equal(0, #identifyCalls)
        assert.are.equal(1, batchWrites)

        -- A failed frame must appear in the final summary with its filename.
        plan.items.b.item.photo = photo
        local confirm = package.loaded.BatchConfirmation.run
        package.loaded.BatchConfirmation.run = function(...)
            local final = confirm(...)
            final.results[2].status = 'failed'
            final.results[2].error_code = 'payload_too_large'
            return final
        end
        component.identifySelectedPhotos()
        assert.are.equal(2, batchWrites)
        assert.matches('Failed: 1', messages[#messages].message, 1, true)
        assert.matches('Withheld: 0', messages[#messages].message, 1, true)
        assert.matches('bird.jpg: Image too large for identification', messages[#messages].message, 1, true)

        -- Single-image transport failures must not reach confirmation or metadata writes.
        selectedPhotos = { photo }
        local recordCount, dialogCount = #recordCalls, #dialogCalls
        package.loaded.WildCatalogApi.identify = function()
            error('Image too large for identification (HTTP 413)', 0)
        end
        component.identifySelectedPhotos()
        assert.are.equal(recordCount, #recordCalls)
        assert.are.equal(dialogCount, #dialogCalls)
        assert.matches('bird.jpg: Image too large for identification (HTTP 413)',
            messages[#messages].message, 1, true)
    end)
end)
