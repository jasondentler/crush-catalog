local IdentificationLogic = assert(
    loadfile('crush-catalog.lrplugin/Core/IdentificationLogic.lua')
)()
local TaxonomyNames = assert(loadfile('crush-catalog.lrplugin/Core/TaxonomyNames.lua'))()

describe('IdentificationLogic', function()
    it('builds prediction menu items without Lightroom dependencies', function()
        local items = IdentificationLogic.predictionItems({ {
            confidence = 0.365,
            taxonomy = {
                'Animalia', 'Chordata', 'Aves', 'Passeriformes',
                'Corvidae', 'Corvus', 'corax',
            },
            taxonomy_common_names = {
                'Animals', '', 'Birds', '', 'Crows', 'Ravens', 'Common Raven',
            },
        } }, 'Nothing found', TaxonomyNames)

        assert.same({ {
            title = 'Common Raven (Corvus corax) 36.5%',
            value = 1,
        } }, items)
        assert.same({ {
            title = 'Nothing found',
            value = 0,
        } }, IdentificationLogic.predictionItems({}, 'Nothing found', TaxonomyNames))
    end)

    it('maps dialog results to normalized dispositions', function()
        local prediction = {
            confidence = 0.9,
            taxonomy = { 'Animalia', 'Corvus', 'corax' },
            taxonomy_ranks = { 'kingdom', 'genus', 'species' },
            taxonomy_common_names = { 'Animals', 'Ravens', 'Common Raven' },
        }
        local confirmed = IdentificationLogic.disposition({
            action = 'ok',
            selectedPredictionIndex = 1,
        }, {
            predictions = { prediction },
        })

        assert.are.equal('confirmed', confirmed.disposition)
        assert.are.equal(1, confirmed.selectedPredictionIndex)
        assert.are.equal(0.9, confirmed.selectedPrediction.confidence)
        assert.same(prediction.taxonomy, confirmed.selectedPrediction.taxonomy)
        assert.same(
            { disposition = 'unsure' },
            IdentificationLogic.disposition({ action = 'unsure' }, {})
        )
    end)
end)
