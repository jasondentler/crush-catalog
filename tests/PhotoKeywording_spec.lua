describe('PhotoKeywording', function()
    local PhotoKeywording = assert(
        loadfile('crush-catalog.lrplugin/PhotoKeywording.lua')
    )()

    local function fixture()
        local catalog = { keywords = {}, createCalls = {}, writeGeneration = 0 }
        local photo = { catalog = catalog, added = {}, removed = {} }

        function catalog:withWriteAccessDo(_, callback)
            self.writeGeneration = self.writeGeneration + 1
            callback()
            return 'executed'
        end

        function catalog:createKeyword(name, synonyms, includeOnExport, parent, returnExisting)
            local path = parent == nil and name or parent.path .. ' > ' .. name
            local existing = self.keywords[path]

            for _, synonym in ipairs(synonyms) do
                assert.are_not.equal(name:lower(), synonym:lower())
            end

            self.createCalls[#self.createCalls + 1] = {
                name = name,
                includeOnExport = includeOnExport,
                parent = parent,
                returnExisting = returnExisting,
            }

            if existing ~= nil then
                if existing.createdGeneration == self.writeGeneration then
                    return nil
                end

                return existing
            end

            local value = {
                name = name,
                path = path,
                parent = parent,
                synonyms = {},
                createdGeneration = self.writeGeneration,
            }

            function value.getSynonyms(keywordValue)
                assert.is_true(
                    keywordValue.createdGeneration < catalog.writeGeneration
                )
                return keywordValue.synonyms
            end

            function value.setAttributes(keywordValue, attributes)
                keywordValue.synonyms = attributes.synonyms
            end

            for _, synonym in ipairs(synonyms) do
                value.synonyms[#value.synonyms + 1] = synonym
            end

            self.keywords[path] = value
            return value
        end

        function photo:addKeyword(keyword)
            self.added[#self.added + 1] = keyword.path
        end

        function photo:removeKeyword(keyword)
            self.removed[#self.removed + 1] = keyword.path
        end

        return catalog, photo
    end

    it('creates and assigns the three rank-aware keyword hierarchies', function()
        local catalog, photo = fixture()
        local prediction = {
            taxonomy = {
                'Animalia', 'Chordata', 'Mammalia', 'Equus', 'quagga', 'chapmani',
            },
            taxonomyRanks = {
                'kingdom', 'phylum', 'class', 'genus', 'species', 'subspecies',
            },
            commonNameTaxonomy = {
                'Animals', 'Chordates', 'Mammals', 'Horses', 'Plains Zebra',
                "Chapman's Zebra",
            },
        }
        local detections = { {
            selectedPredictionIndex = 1,
            selectedPrediction = prediction,
        } }

        PhotoKeywording.record(photo, detections)

        assert.is_not_nil(catalog.keywords['Crush Catalog > All'])
        assert.is_not_nil(catalog.keywords[
            "Crush Catalog > All > Chapman's Zebra"
        ])
        assert.is_not_nil(catalog.keywords[
            'Crush Catalog > Common Names > Animals > Chordates > Mammals'
                .. " > Horses > Plains Zebra > Chapman's Zebra"
        ])
        local species = catalog.keywords[
            'Crush Catalog > Scientific Names > Animalia > Chordata > Mammalia'
                .. ' > Equus > quagga'
        ]
        local subspecies = catalog.keywords[species.path .. ' > chapmani']
        assert.same({ 'Plains Zebra', 'Equus quagga' }, species.synonyms)
        assert.same(
            { "Chapman's Zebra", 'Equus quagga chapmani' },
            subspecies.synonyms
        )
        assert.same(
            { 'chapmani' },
            catalog.keywords[
                'Crush Catalog > Common Names > Animals > Chordates > Mammals'
                    .. " > Horses > Plains Zebra > Chapman's Zebra"
            ].synonyms
        )
        assert.are.equal(13, #photo.added)

        PhotoKeywording.record(photo, detections)
        assert.same({ 'Plains Zebra', 'Equus quagga' }, species.synonyms)
    end)

    it('ignores unconfirmed detections and empty common-name levels', function()
        local catalog, photo = fixture()

        PhotoKeywording.record(photo, {
            { disposition = 'unsure' },
            {
                selectedPredictionIndex = 1,
                selectedPrediction = {
                    taxonomy = { 'Animalia', 'Sciurus', 'niger' },
                    taxonomyRanks = { 'kingdom', 'genus', 'species' },
                    commonNameTaxonomy = { 'Animals', '', 'Fox Squirrel' },
                },
            },
        })

        assert.is_nil(catalog.keywords[
            'Crush Catalog > Common Names > Animals > Sciurus'
        ])
        assert.is_not_nil(catalog.keywords[
            'Crush Catalog > Common Names > Animals > Fox Squirrel'
        ])
        assert.are.equal(6, #photo.added)
    end)

    it('does not create self-synonyms for identical taxonomy names', function()
        local catalog, photo = fixture()

        PhotoKeywording.record(photo, { {
            selectedPredictionIndex = 1,
            selectedPrediction = {
                taxonomy = { 'Animalia', 'Corvus', 'corax' },
                taxonomyRanks = { 'kingdom', 'genus', 'species' },
                commonNameTaxonomy = { 'Animalia', 'Corvus', 'Common Raven' },
            },
        } })

        assert.same({}, catalog.keywords[
            'Crush Catalog > Scientific Names > Animalia'
        ].synonyms)
        assert.same({}, catalog.keywords[
            'Crush Catalog > Common Names > Animalia > Corvus'
        ].synonyms)
        assert.are.equal(7, #photo.added)
    end)

    it('reuses shared ancestry created in the current transaction', function()
        local catalog, photo = fixture()
        local function detection(species, commonName)
            return {
                selectedPredictionIndex = 1,
                selectedPrediction = {
                    taxonomy = { 'Animalia', 'Ardea', species },
                    taxonomyRanks = { 'kingdom', 'genus', 'species' },
                    commonNameTaxonomy = { 'Animals', 'Great Herons', commonName },
                },
            }
        end

        PhotoKeywording.record(photo, {
            detection('herodias', 'Great Blue Heron'),
            detection('alba', 'Great Egret'),
        })

        local animaliaCreates = 0

        for _, call in ipairs(catalog.createCalls) do
            if call.name == 'Animalia' then
                animaliaCreates = animaliaCreates + 1
            end
        end

        assert.are.equal(1, animaliaCreates)
        assert.is_not_nil(catalog.keywords[
            'Crush Catalog > Scientific Names > Animalia > Ardea > alba'
        ])
    end)

    it('removes existing Crush Catalog assignments when reprocessing', function()
        local _, photo = fixture()

        local function existingKeyword(name, path, parent)
            local value = { name = name, path = path, parent = parent }
            function value:getName() return self.name end
            function value:getParent() return self.parent end
            return value
        end

        local root = existingKeyword('Crush Catalog', 'Crush Catalog')
        local common = existingKeyword(
            'Common Names',
            'Crush Catalog > Common Names',
            root
        )
        local bird = existingKeyword(
            'Old Bird',
            'Crush Catalog > Common Names > Old Bird',
            common
        )
        local unrelatedRoot = existingKeyword('Places', 'Places')
        local unrelated = existingKeyword('Texas', 'Places > Texas', unrelatedRoot)

        function photo.getRawMetadata(_, key)
            assert.are.equal('keywords', key)
            return { root, common, bird, unrelated }
        end

        PhotoKeywording.record(photo, {}, true)

        assert.same({
            'Crush Catalog',
            'Crush Catalog > Common Names',
            'Crush Catalog > Common Names > Old Bird',
        }, photo.removed)
    end)
end)
