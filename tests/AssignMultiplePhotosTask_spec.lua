describe('AssignMultiplePhotosTask', function()
    local originalImport
    local originalLoc
    local originalIdentificationSearchDialog
    local originalPhotoMetadata

    before_each(function()
        originalImport = _G.import
        originalLoc = _G.LOC
        originalIdentificationSearchDialog = package.loaded.IdentificationSearchDialog
        originalPhotoMetadata = package.loaded.PhotoMetadata
        _G.LOC = function(value)
            return value:match('=(.*)$') or value
        end
    end)

    after_each(function()
        _G.import = originalImport
        _G.LOC = originalLoc
        package.loaded.IdentificationSearchDialog = originalIdentificationSearchDialog
        package.loaded.PhotoMetadata = originalPhotoMetadata
    end)

    it('searches once and assigns the selected species to every selected photo', function()
        local messages = {}
        local progress = { portions = {} }
        local recordCalls = {}
        local searchCalls = {}
        local sleepCalls = 0
        local task
        local traceCalls = {}
        local selectedPrediction = {
            taxonomy = { 'Animalia', 'Eudocimus', 'albus' },
            taxonomyRanks = { 'kingdom', 'genus', 'species' },
            commonNameTaxonomy = { 'Animals', 'Ibises', 'White Ibis' },
        }
        local photos = {
            {
                getFormattedMetadata = function(_, key)
                    if key == 'preservedFileName' then return 'first.jpg' end
                end,
            },
            {
                getFormattedMetadata = function(_, key)
                    if key == 'fileName' then return 'second.jpg' end
                end,
            },
            {
                getFormattedMetadata = function(_, key)
                    if key == 'fileName' then return 'third.jpg' end
                end,
            },
        }

        function progress:setCancelable(value) self.cancelable = value end
        function progress:setPausable(value) self.pausable = value end
        function progress:isCanceled() return self.canceled or false end
        function progress:isPaused() return self.paused or false end
        function progress:setCaption(value) self.caption = value end
        function progress:setPortionComplete(done, total)
            self.portions[#self.portions + 1] = { done, total }
        end
        function progress:done() self.completed = true end

        package.loaded.IdentificationSearchDialog = {
            show = function(options)
                searchCalls[#searchCalls + 1] = options
                return {
                    action = 'manual',
                    selectedPrediction = selectedPrediction,
                }
            end,
        }
        package.loaded.PhotoMetadata = {
            record = function(photo, detections, reprocessing)
                recordCalls[#recordCalls + 1] = {
                    photo = photo,
                    detections = detections,
                    reprocessing = reprocessing,
                }

                if photo == photos[2] then error('write timeout') end
            end,
            trace = function(message)
                traceCalls[#traceCalls + 1] = message
            end,
        }

        _G.import = function(name)
            local imports = {
                LrApplication = {
                    activeCatalog = function()
                        return { getTargetPhotos = function() return photos end }
                    end,
                },
                LrDialogs = {
                    message = function(title, message, kind)
                        messages[#messages + 1] = {
                            title = title,
                            message = message,
                            kind = kind,
                        }
                    end,
                },
                LrLocalization = {
                    currentLanguage = function() return 'en-US' end,
                },
                LrProgressScope = function() return progress end,
                LrTasks = {
                    pcall = pcall,
                    sleep = function()
                        sleepCalls = sleepCalls + 1
                        progress.paused = false
                    end,
                    startAsyncTask = function(callback) task = callback end,
                },
            }

            return assert(imports[name], 'Unexpected Lightroom import: ' .. tostring(name))
        end

        local component = assert(loadfile(
            'crush-catalog.lrplugin/AssignMultiplePhotosTask.lua'
        ))()
        task()

        assert.are.equal(1, #searchCalls)
        assert.are.equal('en-US', searchCalls[1].commonNameLanguage)
        assert.is_true(progress.cancelable)
        assert.is_true(progress.pausable)
        assert.is_true(progress.completed)
        assert.are.equal('Assigning third.jpg (3 of 3)', progress.caption)
        assert.same({
            { 0, 3 },
            { 1, 3 },
            { 1, 3 },
            { 2, 3 },
            { 2, 3 },
            { 3, 3 },
        }, progress.portions)
        assert.are.equal(3, #recordCalls)

        for index, call in ipairs(recordCalls) do
            assert.are.equal(photos[index], call.photo)
            assert.is_true(call.reprocessing)
            assert.are.equal(1, #call.detections)
            assert.are.equal('manual', call.detections[1].disposition)
            assert.same(selectedPrediction, call.detections[1].selectedPrediction)
        end

        assert.are.equal(1, #messages)
        assert.are.equal('warning', messages[1].kind)
        assert.is_truthy(messages[1].message:match('second.jpg:'))
        assert.are.equal(
            'Beginning multiple assignment; selected photos=3',
            traceCalls[1]
        )
        assert.matches(
            'Multiple assignment failure: second%.jpg: .*write timeout',
            traceCalls[2]
        )
        assert.are.equal('Finished multiple assignment; failures=1', traceCalls[3])

        progress.paused = true
        component.waitWhilePaused(progress)
        assert.are.equal(1, sleepCalls)
        assert.are.equal('Assignment paused', traceCalls[#traceCalls - 1])
        assert.are.equal('Assignment resumed', traceCalls[#traceCalls])
        assert.are.equal('Assignment paused', progress.caption)
        assert.are.equal('second.jpg', component.photoLabel(photos[2]))
    end)

    it('does not write when no photos are selected or no manual result is chosen', function()
        local progressCreated = false
        local recordCalls = 0
        local searchCalls = 0
        local task
        local photos = {}
        local searchResult = {
            action = 'unsure',
        }

        package.loaded.IdentificationSearchDialog = {
            show = function()
                searchCalls = searchCalls + 1
                return searchResult
            end,
        }
        package.loaded.PhotoMetadata = {
            record = function()
                recordCalls = recordCalls + 1
            end,
            trace = function() end,
        }

        _G.import = function(name)
            local imports = {
                LrApplication = {
                    activeCatalog = function()
                        return { getTargetPhotos = function() return photos end }
                    end,
                },
                LrDialogs = {},
                LrLocalization = {
                    currentLanguage = function() return 'en-US' end,
                },
                LrProgressScope = function()
                    progressCreated = true
                    return {}
                end,
                LrTasks = {
                    pcall = pcall,
                    startAsyncTask = function(callback) task = callback end,
                },
            }

            return assert(imports[name], 'Unexpected Lightroom import: ' .. tostring(name))
        end

        local component = assert(loadfile(
            'crush-catalog.lrplugin/AssignMultiplePhotosTask.lua'
        ))()
        task()
        assert.are.equal(0, searchCalls)
        assert.are.equal(0, recordCalls)
        assert.is_false(progressCreated)

        photos = { { getFormattedMetadata = function() return 'bird.jpg' end } }
        component.assignMultiplePhotos()
        assert.are.equal(1, searchCalls)
        assert.are.equal(0, recordCalls)
        assert.is_false(progressCreated)
    end)

    it('stops before the next photo when progress is canceled', function()
        local progress = { portions = {} }
        local recordCalls = 0
        local task
        local photos = {
            { getFormattedMetadata = function() return 'first.jpg' end },
            { getFormattedMetadata = function() return 'second.jpg' end },
        }

        function progress:setCancelable(value) self.cancelable = value end
        function progress:setPausable(value) self.pausable = value end
        progress.isPaused = function() return false end
        progress.isCanceled = function() return recordCalls > 0 end
        function progress:setCaption(value) self.caption = value end
        function progress:setPortionComplete(done, total)
            self.portions[#self.portions + 1] = { done, total }
        end
        function progress:done() self.completed = true end

        package.loaded.IdentificationSearchDialog = {
            show = function()
                return {
                    action = 'manual',
                    selectedPrediction = { taxonomy = { 'Animalia' } },
                }
            end,
        }
        package.loaded.PhotoMetadata = {
            record = function()
                recordCalls = recordCalls + 1
            end,
            trace = function() end,
        }

        _G.import = function(name)
            local imports = {
                LrApplication = {
                    activeCatalog = function()
                        return { getTargetPhotos = function() return photos end }
                    end,
                },
                LrDialogs = {},
                LrLocalization = {
                    currentLanguage = function() return 'en-US' end,
                },
                LrProgressScope = function() return progress end,
                LrTasks = {
                    pcall = pcall,
                    sleep = function() end,
                    startAsyncTask = function(callback) task = callback end,
                },
            }

            return assert(imports[name], 'Unexpected Lightroom import: ' .. tostring(name))
        end

        assert(loadfile('crush-catalog.lrplugin/AssignMultiplePhotosTask.lua'))()
        task()

        assert.are.equal(1, recordCalls)
        assert.is_true(progress.completed)
        assert.same({ { 0, 2 }, { 1, 2 } }, progress.portions)
    end)
end)
