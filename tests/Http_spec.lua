local function loadHttp(lrHttp, lrFileUtils)
    _G._PLUGIN = {
        path = 'crush-catalog.lrplugin',
    }
    _G.import = function(name)
        if name == 'LrHttp' then
            return lrHttp or {}
        elseif name == 'LrFileUtils' then
            return lrFileUtils or {}
        end

        error('Unexpected Lightroom import: ' .. tostring(name))
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

    it('adds the file size required by Lightroom multipart uploads', function()
        local capturedParts
        local Http = loadHttp({
            postMultipart = function(_, parts)
                capturedParts = parts
                return 'body', {}
            end,
        }, {
            fileAttributes = function(path)
                assert.are.equal('/tmp/source.jpg', path)
                return { fileSize = 12345 }
            end,
        })

        Http.postMultipart('http://example.test/identify', {
            { filePath = '/tmp/source.jpg' },
            { value = 'payload' },
        }, {})

        assert.are.equal(12345, capturedParts[1].fileSize)
        assert.is_nil(capturedParts[2].fileSize)
    end)

    it('wraps LrHttp.get with normalized headers', function()
        local capturedUrl
        local capturedHeaders
        local Http = loadHttp({
            get = function(url, headers)
                capturedUrl = url
                capturedHeaders = headers

                return 'body', {
                    { field = 'Content-Type', value = 'application/json' },
                }
            end,
        })

        local response = Http.get('http://example.test/search', { 'header' })

        assert.are.equal('http://example.test/search', capturedUrl)
        assert.same({ 'header' }, capturedHeaders)
        assert.are.equal('body', response.body)
        assert.are.equal('application/json', response.normalizedHeaders['content-type'])
    end)

    it('preserves a file size already provided by the caller', function()
        local Http = loadHttp({
            postMultipart = function()
                return 'body', {}
            end,
        }, {
            fileAttributes = function()
                error('fileAttributes should not be called')
            end,
        })
        local parts = { { filePath = '/tmp/source.jpg', fileSize = 42 } }

        Http.postMultipart('http://example.test/identify', parts, {})

        assert.are.equal(42, parts[1].fileSize)
    end)

    it('reports the file path when its size cannot be determined', function()
        local Http = loadHttp({}, {
            fileAttributes = function()
                return nil
            end,
        })

        assert.has_error(function()
            Http.postMultipart('http://example.test/identify', {
                { filePath = '/tmp/missing.jpg' },
            }, {})
        end, 'Could not determine file size for multipart upload: /tmp/missing.jpg')
    end)
end)
