local HttpLogic = assert(loadfile('crush-catalog.lrplugin/Core/HttpLogic.lua'))()

describe('HttpLogic', function()
    it('normalizes Lightroom-style response headers', function()
        local headers = HttpLogic.normalizeHeaders({
            { field = 'Content-Type', value = 'multipart/mixed; boundary=abc' },
            { name = 'X-Request-Id', value = 'request-id' },
        })

        assert.are.equal('multipart/mixed; boundary=abc', headers['content-type'])
        assert.are.equal('request-id', headers['x-request-id'])
    end)

    it('parses multipart/mixed JSON and JPEG parts', function()
        local body = table.concat({
            '--abc',
            'Content-Type: application/json',
            '',
            '{"results":[]}',
            '--abc',
            'Content-Type: image/jpeg',
            'Content-Disposition: attachment; filename="crop.jpg"',
            '',
            'JPEGDATA',
            '--abc--',
            '',
        }, '\r\n')

        local parts = HttpLogic.parseMultipartMixed(body, 'multipart/mixed; boundary=abc')

        assert.are.equal(2, #parts)
        assert.are.equal('application/json', parts[1].headers['content-type'])
        assert.are.equal('{"results":[]}', parts[1].body)
        assert.are.equal('image/jpeg', parts[2].headers['content-type'])
        assert.are.equal('JPEGDATA', parts[2].body)
        assert.are.equal(
            'crop.jpg',
            HttpLogic.filenameFromContentDisposition(parts[2].headers['content-disposition'])
        )
    end)
end)
