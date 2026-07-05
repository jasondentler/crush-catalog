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
        assert.same({ 0.9 }, confirmed.predictionConfidences)
        assert.same(prediction.taxonomy, confirmed.selectedPrediction.taxonomy)
        assert.same({
            disposition = 'unsure',
            predictionConfidences = {},
        }, IdentificationLogic.disposition({ action = 'unsure' }, {}))
    end)

    it('maps manual search results to manual dispositions', function()
        local selectedPrediction = {
            taxonomy = { 'Animalia', 'Eudocimus', 'albus' },
            taxonomyRanks = { 'kingdom', 'genus', 'species' },
            commonNameTaxonomy = { 'Animals', 'Ibises', 'White Ibis' },
        }
        local disposition = IdentificationLogic.disposition({
            action = 'manual',
            selectedPrediction = selectedPrediction,
        }, {
            predictions = {
                { confidence = 0.95 },
                { confidence = 0.75 },
            },
        })

        assert.are.equal('manual', disposition.disposition)
        assert.same({ 0.95, 0.75 }, disposition.predictionConfidences)
        assert.same(selectedPrediction, disposition.selectedPrediction)
        assert.is_nil(disposition.selectedPredictionIndex)
    end)
end)
