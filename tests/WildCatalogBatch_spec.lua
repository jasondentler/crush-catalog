local Batch = assert(loadfile('crush-catalog.lrplugin/Core/WildCatalogBatch.lua'))()
local JSON = assert(loadfile('crush-catalog.lrplugin/JSON.lua'))()

local function manifest()
    return {
        schema_version = 1,
        execution_mode = 'burst',
        frames = {
            {
                frame_id = 'f1', source_id = 's1',
                representations = {
                    { representation_id = 'preview', role = 'preview', filename = 'preview.jpg' },
                    { representation_id = 'full', role = 'full', filename = 'source.ARW' },
                },
            },
            {
                frame_id = 'f2', source_id = 's2',
                representations = {
                    { representation_id = 'full', role = 'full', filename = 'second.ARW' },
                },
            },
        },
    }
end

local function asset(id, rep)
    return { frame_id = id, representation_id = rep, role = rep }
end

local function result(id, status)
    return { frame_id = id, status = status or 'no_detection', objects = {} }
end

local function progress(requests, results, provisional, status)
    return {
        batch_id = 'session-1', batch_token = '_secret-1',
        status = status or 'need_input',
        requested = requests or {},
        results = results or {},
        provisional_frame_ids = provisional or {},
    }
end

local function fixture(responses)
    local calls = {}
    local function send(method, url, body, headers)
        calls[#calls + 1] = { method = method, url = url, body = body, headers = headers }
        if method == 'DELETE' then
            return { status = 204 }
        end
        local response = table.remove(responses, 1)
        assert.is_table(response)
        return { status = response.status, body = JSON:encode(response.payload) }
    end
    local options = {
        baseUrl = 'https://example.test/identify/',
        json = JSON,
        resolveAsset = function(id, rep)
            if id == 'f2' then
                return nil
            end
            return '/private/' .. id .. '/' .. rep
        end,
        transport = {
            request = send,
            upload = function(url, path, headers)
                return send('PUT', url, path, headers)
            end,
        },
    }
    return options, calls
end

local function reply(status, payload)
    return { status = status, payload = payload }
end

describe('WildCatalogBatch', function()
    it('uploads only requested assets, resolves missing files and returns final results in order', function()
        local options, calls = fixture({
            reply(201, progress({ asset('f1', 'preview') })),
            reply(200, progress()),
            reply(200, progress({ asset('f1', 'full') }, { result('f1') }, { 'f1' })),
            reply(200, progress()),
            reply(200, progress({ asset('f2', 'full') }, { result('f1') })),
            reply(200, progress()),
            reply(200, progress({}, { result('f2', 'failed'), result('f1') }, {}, 'completed')),
        })

        local response = Batch.run(manifest(), options)
        assert.same({ result('f1'), result('f2', 'failed') }, response.results)
        assert.is_false(response.cleanupPending)
        assert.are.equal('https://example.test/v1/batches', calls[1].url)
        assert.are.equal('PUT', calls[2].method)
        assert.are.equal('/private/f1/preview', calls[2].body)
        assert.are.equal('_secret-1', calls[2].headers[3].value)
        assert.are.equal('application/octet-stream', calls[2].headers[2].value)
        assert.are.equal('/private/f1/full', calls[4].body)
        assert.are.equal('https://example.test/v1/batches/session-1/frames/f2'
            .. '/representations/full/unavailable', calls[6].url)
        assert.are.equal('DELETE', calls[8].method)
        assert.is_nil(calls[1].body:find('/private/', 1, true))
    end)

    it('rejects undeclared requests before reading an asset and cleans up', function()
        local options, calls = fixture({
            reply(201, progress({ asset('other', 'full') })),
        })
        options.resolveAsset = function()
            error('must not read')
        end
        assert.has_error(function()
            Batch.run(manifest(), options)
        end, 'Batch identification failed; no results returned')
        assert.are.equal(2, #calls)
        assert.are.equal('DELETE', calls[2].method)
    end)

    it('rejects provisional results even if server reports completion', function()
        local options, calls = fixture({
            reply(201, progress({}, { result('f1'), result('f2') }, { 'f1' }, 'completed')),
        })
        assert.has_error(function()
            Batch.run(manifest(), options)
        end, 'Batch identification failed; no results returned')
        assert.are.equal('DELETE', calls[2].method)
    end)

    it('rejects a repeated resolved asset request', function()
        local request = asset('f1', 'preview')
        local options, calls = fixture({
            reply(201, progress({ request })),
            reply(200, progress({ request })),
        })
        assert.has_error(function()
            Batch.run(manifest(), options)
        end, 'Batch identification failed; no results returned')
        assert.are.equal(3, #calls)
        assert.are.equal('DELETE', calls[3].method)
    end)

    it('cancels before upload and releases the session', function()
        local options, calls = fixture({
            reply(201, progress({ asset('f1', 'preview') })),
        })
        options.isCanceled = function()
            return #calls > 0
        end
        assert.has_error(function()
            Batch.run(manifest(), options)
        end, 'Batch canceled')
        assert.are.equal(2, #calls)
        assert.are.equal('DELETE', calls[2].method)
    end)

    it('returns no results after failed advance and releases the session', function()
        local options, calls = fixture({
            reply(201, progress()),
            reply(500, { detail = '_secret-1' }),
        })
        assert.has_error(function()
            Batch.run(manifest(), options)
        end, 'Batch identification failed; no results returned')
        assert.are.equal('DELETE', calls[3].method)
    end)

    it('rejects completion with a missing frame', function()
        local options, calls = fixture({
            reply(201, progress({}, { result('f1') }, {}, 'completed')),
        })
        assert.has_error(function()
            Batch.run(manifest(), options)
        end, 'Batch identification failed; no results returned')
        assert.are.equal('DELETE', calls[2].method)
    end)
end)
