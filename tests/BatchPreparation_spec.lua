local function loadPreparation()
    local oldImport = _G.import
    local imports = {
        LrFileUtils = {
            exists = function() return 'file' end,
            fileAttributes = function()
                return { fileSize = 80000000, fileModificationDate = 100 }
            end,
        },
        LrPathUtils = {
            parent = function() return '/private/folder' end,
        },
        LrTasks = { pcall = pcall },
        LrUUID = {},
        LrLocalization = { currentLanguage = function() return 'en-US' end },
    }
    _G.import = function(name) return assert(imports[name], name) end
    local ok, result = pcall(assert(loadfile('crush-catalog.lrplugin/BatchPreparation.lua')))
    _G.import = oldImport
    assert(ok, tostring(result))
    return result
end

local function photo(id, capturedAt)
    local raw = {
        uuid = id, path = '/private/folder/' .. id .. '.ARW',
        isVirtualCopy = false, isCropped = false, isVideo = false,
        dateTimeOriginalISO8601 = capturedAt,
        gps = { latitude = 29, longitude = -95 },
        editCount = 1, lastEditTime = 100,
    }
    local formatted = {
        cameraMake = 'Sony', cameraModel = 'ILCE-7RM6', cameraSerialNumber = '123456',
    }
    return {
        getRawMetadata = function(_, key) return raw[key] end,
        getFormattedMetadata = function(_, key) return formatted[key] end,
    }, raw, formatted
end

describe('BatchPreparation', function()
    it('maps documented Lightroom metadata into an opaque original-file manifest', function()
        local preparation = loadPreparation()
        local a = photo('a', '2026-11-23T12:34:56.123')
        local b = photo('b', '2026-11-23T12:34:56.456')
        local plans, excluded = preparation.prepare({ a, b })
        assert.are.equal(0, #excluded)
        local plan = plans[1]
        local frames = plan.manifest.frames
        assert.are.equal('burst', plan.manifest.execution_mode)
        assert.are.equal('a', frames[1].source_id)
        assert.are.equal('camera-1', frames[1].camera_id)
        assert.are.equal(frames[1].camera_id, frames[2].camera_id)
        assert.are.equal(frames[1].session_id, frames[2].session_id)
        assert.are.equal(a, plan.items.a.item.photo)
        assert.are.equal('/private/folder/a.ARW', plan.resolveAsset('a', 'full', 'full'))
        assert.is_true(plan.close())
    end)

    it('detects changed metadata and keeps missing GPS unknown', function()
        local preparation = loadPreparation()
        local a, raw = photo('a', '2026-11-23T12:34:56.123')
        raw.gps = nil
        local plans = preparation.prepare({ a })
        local plan = plans[1]
        assert.are.equal('independent', plan.manifest.execution_mode)
        assert.is_false(plan.manifest.frames[1].gps_absent)
        raw.editCount = 2
        assert.is_nil(plan.resolveAsset('a', 'full', 'full'))
        assert.is_true(plan.close())
    end)

    it('preserves explicit exclusions and stops before preparing canceled selections', function()
        local preparation = loadPreparation()
        local a, raw = photo('a', '2026-11-23T12:34:56')
        raw.isVirtualCopy = true
        raw.masterPhoto = photo('master', '2026-11-23T12:34:56')
        local plans, excluded = preparation.prepare({ a })
        assert.are.equal(0, #plans)
        assert.are.equal('develop_view_unverified', excluded[1].reason)
        assert.are.equal('master', excluded[1].item.sourceId)
        assert.has_error(function()
            preparation.prepare({ a }, { isCanceled = function() return true end })
        end, 'Batch canceled')
    end)

    it('closes the plan on success, error and cancellation', function()
        local preparation = loadPreparation()
        local count = 0
        local plan = {
            manifest = {},
            resolveAsset = function() end,
            close = function() count = count + 1; return true end,
        }
        local result = preparation.run(plan, function(manifest, options)
            assert.are.equal(plan.manifest, manifest)
            assert.are.equal(plan.resolveAsset, options.resolveAsset)
            return { results = {} }
        end)
        assert.same({ results = {} }, result)
        assert.has_error(function()
            preparation.run(plan, function() error('Batch canceled', 0) end)
        end, 'Batch canceled')
        assert.has_error(function()
            preparation.run(plan, function() error('Transport failed', 0) end)
        end, 'Transport failed')
        assert.are.equal(3, count)
    end)
end)
