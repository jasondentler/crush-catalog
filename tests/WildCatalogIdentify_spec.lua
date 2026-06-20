local JSON = assert(loadfile('crush-catalog.lrplugin/JSON.lua'))()
local HttpLogic = assert(loadfile('crush-catalog.lrplugin/Core/HttpLogic.lua'))()
local Identify = assert(loadfile('crush-catalog.lrplugin/Core/WildCatalogIdentify.lua'))()

describe('WildCatalogIdentify', function()
    it('builds the identify multipart request contract', function()
        local request = Identify.buildRequest('/tmp/source.jpg', {
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
        }, JSON)
        local payload = JSON:decode(request.parts[2].value)

        assert.are.equal('http://localhost:8000/identify', request.url)
        assert.are.equal('image', request.parts[1].name)
        assert.are.equal('/tmp/source.jpg', request.parts[1].filePath)
        assert.are.equal('source.jpg', request.parts[1].fileName)
        assert.are.equal('payload', request.parts[2].name)
        assert.are.equal('application/json', request.parts[2].contentType)
        assert.is_true(payload.return_detected_images)
        assert.are.equal('source.jpg', payload.original_filename)
        assert.are.equal('en-US', payload.common_name_language)
        assert.are.equal('multipart/mixed', request.headers[1].value)
    end)

    it('normalizes base URLs with or without trailing slashes', function()
        local withoutTrailingSlash = Identify.buildRequest('/tmp/source.jpg', {
            baseUrl = 'http://localhost:8000',
        }, JSON)
        local withTrailingSlash = Identify.buildRequest('/tmp/source.jpg', {
            baseUrl = 'http://localhost:8000/',
        }, JSON)

        assert.are.equal('http://localhost:8000/identify', withoutTrailingSlash.url)
        assert.are.equal('http://localhost:8000/identify', withTrailingSlash.url)
    end)

    it('can omit detected images from the response', function()
        local request = Identify.buildRequest('/tmp/source.jpg', {
            return_detected_images = false,
        }, JSON)
        local payload = JSON:decode(request.parts[2].value)

        assert.is_false(payload.return_detected_images)
    end)

    it('normalizes legacy backend URLs that include the identify endpoint', function()
        local request = Identify.buildRequest('/tmp/source.jpg', {
            baseUrl = 'http://localhost:8000/identify/',
        }, JSON)

        assert.are.equal('http://localhost:8000/identify', request.url)
    end)

    it('parses multipart identify responses with JPEG detections', function()
        local body = table.concat({
            '--abc',
            'Content-Type: application/json',
            '',
            '{"results":[]}',
            '--abc',
            'Content-Type: image/jpeg',
            'Content-Disposition: attachment; filename="detected-1.jpg"',
            '',
            'JPEGDATA',
            '--abc--',
            '',
        }, '\r\n')
        local response = Identify.parseResponse({
            body = body,
            headers = {
                { field = 'Content-Type', value = 'multipart/mixed; boundary=abc' },
            },
            normalizedHeaders = {
                ['content-type'] = 'multipart/mixed; boundary=abc',
            },
        }, JSON, HttpLogic)

        assert.same({}, response.result.results)
        assert.are.equal(1, #response.detectedImages)
        assert.are.equal('JPEGDATA', response.detectedImages[1].bytes)
        assert.are.equal('detected-1.jpg', response.detectedImages[1].filename)
    end)

    it('accepts an application/json response without detected images', function()
        local response = Identify.parseResponse({
            body = '{"results":[]}',
            headers = {
                { field = 'Content-Type', value = 'application/json' },
            },
            normalizedHeaders = {
                ['content-type'] = 'application/json',
            },
        }, JSON, HttpLogic)

        assert.same({}, response.result.results)
        assert.same({}, response.detectedImages)
    end)
end)
