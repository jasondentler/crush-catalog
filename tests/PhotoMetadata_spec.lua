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
            {
                disposition = 'manual',
                selectedPrediction = {
                    commonName = 'White Ibis',
                    scientificName = 'Eudocimus albus',
                    taxonomy = { 'Animalia', 'Eudocimus', 'albus' },
                    commonNameTaxonomy = { 'Animals', 'Ibises', 'White Ibis' },
                },
            },
        }, TaxonomyNames)

        assert.are.equal('American Robin, Fox Squirrel, White Ibis', summary.commonNames)
        assert.are.equal(
            'Eudocimus albus, Sciurus niger, Turdus migratorius',
            summary.scientificNames
        )
        assert.are.equal(6, summary.detectionCount)
        assert.are.equal(2, summary.topSuggestionCount)
        assert.are.equal(1, summary.otherSuggestionCount)
        assert.are.equal(1, summary.manualCount)
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
            manualCount = '0',
            unsureCount = '1',
            detectionFalsePositivesCount = '0',
            topSuggestionConfidence = '36.5',
        }, written)
    end)

    it('clears metadata and keywords inside their required catalog write gates', function()
        local originalPlugin = _G._PLUGIN
        local plugin = { id = 'test-plugin' }
        local cleared = {}
        local actions = {}
        local privateWriteTimeout
        local root = { name = 'Crush Catalog' }
        local child = { name = 'Birds', parent = root }
        local photo = {
            catalog = {
                withWriteAccessDo = function(_, action, callback)
                    actions[#actions + 1] = action
                    callback()
                    return 'executed'
                end,
                withPrivateWriteAccessDo = function(_, callback, timeoutParams)
                    privateWriteTimeout = timeoutParams.timeout
                    callback()
                    return 'executed'
                end,
            },
        }
        function root:getName() return self.name end
        function root.getParent() return nil end
        function child:getName() return self.name end
        function child:getParent() return self.parent end
        function photo.getRawMetadata(_, key)
            assert.are.equal('keywords', key)
            return { child }
        end
        function photo.removeKeyword(_, value)
            assert.are.equal(child, value)
        end
        function photo.setPropertyForPlugin(_, receivedPlugin, fieldId, value)
            assert.are.equal(plugin, receivedPlugin)
            assert.is_nil(value)
            cleared[#cleared + 1] = fieldId
        end

        _G._PLUGIN = plugin
        local status = PhotoMetadata.clear(photo)
        _G._PLUGIN = originalPlugin

        assert.are.equal('executed', status)
        assert.are.equal(30, privateWriteTimeout)
        assert.same({ 'Remove Crush Catalog keywords' }, actions)
        assert.same({
            'commonNames',
            'scientificNames',
            'detectionCount',
            'topSuggestionCount',
            'otherSuggestionCount',
            'manualCount',
            'unsureCount',
            'detectionFalsePositivesCount',
            'topSuggestionConfidence',
        }, cleared)
    end)

    it('commits approved batch metadata and keyword assignments in one write gate', function()
        local state = { gates = {}, keywords = {}, generation = 0 }
        local catalog = {}
        function catalog.withWriteAccessDo(_, action, callback)
            state.gates[#state.gates + 1] = action
            state.generation = state.generation + 1
            state.inWrite = true
            local ok, failure = pcall(callback)
            state.inWrite = false
            if not ok then error(failure, 0) end
            return 'executed'
        end
        function catalog.createKeyword(_, name, synonyms, _includeOnExport, parent)
            assert.is_true(state.inWrite)
            local path = (parent and parent.path or '') .. '/' .. name
            assert.is_nil(state.keywords[path])
            local keyword = { path = path, synonyms = synonyms, generation = state.generation }
            function keyword:getSynonyms()
                assert.is_true(self.generation < state.generation)
                return self.synonyms
            end
            function keyword:setAttributes(attributes) self.synonyms = attributes.synonyms end
            state.keywords[path] = keyword
            return keyword
        end
        local function makePhoto()
            local photo = { catalog = catalog, written = {}, added = {} }
            function photo:setPropertyForPlugin(_, field, value)
                assert.is_true(state.inWrite)
                assert.are.equal(1, state.generation)
                self.written[field] = value
            end
            function photo:addKeyword(keyword)
                assert.is_true(state.inWrite)
                self.added[#self.added + 1] = keyword.path
            end
            return photo
        end
        local first, second, excluded = makePhoto(), makePhoto(), makePhoto()
        local dispositions = { {
            disposition = 'confirmed', selectedPredictionIndex = 1,
            predictionConfidences = { 0.95 },
            selectedPrediction = {
                taxonomy = { 'Animalia', 'Corvus', 'corax' },
                taxonomyRanks = { 'kingdom', 'genus', 'species' },
                commonNameTaxonomy = { 'Animals', 'Ravens', 'Common Raven' },
            },
        } }
        local status = PhotoMetadata.recordBatch({
            { photo = first, dispositions = dispositions },
            { photo = second, dispositions = dispositions },
        }, function()
            assert.is_true(state.inWrite)
            return true
        end)
        assert.are.equal('executed', status)
        assert.same({ 'Apply Crush Catalog batch keywords',
            'Update Crush Catalog batch synonyms' }, state.gates)
        assert.same(first.added, second.added)
        assert.are.equal('Common Raven', first.written.commonNames)
        assert.same(first.written, second.written)
        assert.same({}, excluded.added)
        assert.same({}, excluded.written)
    end)

    it('rolls back an approved batch when metadata writing raises an error', function()
        local current = { assigned = { 'Existing keyword' }, metadata = { old = 'value' } }
        local catalog = {}
        function catalog.withWriteAccessDo(_, _action, callback)
            local saved = current
            current = { assigned = { unpack(saved.assigned) }, metadata = { old = saved.metadata.old } }
            local ok, failure = pcall(callback)
            if not ok then
                current = saved
                error(failure, 0)
            end
            return 'executed'
        end
        function catalog.createKeyword(_, name)
            return { name = name }
        end
        local photo = { catalog = catalog }
        function photo.addKeyword(_, keyword)
            current.assigned[#current.assigned + 1] = keyword.name
        end
        function photo.setPropertyForPlugin(_, _plugin, field, value)
            current.metadata[field] = value
            error('Simulated catalog write failure', 0)
        end
        local entries = { {
            photo = photo,
            dispositions = { {
                disposition = 'confirmed', selectedPredictionIndex = 1,
                selectedPrediction = {
                    taxonomy = { 'Animalia' }, taxonomyRanks = { 'kingdom' },
                    commonNameTaxonomy = { 'Animals' },
                },
            } },
        } }
        assert.has_error(function()
            PhotoMetadata.recordBatch(entries, function() return true end)
        end, 'Simulated catalog write failure')
        assert.same({ assigned = { 'Existing keyword' }, metadata = { old = 'value' } }, current)
        assert.has_error(function()
            PhotoMetadata.recordBatch(entries, function() return false end)
        end)
        assert.same({ assigned = { 'Existing keyword' }, metadata = { old = 'value' } }, current)
    end)

    it('rejects unresolved or negative-only entries before accessing the catalog', function()
        local entries = { { photo = {}, dispositions = { { disposition = 'unsure' } } } }
        assert.has_error(function()
            PhotoMetadata.recordBatch(entries, function() return true end)
        end, 'Unresolved detection in batch write')
        entries[1].dispositions[1].disposition = 'not_an_animal'
        assert.has_error(function()
            PhotoMetadata.recordBatch(entries, function() return true end)
        end)
    end)

end)
