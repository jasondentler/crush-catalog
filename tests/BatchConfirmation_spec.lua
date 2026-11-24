local function loadConfirmation(preparation, dialog)
    local priorPreparation = package.loaded.BatchPreparation
    local priorDialog = package.loaded.BatchReviewDialog
    package.loaded.BatchPreparation = preparation
    package.loaded.BatchReviewDialog = dialog
    local ok, result = pcall(assert(loadfile('crush-catalog.lrplugin/BatchConfirmation.lua')))
    package.loaded.BatchPreparation = priorPreparation
    package.loaded.BatchReviewDialog = priorDialog
    assert(ok, tostring(result))
    return result
end

local function fixture()
    local item = { photo = {} }
    local plan = {
        manifest = { frames = { { frame_id = 'a' } } },
        items = { a = { item = item } },
    }
    local frame = {
        frame_id = 'a', status = 'identified', coordinate_space = 'original:full_quality',
        width = 100, height = 100,
        objects = { {
            identification_provenance = 'direct', geometry_provenance = 'detected',
            geometry_clipped = false, review_required = false, conflict_evidence_frame_ids = {},
            bounding_box = { 10, 10, 20, 20 },
            predictions = { {
                canonical_namespace = 'inaturalist', canonical_taxon_id = 42,
                confidence = 0.99, taxonomy = { 'Animalia' },
                taxonomy_rank_names = { 'kingdom' }, common_names = { 'Animals' },
            } },
        } },
    }
    local preparation = {
        isCurrent = function(value) return value == item end,
        run = function(p, identify, options)
            return identify(p.manifest, options)
        end,
    }
    return plan, frame, preparation
end

describe('BatchConfirmation', function()
    it('runs automatic confirmation without requesting evidence images', function()
        local plan, frame, preparation = fixture()
        local confirmation = loadConfirmation(preparation, {
            review = function() error('Unexpected manual review') end,
        })
        local result = confirmation.run(plan, function(manifest, options)
            assert.is_false(manifest.include_review_images)
            local final = { results = { frame } }
            final.confirmations = options.onCompleted(final)
            return final
        end, { mode = 'automatic', threshold = 90 })
        assert.are.equal(1, #result.confirmations.approved)
        assert.are.equal('a', result.confirmations.approved[1].frame_id)
    end)

    it('requests evidence for manual review while preserving the selected photo identity', function()
        local plan, frame, preparation = fixture()
        local getter = function() end
        local confirmation = loadConfirmation(preparation, {
            review = function(unit, options)
                assert.are.equal(frame, unit.members[1].frame)
                assert.are.equal(plan.items, options.items)
                assert.are.equal(getter, options.getCrop)
                return { action = 'ok', selectedPredictionIndex = 1 }
            end,
        })
        local result = confirmation.run(plan, function(manifest, options)
            assert.is_true(manifest.include_review_images)
            local final = { results = { frame } }
            final.confirmations = options.onCompleted(final, getter)
            return final
        end, { mode = 'manual', language = 'en-US' })
        assert.are.equal('a', result.confirmations.approved[1].frame_id)
    end)
end)
