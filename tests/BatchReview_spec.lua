local Review = assert(loadfile('crush-catalog.lrplugin/Core/BatchReview.lua'))()

local function object(track, provenance, anchor, confidence, id)
    return {
        track_id = track, identification_provenance = provenance,
        evidence_frame_ids = { anchor }, conflict_evidence_frame_ids = {},
        review_required = false, geometry_provenance = 'detected', geometry_clipped = false,
        bounding_box = { 10, 10, 30, 30 },
        predictions = { {
            canonical_namespace = 'inaturalist', canonical_taxon_id = id or 42,
            confidence = confidence or 0.95,
            taxonomy = { 'Animalia', 'Corvus', 'corax' },
            taxonomy_rank_names = { 'kingdom', 'genus', 'species' },
            common_names = { 'Animals', 'Ravens', 'Common Raven' },
        } },
    }
end

local function frame(id, objects, status)
    return {
        frame_id = id, objects = objects, status = status or 'identified',
        width = 100, height = 100, coordinate_space = 'original:embedded_preview',
    }
end

local function sample()
    return {
        frames = { { frame_id = 'a' }, { frame_id = 'b' }, { frame_id = 'c' } },
    }, {
        frame('a', { object('track-1', 'direct', 'a') }),
        frame('b', { object('track-1', 'propagated', 'a') }),
        frame('c', { object('track-1', 'direct', 'c') }),
    }
end

local function confirm()
    return { action = 'ok', selectedPredictionIndex = 1 }
end

describe('BatchReview', function()
    it('confirms a verified track once, retaining the per-frame dispositions', function()
        local manifest, results = sample()
        local calls = 0
        local decision = Review.collect(manifest, results, {
            mode = 'manual',
            review = function(unit)
                calls = calls + 1
                assert.are.equal('track', unit.kind)
                assert.are.equal(3, #unit.members)
                assert.are.equal(2, #unit.evidence)
                assert.are.equal('a', unit.evidence[1].frame.frame_id)
                assert.are.equal('c', unit.evidence[2].frame.frame_id)
                return confirm()
            end,
        })
        assert.are.equal(1, calls)
        assert.are.equal(3, #decision.approved)
        assert.same({}, decision.skipped)
        for index, approval in ipairs(decision.approved) do
            assert.are.equal(results[index].frame_id, approval.frame_id)
            assert.are.equal('confirmed', approval.dispositions[1].disposition)
            assert.are.equal('Common Raven',
                approval.dispositions[1].selectedPrediction.commonNameTaxonomy[3])
        end
    end)

    it('automatically accepts only a complete qualifying track', function()
        local manifest, results = sample()
        local decision = Review.collect(manifest, results, { mode = 'automatic', threshold = 90 })
        assert.are.equal(3, #decision.approved)
        results[3].objects[1].predictions[1].confidence = 0.89
        decision = Review.collect(manifest, results, { mode = 'automatic', threshold = 90 })
        assert.same({}, decision.approved)
        assert.same({ 'a', 'b', 'c' }, decision.skipped)
    end)

    it('sends a below-threshold track to assisted review', function()
        local manifest, results = sample()
        local calls = 0
        results[3].objects[1].predictions[1].confidence = 0.89
        local decision = Review.collect(manifest, results, {
            mode = 'assisted', threshold = 90,
            review = function(unit)
                calls = calls + 1
                assert.are.equal('track', unit.kind)
                return confirm()
            end,
        })
        assert.are.equal(1, calls)
        assert.are.equal(3, #decision.approved)
    end)

    it('does not propagate approval across conflicting or uncertain results', function()
        local manifest, results = sample()
        results[3].objects[1].review_required = true
        results[3].objects[1].conflict_evidence_frame_ids = { 'a', 'c' }
        results[3].status = 'uncertain'
        local calls = 0
        local decision = Review.collect(manifest, results, {
            mode = 'assisted', threshold = 90,
            review = function(unit)
                calls = calls + 1
                assert.are.equal('object', unit.kind)
                return { action = 'unsure' }
            end,
        })
        assert.are.equal(3, calls)
        assert.same({}, decision.approved)
    end)

    it('rejects orphaned evidence, differing taxa and duplicate detections in one frame', function()
        local manifest, results = sample()
        results[2].objects[1].evidence_frame_ids = { 'missing' }
        local units = Review.units(manifest, results)
        assert.are.equal(3, #units)
        assert.is_true(units[2].automaticBlocked)
        manifest, results = sample()
        results[3].objects[1].predictions[1].canonical_taxon_id = 43
        units = Review.units(manifest, results)
        assert.are.equal(3, #units)
        manifest, results = sample()
        results[2].objects[2] = object('track-1', 'propagated', 'a')
        units = Review.units(manifest, results)
        assert.are.equal(4, #units)
    end)

    it('does not group across missing frames or changed coordinate spaces', function()
        local manifest, results = sample()
        results[2] = frame('b', {}, 'no_detection')
        local units = Review.units(manifest, results)
        assert.are.equal(2, #units)
        assert.are.equal('object', units[1].kind)
        manifest, results = sample()
        results[2].coordinate_space = 'original:full_quality'
        units = Review.units(manifest, results)
        assert.are.equal(3, #units)
    end)

    it('allows track exceptions to be reviewed individually without copying a different taxon', function()
        local manifest, results = sample()
        local calls = 0
        local decision = Review.collect(manifest, results, {
            mode = 'manual',
            review = function(unit)
                calls = calls + 1
                if unit.kind == 'track' then return { action = 'individual' } end
                if unit.members[1].frame.frame_id == 'b' then return { action = 'unsure' } end
                return confirm()
            end,
        })
        assert.are.equal(4, calls)
        assert.same({ 'b' }, decision.skipped)
        assert.are.equal('a', decision.approved[1].frame_id)
        assert.are.equal('c', decision.approved[2].frame_id)
    end)

    it('does not write a frame with unresolved objects, failures or no detections', function()
        local manifest, results = sample()
        results[1].objects[2] = object('track-2', 'direct', 'a', 0.3)
        results[2] = frame('b', {}, 'failed')
        results[3] = frame('c', {}, 'no_detection')
        local decision = Review.collect(manifest, results, {
            mode = 'manual',
            review = function(unit)
                if unit.members[1].object.track_id == 'track-2' then
                    return { action = 'unsure' }
                end
                return confirm()
            end,
        })
        assert.same({}, decision.approved)
        assert.same({ 'a', 'b', 'c' }, decision.skipped)
    end)

    it('invalidates a track if a source changes during review', function()
        local manifest, results = sample()
        local changed = false
        local decision = Review.collect(manifest, results, {
            mode = 'manual',
            isCurrent = function(id) return not changed or id ~= 'b' end,
            review = function()
                changed = true
                return confirm()
            end,
        })
        assert.same({}, decision.approved)
    end)

    it('discards all staged decisions on cancellation', function()
        local manifest, results = sample()
        local decision, reason = Review.collect(manifest, results, {
            mode = 'manual', review = function() return { action = 'stop' } end,
        })
        assert.is_nil(decision)
        assert.are.equal('canceled', reason)
    end)

    it('rejects incomplete or out-of-order final results', function()
        local manifest, results = sample()
        assert.has_error(function() Review.units(manifest, { results[1] }) end)
        assert.has_error(function()
            Review.units(manifest, { results[2], results[1], results[3] })
        end)
    end)

    it('does not auto-accept unresolved canonical identity or clipped geometry', function()
        local manifest, results = sample()
        results[1].objects[1].predictions[1].canonical_taxon_id = nil
        results[2].objects[1].geometry_clipped = true
        local decision = Review.collect(manifest, results, { mode = 'automatic', threshold = 0 })
        assert.same({}, decision.approved)
    end)
end)
