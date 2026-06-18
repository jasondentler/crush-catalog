local function loadHttp(lrHttp)
    _G._PLUGIN = {
        path = 'crush-catalog.lrplugin',
    }
    _G.import = function(name)
        assert.are.equal('LrHttp', name)
        return lrHttp or {}
    end

    return assert(loadfile('crush-catalog.lrplugin/Http.lua'))()
end

describe('Http', function()
    it('wraps LrHttp.postMultipart with normalized headers', function()
        local capturedUrl
        local capturedParts
        local capturedHeaders
        local Http = loadHttp({
            postMultipart = function(url, parts, headers)
                capturedUrl = url
                capturedParts = parts
                capturedHeaders = headers

                return 'body', {
                    { field = 'Content-Type', value = 'application/json' },
                }
            end,
        })

        local response = Http.postMultipart('http://example.test/identify', { 'part' }, { 'header' })

        assert.are.equal('http://example.test/identify', capturedUrl)
        assert.same({ 'part' }, capturedParts)
        assert.same({ 'header' }, capturedHeaders)
        assert.are.equal('body', response.body)
        assert.are.equal('application/json', response.normalizedHeaders['content-type'])
    end)
end)
