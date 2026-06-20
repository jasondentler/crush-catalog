describe('ClearSelectedPhotosTask', function()
    local originalImport
    local originalLoc
    local originalPhotoMetadata

    before_each(function()
        originalImport = _G.import
        originalLoc = _G.LOC
        originalPhotoMetadata = package.loaded.PhotoMetadata
        _G.LOC = function(value)
            return value:match('=(.*)$') or value
        end
    end)

    after_each(function()
        _G.import = originalImport
        _G.LOC = originalLoc
        package.loaded.PhotoMetadata = originalPhotoMetadata
    end)

    it('confirms and clears every selected photo while reporting failures', function()
        local cleared = {}
        local messages = {}
        local task
        local progress = { portions = {} }
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
        }

        function progress:setCancelable(value) self.cancelable = value end
        function progress.isCanceled() return false end
        function progress:setCaption(value) self.caption = value end
        function progress:setPortionComplete(done, total)
            self.portions[#self.portions + 1] = { done, total }
        end
        function progress:done() self.completed = true end

        package.loaded.PhotoMetadata = {
            clear = function(photo)
                cleared[#cleared + 1] = photo
                if photo == photos[2] then error('write timeout') end
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
                    confirm = function(title, prompt, okButton, cancelButton)
                        assert.are.equal('Clear Data from Selected Photos?', title)
                        assert.is_truthy(prompt:match('2 selected photo'))
                        assert.are.equal('Clear Selected Photos', okButton)
                        assert.are.equal('Cancel', cancelButton)
                        return 'ok'
                    end,
                    message = function(title, message, kind)
                        messages[#messages + 1] = {
                            title = title,
                            message = message,
                            kind = kind,
                        }
                    end,
                },
                LrProgressScope = function() return progress end,
                LrTasks = {
                    pcall = pcall,
                    startAsyncTask = function(callback) task = callback end,
                },
            }
            return assert(imports[name])
        end

        local component = assert(loadfile(
            'crush-catalog.lrplugin/ClearSelectedPhotosTask.lua'
        ))()
        task()

        assert.same(photos, cleared)
        assert.is_true(progress.cancelable)
        assert.is_true(progress.completed)
        assert.are.equal('Clearing second.jpg (2 of 2)', progress.caption)
        assert.same({ { 0, 2 }, { 1, 2 }, { 1, 2 }, { 2, 2 } }, progress.portions)
        assert.are.equal(1, #messages)
        assert.are.equal('warning', messages[1].kind)
        assert.is_truthy(messages[1].message:match('second.jpg:'))
        assert.are.equal('second.jpg', component.photoLabel(photos[2]))
    end)

    it('does nothing when confirmation is canceled', function()
        local clearCalls = 0
        local task

        package.loaded.PhotoMetadata = {
            clear = function() clearCalls = clearCalls + 1 end,
        }
        _G.import = function(name)
            local imports = {
                LrApplication = {
                    activeCatalog = function()
                        return { getTargetPhotos = function() return { {} } end }
                    end,
                },
                LrDialogs = { confirm = function() return 'cancel' end },
                LrProgressScope = function() error('progress should not be created') end,
                LrTasks = {
                    pcall = pcall,
                    startAsyncTask = function(callback) task = callback end,
                },
            }
            return assert(imports[name])
        end

        assert(loadfile('crush-catalog.lrplugin/ClearSelectedPhotosTask.lua'))()
        task()
        assert.are.equal(0, clearCalls)
    end)
end)
