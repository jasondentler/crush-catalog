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

    it('archives negative-only dispositions even when no frame is approved', function()
        local manifest, results = sample()
        local events = {}
        local decisions = Review.collect(manifest, results, {
            mode = 'manual',
            review = function() return { action = 'not_an_animal' } end,
            onDisposition = function(event) events[#events + 1] = event end,
        })
        assert.same({}, decisions.approved)
        assert.are.equal(3, #events)
        for index, event in ipairs(events) do
            assert.are.equal(results[index].frame_id, event.frame_id)
            assert.are.equal(1, event.object_index)
            assert.are.equal('not_an_animal', event.disposition.disposition)
        end
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
    it('identifies an uncertain geometry-verified snail track once by manual taxonomy', function()
        local manifest, results = sample()
        local calls = 0
        local prediction = {
            taxonomy = { 'Animalia', 'Pomacea', 'maculata' },
            taxonomyRanks = { 'kingdom', 'genus', 'species' },
            commonNameTaxonomy = { 'Animals', 'Apple Snails', 'Island Apple Snail' },
        }
        for index, result in ipairs(results) do
            local obj = result.objects[1]
            obj.review_track_id = 'review-1'
            obj.track_id = 'independent-' .. index
            obj.identification_provenance = 'direct'
            obj.evidence_frame_ids = { result.frame_id }
            obj.review_required = true
            obj.predictions[1].canonical_taxon_id = nil
            result.status = 'uncertain'
        end
        local decision = Review.collect(manifest, results, {
            mode = 'assisted', threshold = 90,
            review = function(unit)
                calls = calls + 1
                assert.are.equal('track', unit.kind)
                assert.is_true(unit.automaticBlocked)
                assert.are.equal(3, #unit.evidence)
                return { action = 'manual', selectedPrediction = prediction }
            end,
        })
        assert.are.equal(1, calls)
        assert.are.equal(3, #decision.approved)
        for _, approval in ipairs(decision.approved) do
            assert.same(prediction, approval.dispositions[1].selectedPrediction)
            assert.are.equal('manual', approval.dispositions[1].disposition)
        end
        decision = Review.collect(manifest, results, { mode = 'automatic', threshold = 0 })
        assert.same({}, decision.approved)
    end)

    it('rejects one verified background track without rejecting the other subject', function()
        local manifest, results = sample()
        for index, result in ipairs(results) do
            local patch = object('patch-' .. index, 'direct', result.frame_id, 0.95, 50 + index)
            patch.review_track_id = 'background'
            patch.review_required = true
            result.objects[2] = patch
        end
        local calls = 0
        local decision = Review.collect(manifest, results, {
            mode = 'manual',
            review = function(unit)
                calls = calls + 1
                if unit.members[1].object.review_track_id == 'background' then
                    assert.are.equal(3, #unit.evidence)
                    return { action = 'not_an_animal' }
                end
                return confirm()
            end,
        })
        assert.are.equal(2, calls)
        assert.are.equal(3, #decision.approved)
        for _, approval in ipairs(decision.approved) do
            assert.are.equal('confirmed', approval.dispositions[1].disposition)
            assert.are.equal('not_an_animal', approval.dispositions[2].disposition)
        end
    end)

    it('requires an explicit species decision when review-track predictions disagree', function()
        local manifest, results = sample()
        for _, result in ipairs(results) do
            result.objects[1].review_track_id = 'review-1'
            result.objects[1].review_required = true
        end
        results[3].objects[1].predictions[1].canonical_taxon_id = 43
        results[3].objects[1].conflict_evidence_frame_ids = { 'a', 'c' }
        local calls = 0
        local decision = Review.collect(manifest, results, {
            mode = 'manual',
            review = function(unit)
                calls = calls + 1
                assert.are.equal('track', unit.kind)
                assert.is_true(unit.automaticBlocked)
                return confirm()
            end,
        })
        assert.are.equal(1, calls)
        assert.same({}, decision.approved)
    end)

    it('rejects related weak regions with duplicate boxes and a missing frame once', function()
        local manifest, results = sample()
        for _, result in ipairs(results) do
            local first = result.objects[1]
            first.identification_provenance = 'direct'
            first.evidence_frame_ids = { result.frame_id }
            first.track_id = 'subject-' .. result.frame_id
            first.review_group_id = 'real-subject'
        end
        for _, index in ipairs({ 1, 3 }) do
            local result = results[index]
            for objectIndex = 2, 3 do
                local patch = object('patch-' .. result.frame_id .. objectIndex,
                    'direct', result.frame_id, 0.4, 50 + objectIndex)
                patch.review_group_id = 'weak-region'
                patch.review_required = true
                result.objects[objectIndex] = patch
            end
        end
        local calls = 0
        local decisions = Review.collect(manifest, results, {
            mode = 'manual',
            review = function(unit)
                calls = calls + 1
                if unit.members[1].object.review_group_id == 'weak-region' then
                    assert.is_true(unit.candidateRegions)
                    assert.is_true(unit.automaticBlocked)
                    assert.are.equal(2, unit.frameCount)
                    assert.are.equal(4, #unit.evidence)
                    return { action = 'not_an_animal' }
                end
                assert.are.equal(3, unit.frameCount)
                return confirm()
            end,
        })
        assert.are.equal(2, calls)
        assert.are.equal(3, #decisions.approved)
        for _, index in ipairs({ 1, 3 }) do
            assert.are.equal('not_an_animal', decisions.approved[index].dispositions[2].disposition)
            assert.are.equal('not_an_animal', decisions.approved[index].dispositions[3].disposition)
        end
    end)

    it('allows one explicit species choice for duplicate snail detections', function()
        local manifest, results = sample()
        for _, result in ipairs(results) do
            local primary = result.objects[1]
            primary.track_id = 'primary-' .. result.frame_id
            primary.identification_provenance = 'direct'
            primary.evidence_frame_ids = { result.frame_id }
            primary.review_group_id = 'snail'
            primary.review_required = true
        end
        local duplicate = object('duplicate', 'direct', 'b', 0.3, 43)
        duplicate.review_group_id = 'snail'
        duplicate.review_required = true
        results[2].objects[2] = duplicate
        local prediction = {
            taxonomy = { 'Animalia', 'Pomacea', 'maculata' },
            taxonomyRanks = { 'kingdom', 'genus', 'species' },
        }
        local calls = 0
        local decisions = Review.collect(manifest, results, {
            mode = 'assisted', threshold = 90,
            review = function(unit)
                calls = calls + 1
                assert.is_true(unit.automaticBlocked)
                assert.are.equal(4, #unit.evidence)
                return { action = 'manual', selectedPrediction = prediction }
            end,
        })
        assert.are.equal(1, calls)
        assert.are.equal(3, #decisions.approved)
        assert.same(prediction, decisions.approved[2].dispositions[2].selectedPrediction)
        decisions = Review.collect(manifest, results, { mode = 'automatic', threshold = 90 })
        assert.same({}, decisions.approved)
    end)

    it('allows explicit manual identification of a consecutive clipped region only', function()
        local manifest, results = sample()
        local prediction = { taxonomy = { 'Plantae', 'Phragmites', 'australis' },
            taxonomyRanks = { 'kingdom', 'genus', 'species' } }
        for _, result in ipairs(results) do
            local obj = result.objects[1]
            obj.review_group_id = 'clipped-reed'
            obj.track_id = 'independent-' .. result.frame_id
            obj.geometry_clipped = true
            obj.identification_provenance = 'direct'
            obj.evidence_frame_ids = { result.frame_id }
            obj.review_required = true
            result.status = 'uncertain'
        end
        local decisions = Review.collect(manifest, results, {
            mode = 'assisted', threshold = 90,
            review = function(unit)
                assert.is_true(unit.automaticBlocked)
                assert.are.equal(3, #unit.evidence)
                return { action = 'manual', selectedPrediction = prediction }
            end,
        })
        assert.are.equal(1, decisions.reviewPrompts)
        assert.are.equal(3, #decisions.approved)
        for _, approval in ipairs(decisions.approved) do
            assert.same(prediction, approval.dispositions[1].selectedPrediction)
        end
        decisions = Review.collect(manifest, results, { mode = 'automatic', threshold = 0 })
        assert.same({}, decisions.approved)
        results[3].coordinate_space = 'original:full_quality'
        local units = Review.units(manifest, results, true)
        assert.are.equal(3, #units)
        assert.is_true(units[1].automaticBlocked)
    end)

    it('reviews weak edge regions across short gaps without approving missing detections', function()
        local manifest, results = sample()
        local prediction = { taxonomy = { 'Plantae', 'Phragmites', 'australis' },
            taxonomyRanks = { 'kingdom', 'genus', 'species' } }
        for _, index in ipairs({ 1, 3 }) do
            local result = results[index]
            local obj = result.objects[1]
            obj.review_group_id = 'edge-region-1'
            obj.track_id = 'independent-' .. result.frame_id
            obj.geometry_clipped = index == 1
            obj.bounding_box = { 10, 0, 30, 70 }
            obj.identification_provenance = 'direct'
            obj.evidence_frame_ids = { result.frame_id }
            obj.review_required = true
            result.status = 'uncertain'
        end
        results[2] = frame('b', {}, 'no_detection')
        local decisions = Review.collect(manifest, results, {
            mode = 'assisted', threshold = 90,
            review = function(unit)
                assert.is_true(unit.automaticBlocked)
                assert.are.equal(2, #unit.evidence)
                return { action = 'manual', selectedPrediction = prediction }
            end,
        })
        assert.are.equal(1, decisions.reviewPrompts)
        assert.same({ 'b' }, decisions.skipped)
        assert.are.equal(2, #decisions.approved)
        for _, approval in ipairs(decisions.approved) do
            assert.same(prediction, approval.dispositions[1].selectedPrediction)
        end
        decisions = Review.collect(manifest, results, { mode = 'automatic', threshold = 0 })
        assert.same({}, decisions.approved)
        results[3].objects[1].bounding_box = { 10, 1, 30, 70 }
        assert.are.equal(2, #Review.units(manifest, results, true))
    end)

    it('automatically accepts agreeing independent direct predictions across region boundaries', function()
        local manifest, results = sample()
        for _, result in ipairs(results) do
            local obj = result.objects[1]
            obj.review_group_id = 'same-region'
            obj.track_id = 'independent-' .. result.frame_id
            obj.identification_provenance = 'direct'
            obj.evidence_frame_ids = { result.frame_id }
        end
        results[3].coordinate_space = 'original:full_quality'
        local decisions = Review.collect(manifest, results, {
            mode = 'assisted', threshold = 90,
            review = function() error('Unexpected review') end,
        })
        assert.are.equal(0, decisions.reviewPrompts)
        assert.are.equal(3, #decisions.approved)
        for _, approval in ipairs(decisions.approved) do
            assert.are.equal('confirmed', approval.dispositions[1].disposition)
        end
        results[3].objects[1].predictions[1].confidence = 0.89
        decisions = Review.collect(manifest, results, {
            mode = 'assisted', threshold = 90,
            review = function() return { action = 'unsure' } end,
        })
        assert.are.equal(1, decisions.reviewPrompts)
        assert.same({}, decisions.approved)
    end)

    it('keeps disagreeing or duplicate independent region predictions in review', function()
        local manifest, results = sample()
        for _, result in ipairs(results) do
            local obj = result.objects[1]
            obj.review_group_id = 'same-region'
            obj.track_id = 'independent-' .. result.frame_id
            obj.identification_provenance = 'direct'
            obj.evidence_frame_ids = { result.frame_id }
        end
        results[3].objects[1].predictions[1].canonical_taxon_id = 43
        local decisions = Review.collect(manifest, results, {
            mode = 'assisted', threshold = 90,
            review = function() return { action = 'unsure' } end,
        })
        assert.are.equal(1, decisions.reviewPrompts)
        assert.same({}, decisions.approved)
        results[3].objects[1].predictions[1].canonical_taxon_id = 42
        local duplicate = object('duplicate', 'direct', 'b')
        duplicate.review_group_id = 'same-region'
        results[2].objects[2] = duplicate
        decisions = Review.collect(manifest, results, {
            mode = 'assisted', threshold = 90,
            review = function() return { action = 'unsure' } end,
        })
        assert.are.equal(1, decisions.reviewPrompts)
        assert.same({}, decisions.approved)
    end)

    it('groups common predictions across windows only for explicit human review', function()
        local manifest, results = sample()
        for _, result in ipairs(results) do
            result.objects[1].review_group_id = 'same-heron'
        end
        results[3].objects[1].track_id = 'window-2'
        local calls = 0
        local decisions = Review.collect(manifest, results, {
            mode = 'assisted', threshold = 90,
            review = function(unit)
                calls = calls + 1
                assert.is_true(unit.automaticBlocked)
                assert.are.equal(3, #unit.evidence)
                return confirm()
            end,
        })
        assert.are.equal(1, calls)
        assert.are.equal(3, #decisions.approved)
    end)

end)
