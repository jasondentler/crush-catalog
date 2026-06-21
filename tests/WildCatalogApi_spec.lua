local function loadWildCatalogApi(lrHttp, prefs)
    _G._PLUGIN = {
        path = 'crush-catalog.lrplugin',
    }
    _G.import = function(name)
        if name == 'LrHttp' then
            return lrHttp
        elseif name == 'LrFileUtils' then
            return {
                fileAttributes = function()
                    return { fileSize = 12345 }
                end,
            }
        elseif name == 'LrPrefs' then
            return {
                prefsForPlugin = function()
                    return prefs or {}
                end,
            }
        end

        error('Unexpected Lightroom import: ' .. tostring(name))
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
        assert.are.equal(12345, capturedParts[1].fileSize)
        assert.are.equal('payload', capturedParts[2].name)
        assert.are.equal('application/json', capturedParts[2].contentType)
        assert.is_true(payload.return_detected_images)
        assert.are.equal('source.jpg', payload.original_filename)
        assert.are.equal('en-US', payload.common_name_language)
        assert.are.equal('multipart/mixed', capturedHeaders[1].value)
        assert.same({}, response.result.results)
        assert.same({}, response.detectedImages)
    end)

    it('uses the configured Lightroom backend URL when no base URL is provided', function()
        local capturedUrl
        local api = loadWildCatalogApi({
            postMultipart = function(url)
                capturedUrl = url

                return '{"results":[]}', {
                    { field = 'Content-Type', value = 'application/json' },
                }
            end,
        }, {
            backendUrl = 'http://example.test:9000/',
        })

        api.identify('/tmp/source.jpg')

        assert.are.equal('http://example.test:9000/identify', capturedUrl)
    end)
end)
