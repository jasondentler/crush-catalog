local Render = assert(loadfile('crush-catalog.lrplugin/LightroomRender.lua'))()

local function fixture(failAt, answer)
    local oldImport = _G.import
    local existing = { ['/original.ARW'] = 'file' }
    local dir = '/tmp/crush-render-1234'
    local file = dir .. '/original.jpg'
    local catalog, calls, registry = { kAllPhotos = 'all photos' }, {}, {}
    local module = 'library'
    local function makePhoto(uuid, master, name)
        local photo = { catalog = catalog }
        function photo.getRawMetadata(_self, key)
            if key == 'uuid' then return uuid end
            if key == 'isVirtualCopy' then return master ~= nil end
            if key == 'masterPhoto' then return master end
        end
        function photo.getFormattedMetadata(_self, key)
            if key == 'copyName' then return name end
        end
        registry[uuid] = photo
        return photo
    end
    local original = makePhoto('original')
    local other = makePhoto('other')
    local active, selected = other, { other, original }
    local captured, collection, members
    local sources = { 'original source' }
    local nextCopy, prompts, messages = 0, {}, {}
    function catalog.getTargetPhoto(_self) return active end
    function catalog.getTargetPhotos(_self) return selected end
    local pendingSources
    function catalog.setSelectedPhotos(_self, photo, others)
        assert.is_nil(pendingSources)
        active, selected = photo, { photo }
        for _, item in ipairs(others) do selected[#selected + 1] = item end
        if #others > 0 and failAt == 'restore_active' then
            active = others[1]
        elseif #others > 0 and failAt == 'restore_members' then
            selected = { photo }
        end
    end
    function catalog.getActiveSources(_self) return sources end
    function catalog.setActiveSources(_self, value)
        pendingSources = type(value) == 'string' and { value } or value
    end
    function catalog.withWriteAccessDo(_self, _, fn, options)
        assert.are.equal(30, options.timeout)
        fn()
        return 'executed'
    end
    function catalog.createCollection(_self, name, parent, reuse)
        assert.are.equal('Crush Catalog - Temporary Virtual Copies', name)
        assert.is_nil(parent)
        assert.is_true(reuse)
        if collection then return collection end
        calls[#calls + 1] = 'collection'
        members = {}
        collection = {
            isSmartCollection = function() return false end,
            getPhotos = function() return members end,
            addPhotos = function(_, copies)
                for _, copy in ipairs(copies) do members[#members + 1] = copy end
            end,
            removePhotos = function(_, photos)
                local remove = {}
                for _, photo in ipairs(photos) do remove[photo] = true end
                local remaining = {}
                for _, photo in ipairs(members) do
                    if not remove[photo] then remaining[#remaining + 1] = photo end
                end
                members = remaining
            end,
            delete = function()
                assert.are.equal(0, #members)
                calls[#calls + 1] = 'delete collection'
                collection = nil
            end,
        }
        return collection
    end
    function catalog.createVirtualCopies(_self, name)
        assert.same({ original }, selected)
        calls[#calls + 1] = 'create'
        if failAt == 'wrong_copy' then return { original } end
        nextCopy = nextCopy + 1
        return { makePhoto('copy' .. nextCopy, original, name) }
    end
    function catalog.findPhotoByUuid(_self, uuid) return registry[uuid] end
    local imports = {
        LrFileUtils = {
            exists = function(path) return existing[path] or false end,
            createAllDirectories = function(path)
                existing[path] = 'directory'
                return true, true
            end,
            delete = function(path)
                assert.are.equal(dir, path)
                existing[path], existing[file] = nil, nil
                return true
            end,
        },
        LrPathUtils = {
            child = function(parent, name) return parent .. '/' .. name end,
            parent = function(path) return path:match('^(.+)/[^/]+$') end,
            getStandardFilePath = function() return '/tmp' end,
        },
        LrUUID = { generateUUID = function() return '1234' end },
        LrTasks = {
            pcall = pcall,
            sleep = function()
                if pendingSources then sources, pendingSources = pendingSources, nil end
            end,
        },
        LrApplicationView = {
            getCurrentModuleName = function() return module end,
            switchToModule = function(value) module = value end,
            gridView = function() assert.are.equal('library', module) end,
        },
        LrDevelopController = {
            resetAllDevelopAdjustments = function()
                assert.are.equal('develop', module)
                assert.same({ registry['copy' .. nextCopy] }, selected)
                calls[#calls + 1] = 'reset'
                if failAt == 'reset' then error('reset failed') end
            end,
        },
        LrSelection = {
            removeFromCatalog = function()
                assert.same({ catalog.kAllPhotos }, sources)
                local remove = {}
                for _, copy in ipairs(selected) do
                    assert.is_true(copy:getRawMetadata('isVirtualCopy'))
                    if failAt ~= 'remove' then
                        registry[copy:getRawMetadata('uuid')] = nil
                        remove[copy] = true
                    end
                end
                calls[#calls + 1] = 'remove'
                local remaining = {}
                for _, photo in ipairs(members) do
                    if not remove[photo] then remaining[#remaining + 1] = photo end
                end
                members = remaining
            end,
        },
        LrDialogs = {
            message = function(title) messages[#messages + 1] = title end,
            confirm = function(title, message, action, cancel, alternate)
                prompts[#prompts + 1] = { title, message, action, cancel, alternate }
                return answer or 'cancel'
            end,
        },
        LrExportSession = function(options)
            captured = options
            assert.same({ registry['copy' .. nextCopy] }, options.photosToExport)
            calls[#calls + 1] = 'export'
            return {
                renditions = function()
                    return ipairs({ {
                        waitForRender = function()
                            if failAt == 'export' then return false, 'failed' end
                            existing[file] = 'file'
                            return true, file
                        end,
                    } })
                end,
            }
        end,
    }
    _G.import = function(name) return assert(imports[name]) end
    local ok, render, cleanup, finish = pcall(Render.create)
    _G.import = oldImport
    assert.is_true(ok)
    return {
        render = function() return render(original) end,
        cleanup = cleanup, finish = finish, calls = calls, file = file, registry = registry,
        prompts = prompts, messages = messages,
        collection = function() return collection end,
        addMaster = function() members[#members + 1] = original end,
        addForeignCopy = function()
            members[#members + 1] = makePhoto('foreign', original, 'My edit')
        end,
        seedPreviousRun = function()
            catalog:createCollection('Crush Catalog - Temporary Virtual Copies', nil, true)
            members[#members + 1] = makePhoto('previous', original, 'Crush Catalog temporary abcd')
        end,
        existing = existing, captured = function() return captured end,
        verifyRestored = function()
            assert.are.equal(other, active)
            assert.same({ other, original }, selected)
            assert.are.equal('library', module)
            assert.same({ 'original source' }, sources)
            assert.are.equal(original, registry.original)
            assert.are.equal('file', existing['/original.ARW'])
        end,
    }
end

describe('LightroomRender', function()
    it('does not create a collection unless a render is requested', function()
        local f = fixture()
        assert.is_true(f.finish())
        assert.same({}, f.calls)
    end)

    it('queues copies across renders and removes them together at run end', function()
        local f = fixture()
        assert.are.equal(f.file, f.render())
        assert.same({ 'collection', 'create', 'reset', 'export' }, f.calls)
        assert.is_not_nil(f.registry.copy1)
        f.verifyRestored()
        assert.is_true(f.cleanup())
        assert.is_not_nil(f.registry.copy1)
        assert.are.equal(f.file, f.render())
        assert.is_not_nil(f.registry.copy2)
        local settings = f.captured().exportSettings
        assert.are.equal('JPEG', settings.LR_format)
        assert.are.equal(1, settings.LR_jpeg_quality)
        assert.is_false(settings.LR_size_doConstrain)
        assert.is_true(f.finish())
        assert.same({ 'collection', 'create', 'reset', 'export',
            'create', 'reset', 'export', 'remove', 'delete collection' }, f.calls)
        assert.is_nil(f.registry.copy1)
        assert.is_nil(f.registry.copy2)
        assert.is_nil(f.collection())
        assert.is_nil(f.existing[f.file])
        f.verifyRestored()
        assert.is_true(f.finish())
    end)

    it('keeps a valid rendition when Lightroom restores the set but changes the active photo', function()
        local f = fixture('restore_active')
        assert.are.equal(f.file, f.render())
        assert.is_true(f.finish())
        assert.is_nil(f.registry.copy1)
        assert.is_nil(f.collection())
        assert.same({}, f.messages)
    end)

    it('keeps a valid rendition and cleans up even if selection restoration fails', function()
        local f = fixture('restore_members')
        assert.are.equal(f.file, f.render())
        assert.is_true(f.finish())
        assert.is_nil(f.registry.copy1)
        assert.is_nil(f.collection())
        assert.same({ 'Photo selection changed' }, f.messages)
        assert.is_not_nil(f.registry.original)
    end)

    it('queues a copy even after reset or export failure', function()
        for _, stage in ipairs({ 'reset', 'export' }) do
            local f = fixture(stage)
            assert.is_nil(f.render())
            assert.is_not_nil(f.registry.copy1)
            assert.is_nil(f.existing[f.file])
            assert.is_true(f.finish())
            assert.is_nil(f.registry.copy1)
            assert.is_nil(f.collection())
            f.verifyRestored()
        end
    end)

    it('refuses to reset or remove a master returned as a copy', function()
        local f = fixture('wrong_copy')
        assert.has_error(f.render, 'Temporary virtual copy tracking or selection restoration failed')
        assert.same({ 'collection', 'create' }, f.calls)
        assert.is_false(f.finish())
        f.verifyRestored()
    end)

    it('retains the collection when virtual-copy removal fails', function()
        local f = fixture('remove')
        assert.are.equal(f.file, f.render())
        assert.is_false(f.finish())
        assert.is_not_nil(f.registry.copy1)
        assert.is_not_nil(f.collection())
        assert.is_nil(f.existing[f.file])
        f.verifyRestored()
    end)

    it('reuses an existing collection and cleans up copies from a prior interrupted run', function()
        local f = fixture()
        f.seedPreviousRun()
        assert.are.equal(f.file, f.render())
        assert.is_not_nil(f.registry.previous)
        assert.is_true(f.finish())
        assert.is_nil(f.registry.previous)
        assert.is_nil(f.registry.copy1)
        assert.is_nil(f.collection())
        assert.same({ 'collection', 'create', 'reset', 'export',
            'remove', 'delete collection' }, f.calls)
        f.verifyRestored()
    end)

    it('preserves unexpected virtual copies when the user declines removal', function()
        local f = fixture()
        assert.are.equal(f.file, f.render())
        f.addForeignCopy()
        assert.is_true(f.finish())
        assert.are.equal(1, #f.prompts)
        assert.is_truthy(f.prompts[1][2]:find('My edit', 1, true))
        assert.are.equal('Keep Copy', f.prompts[1][3])
        assert.are.equal('Remove Virtual Copy', f.prompts[1][5])
        assert.is_not_nil(f.registry.foreign)
        assert.is_nil(f.registry.copy1)
        assert.is_nil(f.collection())
        f.verifyRestored()
    end)

    it('removes unexpected virtual copies only after explicit approval', function()
        local f = fixture(nil, 'other')
        assert.are.equal(f.file, f.render())
        f.addForeignCopy()
        assert.is_true(f.finish())
        assert.are.equal(1, #f.prompts)
        assert.is_nil(f.registry.foreign)
        assert.is_nil(f.registry.copy1)
        assert.is_nil(f.collection())
        f.verifyRestored()
    end)

    it('clears real photos from the collection without removing them from the catalog', function()
        local f = fixture()
        assert.are.equal(f.file, f.render())
        f.addMaster()
        assert.is_true(f.finish())
        assert.are.equal(0, #f.prompts)
        assert.is_nil(f.registry.copy1)
        assert.is_nil(f.collection())
        assert.same({ 'collection', 'create', 'reset', 'export',
            'remove', 'delete collection' }, f.calls)
        f.verifyRestored()
    end)
end)
