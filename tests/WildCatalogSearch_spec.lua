local JSON = assert(loadfile('crush-catalog.lrplugin/JSON.lua'))()
local Search = assert(loadfile('crush-catalog.lrplugin/Core/WildCatalogSearch.lua'))()

describe('WildCatalogSearch', function()
    it('builds the search request contract', function()
        local request = Search.buildRequest('white ibis', {
            baseUrl = 'http://localhost:8000/',
            gpsCoordinates = {
                latitude = 29.573361,
                longitude = -94.389507,
            },
            commonNameLanguage = 'en-US',
        })

        assert.are.equal(
            'http://localhost:8000/search?query=white%20ibis&lat=29.573361&lng=-94.389507',
            request.url
        )
        assert.same({
            { field = 'Accept', value = 'application/json' },
            { field = 'Accept-Language', value = 'en-US' },
        }, request.headers)
    end)

    it('normalizes legacy endpoint URLs and parses results', function()
        local request = Search.buildRequest('ibis', {
            baseUrl = 'http://localhost:8000/search/',
        })
        local response = Search.parseResponse({
            body = JSON:encode({
                total_items = 1,
                items = { {
                    taxonomy = { 'Animalia', 'Eudocimus', 'albus' },
                    taxonomy_rank_names = { 'kingdom', 'genus', 'species' },
                    taxonomy_common_names = {
                        'Animals', 'Ibises', 'White Ibis',
                    },
                } },
            }),
            headers = {},
        }, JSON)

        assert.are.equal('http://localhost:8000/search?query=ibis', request.url)
        assert.are.equal(1, response.totalItems)
        assert.same({
            taxonomy = { 'Animalia', 'Eudocimus', 'albus' },
            taxonomyRanks = { 'kingdom', 'genus', 'species' },
            commonNameTaxonomy = { 'Animals', 'Ibises', 'White Ibis' },
        }, response.items[1])
    end)
end)
