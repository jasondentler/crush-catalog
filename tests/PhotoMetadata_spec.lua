describe('PhotoMetadata', function()
    local PhotoMetadata = assert(loadfile('crush-catalog.lrplugin/PhotoMetadata.lua'))()
    local PhotoMetadataLogic = assert(
        loadfile('crush-catalog.lrplugin/Core/PhotoMetadataLogic.lua')
    )()
    local TaxonomyNames = assert(loadfile('crush-catalog.lrplugin/Core/TaxonomyNames.lua'))()

    it('summarizes confirmed predictions and preserves their taxonomies', function()
        local summary = PhotoMetadataLogic.summarize({
            {
                predictionConfidences = { 0.99, 0.75, 0.5 },
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
        assert.are.equal('99.0', summary.topSuggestionConfidence)
        assert.same({ 'Animalia', 'Sciurus', 'niger' }, summary.taxonomies[1])
        assert.same(
            { 'Animals', 'Thrushes', 'American Robin' },
            summary.commonNameTaxonomies[2]
        )
    end)

    it('sets confidence to zero for detections without predictions', function()
        local summary = PhotoMetadataLogic.summarize({
            { disposition = 'unsure', predictionConfidences = {} },
        }, TaxonomyNames)

        assert.are.equal('0.0', summary.topSuggestionConfidence)
        assert.are.equal('', PhotoMetadataLogic.summarize(
            {},
            TaxonomyNames
        ).topSuggestionConfidence)
    end)

    it('records metadata and keywords inside their required catalog write gates', function()
        local originalPlugin = _G._PLUGIN
        local plugin = { id = 'test-plugin' }
        local written = {}
        local privateWriteGateEntered = false
        local privateWriteTimeout
        local writeGateEntered = false
        local writeActions = {}
        local keywords = {}
        local photo = {
            catalog = {
                withPrivateWriteAccessDo = function(catalog, callback, timeoutParams)
                    assert.is_not_nil(catalog)
                    privateWriteTimeout = timeoutParams.timeout
                    privateWriteGateEntered = true
                    callback()
                    privateWriteGateEntered = false
                    return 'executed'
                end,
                withWriteAccessDo = function(catalog, actionName, callback)
                    assert.is_not_nil(catalog)
                    writeActions[#writeActions + 1] = actionName
                    assert.is_false(privateWriteGateEntered)
                    writeGateEntered = true
                    callback()
                    writeGateEntered = false
                    return 'executed'
                end,
                createKeyword = function(_, name, synonyms, _, parent)
                    assert.is_true(writeGateEntered)
                    local key = tostring(parent) .. '/' .. name
                    local value = keywords[key]

                    if value == nil then
                        value = { name = name, synonyms = synonyms, parent = parent }
                        function value:getSynonyms() return self.synonyms end
                        function value:setAttributes(attributes)
                            self.synonyms = attributes.synonyms
                        end
                        keywords[key] = value
                    end

                    return value
                end,
            },
        }

        function photo:setPropertyForPlugin(receivedPlugin, fieldId, value)
            assert.is_true(privateWriteGateEntered)
            assert.is_false(writeGateEntered)
            assert.are.equal(photo, self)
            assert.are.equal(plugin, receivedPlugin)
            written[fieldId] = value
        end

        function photo.addKeyword()
            assert.is_true(writeGateEntered)
            assert.is_false(privateWriteGateEntered)
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
        assert.are.equal(30, privateWriteTimeout)
        assert.same({
            'Apply Crush Catalog keywords',
            'Update Crush Catalog synonyms',
        }, writeActions)
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
