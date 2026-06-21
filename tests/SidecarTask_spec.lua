describe('SidecarTask', function()
    local originalImport
    local originalPhotoMetadata
    local originalSidecarFiles

    before_each(function()
        originalImport = _G.import
        originalPhotoMetadata = package.loaded.PhotoMetadata
        originalSidecarFiles = package.loaded.SidecarFiles
    end)

    after_each(function()
        _G.import = originalImport
        package.loaded.PhotoMetadata = originalPhotoMetadata
        package.loaded.SidecarFiles = originalSidecarFiles
    end)

    local function loadTask(photos, progress, files, metadata, sleeps)
        package.loaded.PhotoMetadata = metadata
        package.loaded.SidecarFiles = files
        _G.import = function(name)
            local imports = {
                LrApplication = {
                    activeCatalog = function()
                        return { getTargetPhotos = function() return photos end }
                    end,
                },
                LrDialogs = { message = function() end },
                LrPathUtils = {
                    leafName = function(path) return path:match('[^/]+$') end,
                },
                LrProgressScope = function() return progress end,
                LrTasks = {
                    pcall = pcall,
                    sleep = function(seconds) sleeps[#sleeps + 1] = seconds end,
                },
            }
            return assert(imports[name])
        end

        return assert(loadfile('crush-catalog.lrplugin/SidecarTask.lua'))()
    end

    it('pauses, resumes, and reports export progress', function()
        local captions = {}
        local portions = {}
        local sleeps = {}
        local paused = true
        local exports = {}
        local photo = {
            getRawMetadata = function(_, key)
                if key == 'path' then return '/photos/bird.CR3' end
                return false
            end,
            getFormattedMetadata = function(_, key)
                if key == 'fileName' then return 'bird.CR3' end
            end,
        }
        local progress = {}
        function progress:setCancelable(value) self.cancelable = value end
        function progress:setPausable(value) self.pausable = value end
        function progress.isPaused()
            local result = paused
            paused = false
            return result
        end
        function progress.isCanceled() return false end
        function progress.setCaption(_, value) captions[#captions + 1] = value end
        function progress.setPortionComplete(_, done, total)
            portions[#portions + 1] = { done, total }
        end
        function progress:done() self.completed = true end

        local component = loadTask({ photo }, progress, {
            export = function(path, sourceFile, values)
                exports[#exports + 1] = { path, sourceFile, values }
            end,
        }, {
            read = function() return { detectionCount = '1' } end,
        }, sleeps)

        component.exportSelectedPhotos()

        assert.is_true(progress.cancelable)
        assert.is_true(progress.pausable)
        assert.is_true(progress.completed)
        assert.same({ 0.2 }, sleeps)
        assert.same({
            'Backing up identification data for bird.CR3 (1 of 1) - Paused',
            'Backing up identification data for bird.CR3 (1 of 1)',
            'Backing up identification data for bird.CR3 (1 of 1)',
        }, captions)
        assert.same({ { 0, 1 }, { 1, 1 } }, portions)
        assert.are.equal('/photos/bird.CR3', exports[1][1])
        assert.are.equal('bird.CR3', exports[1][2])
    end)

    it('can be canceled while paused without processing a photo', function()
        local sleeps = 0
        local canceled = false
        local progress = {}
        function progress.setCancelable() end
        function progress.setPausable() end
        function progress.isPaused() return true end
        function progress.isCanceled() return canceled end
        function progress.setCaption() end
        function progress.setPortionComplete() error('should not process') end
        function progress:done() self.completed = true end

        local component = loadTask({ {
            getRawMetadata = function() return false end,
            getFormattedMetadata = function() return 'bird.CR3' end,
        } }, progress, {
            export = function() error('should not export') end,
        }, {
            read = function() error('should not read') end,
        }, setmetatable({}, {
            __newindex = function()
                sleeps = sleeps + 1
                canceled = true
            end,
        }))

        component.exportSelectedPhotos()
        assert.are.equal(1, sleeps)
        assert.is_true(progress.completed)
    end)

    it('silently excludes virtual copies from export progress', function()
        local exports = {}
        local portions = {}
        local progress = {}
        local function photo(path, virtual)
            return {
                getRawMetadata = function(_, key)
                    if key == 'isVirtualCopy' then return virtual end
                    if key == 'path' then return path end
                end,
                getFormattedMetadata = function()
                    return path:match('[^/]+$')
                end,
            }
        end
        function progress.setCancelable() end
        function progress.setPausable() end
        function progress.isPaused() return false end
        function progress.isCanceled() return false end
        function progress.setCaption(_, value) progress.caption = value end
        function progress.setPortionComplete(_, done, total)
            portions[#portions + 1] = { done, total }
        end
        function progress.done() end

        local original = photo('/photos/original.CR3', false)
        local virtual = photo('/photos/original.CR3', true)
        local component = loadTask({ virtual, original }, progress, {
            export = function(_, sourceFile)
                exports[#exports + 1] = sourceFile
            end,
        }, {
            read = function() return {} end,
        }, {})

        component.exportSelectedPhotos()

        assert.same({ 'original.CR3' }, exports)
        assert.are.equal(
            'Backing up identification data for original.CR3 (1 of 1)',
            progress.caption
        )
        assert.same({ { 0, 1 }, { 1, 1 } }, portions)
    end)

    it('does nothing when importing a virtual-copy-only selection', function()
        local component = loadTask({ {
            getRawMetadata = function(_, key)
                assert.are.equal('isVirtualCopy', key)
                return true
            end,
        } }, nil, {
            import = function() error('should not read sidecar') end,
        }, {
            write = function() error('should not write metadata') end,
        }, {})

        component.importSelectedPhotos()
    end)
end)
