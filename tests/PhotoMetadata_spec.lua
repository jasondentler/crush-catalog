describe('PhotoMetadata', function()
    local PhotoMetadata = assert(loadfile('crush-catalog.lrplugin/PhotoMetadata.lua'))()
    local PhotoMetadataLogic = assert(
        loadfile('crush-catalog.lrplugin/Core/PhotoMetadataLogic.lua')
    )()
    local TaxonomyNames = assert(loadfile('crush-catalog.lrplugin/Core/TaxonomyNames.lua'))()

    it('summarizes confirmed predictions and preserves their taxonomies', function()
        local summary = PhotoMetadataLogic.summarize({
            {
                selectedPredictionIndex = 2,
                selectedPrediction = {
                    commonName = 'Fox Squirrel',
                    scientificName = 'niger',
                    confidence = 0.75,
                    taxonomy = { 'Animalia', 'Sciurus', 'niger' },
                    commonNameTaxonomy = { 'Animals', 'Squirrels', 'Fox Squirrel' },
                },
            },
            {
                selectedPredictionIndex = 1,
                selectedPrediction = {
                    commonName = 'American Robin',
                    scientificName = 'Turdus migratorius',
                    confidence = 0.982,
                    taxonomy = { 'Animalia', 'Turdus', 'migratorius' },
                    commonNameTaxonomy = { 'Animals', 'Thrushes', 'American Robin' },
                },
            },
            {
                selectedPredictionIndex = 1,
                selectedPrediction = {
                    commonName = 'Fox Squirrel',
                    scientificName = 'niger',
                    confidence = 0.8,
                    taxonomy = { 'Animalia', 'Sciurus', 'niger' },
                    commonNameTaxonomy = { 'Animals', 'Squirrels', 'Fox Squirrel' },
                },
            },
            { disposition = 'unsure' },
            { disposition = 'not_an_animal' },
        }, TaxonomyNames)

        assert.are.equal('American Robin, Fox Squirrel', summary.commonNames)
        assert.are.equal('Sciurus niger, Turdus migratorius', summary.scientificNames)
        assert.are.equal(5, summary.detectionCount)
        assert.are.equal(2, summary.topSuggestionCount)
        assert.are.equal(1, summary.otherSuggestionCount)
        assert.are.equal(1, summary.unsureCount)
        assert.are.equal(1, summary.detectionFalsePositivesCount)
        assert.are.equal('98.2', summary.topSuggestionConfidence)
        assert.same({ 'Animalia', 'Sciurus', 'niger' }, summary.taxonomies[1])
        assert.same(
            { 'Animals', 'Thrushes', 'American Robin' },
            summary.commonNameTaxonomies[2]
        )
    end)

    it('records string values inside a private catalog write gate', function()
        local originalPlugin = _G._PLUGIN
        local plugin = { id = 'test-plugin' }
        local written = {}
        local writeGateEntered = false
        local photo = {
            catalog = {
                withPrivateWriteAccessDo = function(catalog, callback)
                    assert.is_not_nil(catalog)
                    writeGateEntered = true
                    callback()
                    return 'executed'
                end,
            },
        }

        function photo:setPropertyForPlugin(receivedPlugin, fieldId, value)
            assert.is_true(writeGateEntered)
            assert.are.equal(photo, self)
            assert.are.equal(plugin, receivedPlugin)
            written[fieldId] = value
        end

        _G._PLUGIN = plugin
        local summary, status = PhotoMetadata.record(photo, {
            {
                selectedPredictionIndex = 1,
                selectedPrediction = {
                    commonName = 'Fox Squirrel',
                    scientificName = 'niger',
                    confidence = 0.365,
                    taxonomy = { 'Animalia', 'Sciurus', 'niger' },
                    commonNameTaxonomy = { 'Animals', 'Squirrels', 'Fox Squirrel' },
                },
            },
            { disposition = 'unsure' },
        })
        _G._PLUGIN = originalPlugin

        assert.are.equal('executed', status)
        assert.are.equal(2, summary.detectionCount)
        assert.same({
            commonNames = 'Fox Squirrel',
            scientificNames = 'Sciurus niger',
            detectionCount = '2',
            topSuggestionCount = '1',
            otherSuggestionCount = '0',
            unsureCount = '1',
            detectionFalsePositivesCount = '0',
            topSuggestionConfidence = '36.5',
        }, written)
    end)
end)
