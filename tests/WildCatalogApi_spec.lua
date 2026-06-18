local function loadWildCatalogApi(lrHttp)
    _G._PLUGIN = {
        path = 'crush-catalog.lrplugin',
    }
    _G.import = function(name)
        assert.are.equal('LrHttp', name)
        return lrHttp
    end

    return assert(loadfile('crush-catalog.lrplugin/WildCatalogApi.lua'))()
end

describe('WildCatalogApi', function()
    it('connects the identify request builder to the Lightroom HTTP adapter', function()
        local capturedUrl
        local capturedParts
        local capturedHeaders
        local api = loadWildCatalogApi({
            postMultipart = function(url, parts, headers)
                capturedUrl = url
                capturedParts = parts
                capturedHeaders = headers

                return '{"results":[]}', {
                    { field = 'Content-Type', value = 'application/json' },
                }
            end,
        })

        local response = api.identify('/tmp/source.jpg', {
            baseUrl = 'http://localhost:8000/',
            originalFilename = 'source.jpg',
            commonNameLanguage = 'en-US',
            exifOverride = {
                captured_at = '2026-05-01T12:30:00Z',
                gps_coordinates = {
                    latitude = 29.573361,
                    longitude = -94.389507,
                },
            },
        })
        local payload = api.JSON:decode(capturedParts[2].value)

        assert.are.equal('http://localhost:8000/identify', capturedUrl)
        assert.are.equal('image', capturedParts[1].name)
        assert.are.equal('/tmp/source.jpg', capturedParts[1].filePath)
        assert.are.equal('source.jpg', capturedParts[1].fileName)
        assert.are.equal('payload', capturedParts[2].name)
        assert.are.equal('application/json', capturedParts[2].contentType)
        assert.is_true(payload.return_detected_images)
        assert.are.equal('source.jpg', payload.original_filename)
        assert.are.equal('en-US', payload.common_name_language)
        assert.are.equal('multipart/mixed', capturedHeaders[1].value)
        assert.same({}, response.result.results)
        assert.same({}, response.detectedImages)
    end)
end)
