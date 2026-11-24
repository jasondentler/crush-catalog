local function loadDialog(show)
    local previousImport = _G.import
    local previousDialog = package.loaded.IdentificationDialog
    _G.import = function() return {} end
    package.loaded.IdentificationDialog = { showBatchObject = show }
    local ok, result = pcall(assert(loadfile('crush-catalog.lrplugin/BatchReviewDialog.lua')))
    _G.import = previousImport
    package.loaded.IdentificationDialog = previousDialog
    assert(ok, tostring(result))
    return result
end

local function sample()
    local object = {
        bounding_box = { 1, 2, 3, 4 },
        identification_provenance = 'direct',
        review_required = true, reason = 'conflicting_evidence',
        conflict_evidence_frame_ids = { 'a', 'b' },
    }
    local member = {
        frame = { frame_id = 'a', coordinate_space = 'original:embedded_preview',
            objects = { object } },
        object = object, objectIndex = 1, frameIndex = 1,
    }
    local crop = {
        frame_id = 'a', object_index = 1, coordinate_space = 'original:embedded_preview',
        bounding_box = { 1, 2, 3, 4 },
        bytes = string.char(255, 216, 255, 217),
    }
    return member, crop
end

describe('BatchReviewDialog', function()
    it('checks crop identity, coordinate space and geometry before showing evidence', function()
        local dialog = loadDialog(function() end)
        local member, crop = sample()
        assert.is_true(dialog.matchingCrop(member, crop))
        crop.frame_id = 'b'
        assert.is_false(dialog.matchingCrop(member, crop))
        crop.frame_id = 'a'
        crop.object_index = 2
        assert.is_false(dialog.matchingCrop(member, crop))
        crop.object_index = 1
        crop.coordinate_space = 'original:full_quality'
        assert.is_false(dialog.matchingCrop(member, crop))
        crop.coordinate_space = member.frame.coordinate_space
        crop.bounding_box[1] = 0
        assert.is_false(dialog.matchingCrop(member, crop))
        crop.bounding_box[1] = 1
        crop.bytes = 'not an image'
        assert.is_false(dialog.matchingCrop(member, crop))
    end)

    it('declines review without matching evidence', function()
        local dialog = loadDialog(function() error('Must not display invalid evidence') end)
        local member = sample()
        local unit = { kind = 'object', members = { member }, evidence = { member } }
        assert.same({ action = 'unsure' }, dialog.review(unit, {}))
        unit.kind = 'track'
        assert.same({ action = 'individual' }, dialog.review(unit, {}))
    end)

    it('passes verified object evidence and uncertainty to the existing confirmation dialog', function()
        local member, crop = sample()
        local photo = {}
        local calls = 0
        local dialog = loadDialog(function(p, m, image, options)
            calls = calls + 1
            assert.are.equal(photo, p)
            assert.are.equal(member, m)
            assert.are.equal(crop.bytes, image.bytes)
            assert.are.equal(3, options.imageCount)
            assert.are.equal('en-US', options.commonNameLanguage)
            assert.is_truthy(options.batchReviewSummary:find('Conflicting direct evidence'))
            return { action = 'ok', selectedPredictionIndex = 1 }
        end)
        local result = dialog.review({ kind = 'object', members = { member },
            evidence = { member } }, {
            items = { a = { item = { photo = photo } } },
            getCrop = function(m)
                assert.are.equal(member, m)
                return crop
            end,
            imageCount = 3, language = 'en-US',
        })
        assert.are.equal(1, calls)
        assert.same({ action = 'ok', selectedPredictionIndex = 1 }, result)
    end)
end)
