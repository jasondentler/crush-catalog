local Manifest = assert(loadfile('crush-catalog.lrplugin/Core/BatchManifest.lua'))()

local function item(index, overrides)
    local value = {
        photoId = 'photo-' .. index, sourceId = 'source-' .. index,
        path = '/private/original-' .. index .. '.ARW', byteCount = 80000000,
        modifiedAt = 100, editCount = 2, lastEditTime = 90,
        isVirtualCopy = false, isCropped = false,
        capturedAt = '2026-11-23T12:34:56.123-06:00',
        cameraKey = 'private-camera', sessionKey = 'private-folder',
        gps = { latitude = 29, longitude = -95 },
    }
    for key, entry in pairs(overrides or {}) do value[key] = entry end
    return value
end

local function callbacks()
    local state = { made = {}, removed = {}, current = true }
    local options = {
        language = 'en-US',
        isCurrent = function() return state.current end,
        makePreview = function(path)
            state.made[#state.made + 1] = path
            if not state.unavailable then return '/temp/preview-' .. #state.made end
        end,
        removePreview = function(path)
            state.removed[#state.removed + 1] = path
            return not state.removeFailed
        end,
    }
    return options, state
end

describe('BatchManifest', function()
    it('describes original assets without exposing local paths or camera serials', function()
        local options, state = callbacks()
        local first, second = item(1), item(2)
        local plans, excluded = Manifest.prepare({ first, second }, options)
        assert.are.equal(0, #excluded)
        assert.are.equal(1, #plans)
        local plan = plans[1]
        assert.same({
            schema_version = 1, execution_mode = 'burst',
            frames = {
                {
                    frame_id = 'photo-1', source_id = 'source-1',
                    captured_at = first.capturedAt, fractional_digits = 3,
                    camera_id = 'camera-1', session_id = 'sequence-1',
                    gps = first.gps, gps_absent = false, common_name_language = 'en-US',
                    representations = {
                        { representation_id = 'full', role = 'full',
                            filename = 'original-1.ARW', byte_count = 80000000 },
                        { representation_id = 'preview', role = 'preview',
                            filename = 'preview.jpg' },
                    },
                },
                {
                    frame_id = 'photo-2', source_id = 'source-2',
                    captured_at = second.capturedAt, fractional_digits = 3,
                    camera_id = 'camera-1', session_id = 'sequence-1',
                    gps = second.gps, gps_absent = false, common_name_language = 'en-US',
                    representations = {
                        { representation_id = 'full', role = 'full',
                            filename = 'original-2.ARW', byte_count = 80000000 },
                        { representation_id = 'preview', role = 'preview',
                            filename = 'preview.jpg' },
                    },
                },
            },
        }, plan.manifest)
        assert.are.equal(first, plan.items['photo-1'].item)
        assert.same({}, state.made)
    end)

    it('uses independent full assets for imprecise, missing or invalid sequence evidence', function()
        local a, b, c, d = item(1), item(2), item(3), item(4)
        a.capturedAt = '2026-11-23T12:34:56'
        b.sessionKey = nil
        c.gps = nil
        d.capturedAt = '2026-02-30T12:34:56.123Z'
        local options = callbacks()
        local plans = Manifest.prepare({ a, b, c, d }, options)
        local manifest = plans[1].manifest
        assert.are.equal('independent', manifest.execution_mode)
        for _, frame in ipairs(manifest.frames) do
            assert.are.equal(1, #frame.representations)
        end
        assert.are.equal(0, manifest.frames[1].fractional_digits)
        assert.is_false(manifest.frames[3].gps_absent)
        assert.is_nil(manifest.frames[4].captured_at)
        assert.same({ 'Subsecond time unavailable' }, plans[1].items['photo-1'].previewBlockers)
        assert.same({ 'Sequence identity unavailable' }, plans[1].items['photo-2'].previewBlockers)
        assert.same({ 'GPS context unknown' }, plans[1].items['photo-3'].previewBlockers)
    end)

    it('resumes only matching archived originals and preserves sequence breaks', function()
        local options = callbacks()
        local a, b, c = item(1), item(2), item(3)
        local prior = Manifest.prepare({ a, b, c }, options)
        options.resumeFrames = {
            [b.photoId] = { frame = prior[1].manifest.frames[2], batch_id = 'old-batch' },
            [c.photoId] = { frame = prior[1].manifest.frames[3], batch_id = 'old-batch' },
        }
        c.byteCount = c.byteCount + 1
        local plans, excluded, resumed = Manifest.prepare({ a, b, c }, options)
        assert.are.equal(2, #plans)
        assert.are.equal(0, #excluded)
        assert.same({ { frame_id = b.photoId, batch_id = 'old-batch' } }, resumed)
        assert.are.equal(a.photoId, plans[1].manifest.frames[1].frame_id)
        assert.are.equal(c.photoId, plans[2].manifest.frames[1].frame_id)
    end)

    it('supports verified GPS absence without assuming it from missing metadata', function()
        local a = item(1)
        a.gps = nil
        a.gpsAbsent = true
        local options = callbacks()
        local plans = Manifest.prepare({ a }, options)
        assert.is_true(plans[1].manifest.frames[1].gps_absent)
        assert.are.equal('burst', plans[1].manifest.execution_mode)
    end)

    it('does not offer previews for other formats or disabled burst mode', function()
        local a = item(1, { path = 'C:\\photos\\bird.CR3' })
        local options = callbacks()
        local plans = Manifest.prepare({ a }, options)
        assert.are.equal('independent', plans[1].manifest.execution_mode)
        assert.are.equal('bird.CR3', plans[1].manifest.frames[1].representations[1].filename)
        options.enableBurst = false
        plans = Manifest.prepare({ item(2) }, options)
        assert.are.equal('independent', plans[1].manifest.execution_mode)
    end)

    it('excludes crops, virtual copies, missing sources, duplicate selections and videos', function()
        local a = item(1)
        local missing = item(4)
        missing.byteCount = nil
        local options = callbacks()
        local plans, excluded = Manifest.prepare({
            a, item(2, { isCropped = true }), item(3, { isVirtualCopy = true }),
            missing, item(5, { isVideo = true }), a, item(6, { path = a.path }), item(7),
        }, options)
        assert.are.equal(2, #plans)
        assert.are.equal(6, #excluded)
        assert.are.equal('develop_view_unverified', excluded[1].reason)
        assert.are.equal('develop_view_unverified', excluded[2].reason)
        assert.are.equal('original_unavailable', excluded[3].reason)
        assert.are.equal('unsupported_video', excluded[4].reason)
        assert.are.equal('duplicate_photo', excluded[5].reason)
        assert.are.equal('repeated_source_path', excluded[6].reason)
        assert.are.equal('photo-7', plans[2].manifest.frames[1].frame_id)
    end)

    it('partitions large selections in order at 256 frames', function()
        local items = {}
        for i = 1, 513 do items[i] = item(i) end
        local options = callbacks()
        local plans, excluded = Manifest.prepare(items, options)
        assert.are.equal(0, #excluded)
        assert.are.equal(3, #plans)
        assert.are.equal(256, #plans[1].manifest.frames)
        assert.are.equal(256, #plans[2].manifest.frames)
        assert.are.equal('photo-257', plans[2].manifest.frames[1].frame_id)
        assert.are.equal('photo-513', plans[3].manifest.frames[1].frame_id)
    end)

    it('resolves only requested declared assets, with lazy preview cleanup', function()
        local options, state = callbacks()
        local plans = Manifest.prepare({ item(1), item(2) }, options)
        local plan = plans[1]
        assert.is_nil(plan.resolveAsset('unknown', 'full', 'full'))
        assert.is_nil(plan.resolveAsset('photo-1', 'full', 'preview'))
        assert.are.equal('/temp/preview-1', plan.resolveAsset('photo-1', 'preview', 'preview'))
        assert.same({}, state.removed)
        assert.are.equal('/private/original-1.ARW', plan.resolveAsset('photo-1', 'full', 'full'))
        assert.same({ '/temp/preview-1' }, state.removed)
        assert.are.equal('/temp/preview-2', plan.resolveAsset('photo-2', 'preview', 'preview'))
        assert.is_true(plan.close())
        assert.same({ '/temp/preview-1', '/temp/preview-2' }, state.removed)
        assert.is_nil(plan.resolveAsset('photo-2', 'full', 'full'))
        assert.is_true(plan.close())
    end)

    it('falls back when native preview extraction declines and refuses changed originals', function()
        local options, state = callbacks()
        local plans = Manifest.prepare({ item(1) }, options)
        local plan = plans[1]
        state.unavailable = true
        assert.is_nil(plan.resolveAsset('photo-1', 'preview', 'preview'))
        assert.are.equal('/private/original-1.ARW', plan.resolveAsset('photo-1', 'full', 'full'))
        state.current = false
        assert.is_nil(plan.resolveAsset('photo-1', 'full', 'full'))
    end)

    it('reports cleanup failure and permits a cleanup retry', function()
        local options, state = callbacks()
        local plans = Manifest.prepare({ item(1) }, options)
        local plan = plans[1]
        plan.resolveAsset('photo-1', 'preview', 'preview')
        state.removeFailed = true
        assert.is_false(plan.close())
        state.removeFailed = false
        assert.is_true(plan.close())
    end)

    it('checks the local source and catalog snapshot rather than inventing develop IDs', function()
        assert.is_true(Manifest.sameSnapshot(item(1), item(1)))
        assert.is_false(Manifest.sameSnapshot(item(1), item(1, { editCount = 3 })))
        assert.is_false(Manifest.sameSnapshot(item(1), item(1, { modifiedAt = 101 })))
        assert.is_false(Manifest.sameSnapshot(item(1), item(1, { lastEditTime = 91 })))
        assert.is_false(Manifest.sameSnapshot(item(1), item(1, { path = '/other.ARW' })))
        assert.is_false(Manifest.sameSnapshot(item(1), item(1, {
            gps = { latitude = 30, longitude = -95 },
        })))
    end)
end)
