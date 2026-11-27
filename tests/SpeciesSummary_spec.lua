local Summary = assert(loadfile('crush-catalog.lrplugin/Core/SpeciesSummary.lua'))()

local function keyword(name, synonyms, photos, children)
    local result = { photos = photos or {}, children = children or {} }
    function result.getName() return name end
    function result.getSynonyms() return synonyms or {} end
    function result:getPhotos() return self.photos end
    function result:getChildren() return self.children end
    return result
end

local function catalog(scientificChildren)
    local root = keyword('Crush Catalog', {}, {}, {
        keyword('Scientific Names', {}, {}, scientificChildren),
        keyword('Common Names', {}, {}, {
            keyword('Duplicate common name', {}, { { localIdentifier = 100 } }),
        }),
        keyword('All', {}, {}, {
            keyword('Duplicate flat name', {}, { { localIdentifier = 100 } }),
        }),
    })
    return {
        getKeywords = function()
            return { root, keyword('Unrelated', {}, {}, scientificChildren) }
        end,
    }
end

describe('SpeciesSummary', function()
    it('counts unique species and lifers from live catalog keyword memberships', function()
        local a, b, c, d = { localIdentifier = 1 }, { localIdentifier = 2 },
            { localIdentifier = 3 }, { localIdentifier = 4 }
        local heron = keyword('herodias', { 'Great Blue Heron', 'Ardea herodias' }, { a })
        local egret = keyword('alba', { 'Great Egret', 'Ardea alba' })
        local subspecies = keyword('occidentalis',
            { 'Great White Heron', 'Ardea herodias occidentalis' }, { a, b })
        heron.children = { subspecies }
        local genus = keyword('Ardea', {}, { d }, { heron, egret })
        local catalogValue = catalog({ keyword('Animalia', {}, {}, {
            keyword('Aves', {}, {}, { genus }),
        }) })
        local before = Summary.snapshot(catalogValue)
        assert.is_true(before['ardea herodias'].present)
        assert.is_false(before['ardea alba'].present)
        assert.is_nil(before['ardea herodias occidentalis'])

        heron.photos = { a, b }
        egret.photos = { c, d }
        local after = Summary.snapshot(catalogValue, { a, b, c })
        local result = Summary.compare(before, after)

        assert.are.equal(2, result.catalogTotal)
        assert.same({
            { name = 'Great Blue Heron', scientificName = 'Ardea herodias', count = 2 },
            { name = 'Great Egret', scientificName = 'Ardea alba', count = 1 },
        }, result.ranked)
        assert.same({ result.ranked[2] }, result.lifers)

        -- Reprocessing the same photographs cannot create new lifers.
        assert.same({}, Summary.compare(after, after).lifers)
    end)

    it('excludes unused species and includes manually attached subspecies', function()
        local photo = { localIdentifier = 1 }
        local catalogValue = catalog({
            keyword('Equus', {}, {}, {
                keyword('quagga', { 'Plains Zebra', 'Equus quagga' }, {}, {
                    keyword('chapmani', { "Chapman's Zebra" }, { photo }),
                }),
                keyword('zebra', { 'Mountain Zebra', 'Equus zebra' }),
            }),
        })
        local result = Summary.compare({}, Summary.snapshot(catalogValue, { photo }))
        assert.are.equal(1, result.catalogTotal)
        assert.are.equal(1, #result.ranked)
        assert.are.equal('Plains Zebra', result.lifers[1].name)
    end)

    it('deduplicates the same binomial across hierarchies and uses stable photo identifiers', function()
        local a = { localIdentifier = 1 }
        local b = { localIdentifier = 2 }
        local catalogValue = catalog({
            keyword('Corvus', {}, {}, {
                keyword('corax', { 'Common Raven', 'Corvus corax' }, { a }),
            }),
            keyword('Corvidae', {}, {}, {
                keyword('Corvus', {}, {}, {
                    keyword('Corvus corax', { 'Common Raven' }, { a, b }),
                }),
            }),
        })
        local result = Summary.compare({}, Summary.snapshot(catalogValue, {
            { localIdentifier = 1 }, { localIdentifier = 2 },
        }))
        assert.are.equal(1, result.catalogTotal)
        assert.are.equal(2, result.ranked[1].count)
        assert.are.equal(1, #result.lifers)
    end)

    it('does not count higher ranks, unrelated keywords, or untagged species', function()
        local photo = { localIdentifier = 1 }
        local catalogValue = catalog({
            keyword('Aves', { 'Birds' }, { photo }, {
                keyword('Corvus', { 'Crows' }, { photo }, {
                    keyword('corax', { 'Common Raven', 'Corvus corax' }),
                    keyword('unknown', { 'Unknown crow' }, { photo }),
                }),
            }),
        })
        local result = Summary.compare({}, Summary.snapshot(catalogValue, { photo }))
        assert.are.equal(0, result.catalogTotal)
        assert.same({}, result.ranked)
        assert.same({}, result.lifers)
    end)

    it('counts legacy species with a common-name synonym or no synonyms', function()
        local photo = { localIdentifier = 1 }
        local catalogValue = catalog({
            keyword('Haliaeetus', {}, {}, {
                keyword('leucocephalus', { 'Bald Eagle' }, { photo }),
            }),
            keyword('Anhinga', {}, {}, {
                keyword('anhinga', {}, { photo }),
            }),
            keyword('Hericium', {}, {}, {
                keyword('Hericium Erinaceus', {}, { photo }),
            }),
        })
        local before = Summary.snapshot(catalogValue)
        local after = Summary.snapshot(catalogValue, { photo })
        local result = Summary.compare(before, after)
        assert.are.equal(3, result.catalogTotal)
        assert.are.equal(3, #result.ranked)
        assert.same({}, result.lifers)
        assert.are.equal('Bald Eagle', after['haliaeetus leucocephalus'].name)
        assert.is_true(after['anhinga anhinga'].present)
        assert.is_true(after['hericium erinaceus'].present)
    end)

    it('excludes species complexes without excluding species beneath them', function()
        local photo = { localIdentifier = 1 }
        local catalogValue = catalog({
            keyword('Porcellio', {}, {}, {
                keyword('Porcellio Laevis Group', {}, { photo }, {
                    keyword('laevis', { 'Smooth Slater' }, { photo }),
                }),
            }),
            keyword('Micropterus', {}, {}, {
                keyword('Micropterus Salmoides', { 'Largemouth Bass Complex' }, { photo }),
            }),
            keyword('Acanthurus', {}, {}, {
                keyword('Acanthurus Triostegus', { 'Convict Surgeonfishes' }, { photo }),
            }),
        })
        local result = Summary.compare({}, Summary.snapshot(catalogValue, { photo }))
        assert.are.equal(1, result.catalogTotal)
        assert.are.equal('Porcellio laevis', result.ranked[1].scientificName)
    end)

    it('visits species below unmarked title-cased legacy complexes', function()
        local photo = { localIdentifier = 1 }
        local catalogValue = catalog({
            keyword('Schistocerca', {}, {}, {
                keyword('Schistocerca Alutacea', {}, { photo }, {
                    keyword('obscura', { 'Obscure Bird Grasshopper' }, { photo }),
                }),
            }),
            keyword('Pleurotus', {}, {}, {
                keyword('Pleurotus Ostreatus', {}, { photo }, {
                    keyword('pulmonarius', { 'Pale Oyster' }, { photo }),
                }),
            }),
        })
        local after = Summary.snapshot(catalogValue, { photo })
        assert.is_nil(after['schistocerca alutacea'])
        assert.is_nil(after['pleurotus ostreatus'])
        local result = Summary.compare({}, after)
        assert.are.equal(2, result.catalogTotal)
        assert.are.equal('Schistocerca obscura', result.ranked[1].scientificName)
        assert.are.equal('Pleurotus pulmonarius', result.ranked[2].scientificName)
    end)

    it('uses the genus named in a complex instead of an intervening section', function()
        local photo = { localIdentifier = 1 }
        local catalogValue = catalog({
            keyword('Quercus', {}, {}, {
                keyword('Phellos', {}, {}, {
                    keyword('Quercus Marilandica', {}, { photo }, {
                        keyword('falcata', { 'Southern Red Oak' }, { photo }),
                    }),
                }),
            }),
        })
        local after = Summary.snapshot(catalogValue, { photo })
        assert.is_nil(after['phellos falcata'])
        assert.is_true(after['quercus falcata'].present)
        assert.are.equal(1, Summary.compare({}, after).catalogTotal)
    end)

    it('does not report a lifer when a scientific synonym clarifies the genus', function()
        local photo = { localIdentifier = 1 }
        local synonyms = { 'Loblolly Pine' }
        local catalogValue = catalog({
            keyword('Pinus', {}, {}, {
                keyword('Australes', {}, {}, {
                    keyword('taeda', synonyms, { photo }),
                }),
            }),
        })
        local before = Summary.snapshot(catalogValue)
        synonyms[#synonyms + 1] = 'Pinus Australes taeda'
        local after = Summary.snapshot(catalogValue, { photo })
        local result = Summary.compare(before, after)
        assert.are.equal(1, result.catalogTotal)
        assert.are.equal('Pinus taeda', result.ranked[1].scientificName)
        assert.are.equal('Loblolly Pine', result.ranked[1].name)
        assert.same({}, result.lifers)
    end)

    it('does not report false lifers when the initial snapshot fails', function()
        local result = Summary.compare(nil, {})
        assert.are.equal(0, result.catalogTotal)
        assert.is_nil(result.lifers)
        assert.same({}, Summary.compare({}, nil))
    end)

    it('formats elapsed time for short and long identification runs', function()
        assert.are.equal('8s', Summary.elapsed(7.951))
        assert.are.equal('2m 14s', Summary.elapsed(134))
        assert.are.equal('1h 2m 3s', Summary.elapsed(3723))
    end)
end)
