describe('AutomaticModesLogic', function()
    local logic = assert(
        loadfile('crush-catalog.lrplugin/Core/AutomaticModesLogic.lua')
    )()

    local function result(confidence)
        return { predictions = { {
            confidence = confidence,
            taxonomy = { 'Animalia', 'Corvus', 'corax' },
            taxonomy_ranks = { 'kingdom', 'genus', 'species' },
            taxonomy_common_names = { 'Animals', 'Corvus', 'Common Raven' },
        } } }
    end

    it('validates integer percentage thresholds and modes', function()
        assert.are.equal(0, logic.threshold('0'))
        assert.are.equal(100, logic.threshold('100'))
        assert.is_nil(logic.threshold('90.5'))
        assert.is_nil(logic.threshold('-1'))
        assert.is_nil(logic.threshold('101'))
        assert.is_nil(logic.threshold('nope'))
        assert.is_true(logic.validOptions({ mode = 'assisted', threshold = '90' }))
        assert.is_false(logic.validOptions({ mode = 'automatic', threshold = '' }))
        assert.is_true(logic.validOptions({ mode = 'manual', threshold = '' }))
        assert.is_false(logic.validOptions({ mode = 'unknown', threshold = '90' }))
    end)

    it('confirms the top prediction at the threshold and is unsure below it', function()
        local confirmed = logic.automaticDisposition(result(0.9), 90)
        local unsureResult = result(0.899)
        unsureResult.predictions[2] = { confidence = 0.5 }
        local unsure = logic.automaticDisposition(unsureResult, 90)

        assert.are.equal('confirmed', confirmed.disposition)
        assert.are.equal(1, confirmed.selectedPredictionIndex)
        assert.are.equal('Common Raven', confirmed.selectedPrediction.commonNameTaxonomy[3])
        assert.are.equal('unsure', unsure.disposition)
        assert.same({ 0.899, 0.5 }, unsure.predictionConfidences)
        assert.are.equal('unsure', logic.automaticDisposition({ predictions = {} }, 90).disposition)
    end)

    it('shows only low-confidence detections in assisted mode', function()
        assert.is_false(logic.shouldShowManual(
            result(0.95),
            { mode = 'assisted', threshold = 90 }
        ))
        assert.is_true(logic.shouldShowManual(
            result(0.89),
            { mode = 'assisted', threshold = 90 }
        ))
        assert.is_false(logic.shouldShowManual(
            result(0.1),
            { mode = 'automatic', threshold = 90 }
        ))
        assert.is_true(logic.shouldShowManual(result(0.99), { mode = 'manual' }))
    end)

    it('processes new, unsure, or explicitly reprocessed photos', function()
        assert.is_true(logic.shouldProcess(false, nil, false))
        assert.is_true(logic.shouldProcess(true, '2', false))
        assert.is_false(logic.shouldProcess(true, '0', false))
        assert.is_true(logic.shouldProcess(true, '0', true))
    end)

    it('resolves dependencies from the Lightroom plugin path', function()
        local originalPlugin = _G._PLUGIN
        _G._PLUGIN = { path = 'crush-catalog.lrplugin' }

        local loaded, component = pcall(
            assert(loadfile('crush-catalog.lrplugin/Core/AutomaticModesLogic.lua'))
        )

        _G._PLUGIN = originalPlugin
        assert.is_true(loaded)
        assert.is_table(component)
    end)
end)
