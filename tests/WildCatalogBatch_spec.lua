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

    it('reports finalized counts from compact progress without intermediate results', function()
        local initial = progress({ asset('f1', 'preview') })
        initial.finalized_frame_count = 0
        local nextProgress = progress({ asset('f2', 'full') })
        nextProgress.finalized_frame_count = 1
        local options = fixture({
            reply(201, initial),
            reply(200, nextProgress),
            reply(200, progress({}, { result('f1'), result('f2') }, {}, 'completed')),
        })
        local counts = {}
        options.onProgress = function(done, total)
            assert.are.equal(2, total)
            counts[#counts + 1] = done
        end
        local final = Batch.run(manifest(), options)
        assert.same({ 0, 1 }, counts)
        assert.are.equal(2, #final.results)
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

    it('fetches only verified final review evidence before session deletion', function()
        local first = result('f1', 'identified')
        first.objects = { { bounding_box = { 1, 2, 3, 4 } } }
        first.coordinate_space = 'original:supplied_preview'
        local options, calls = fixture({
            reply(201, progress({}, { first, result('f2') }, {}, 'completed')),
        })
        local request = manifest()
        request.include_review_images = true
        local fetches = 0
        options.transport.get = function(url, headers)
            fetches = fetches + 1
            assert.are.equal(1, #calls)
            assert.are.equal('https://example.test/v1/batches/session-1/frames/f1'
                .. '/objects/1/review-image', url)
            assert.are.equal('_secret-1', headers[2].value)
            return {
                status = 200, body = 'jpeg bytes',
                normalizedHeaders = {
                    ['content-type'] = 'image/jpeg',
                    ['x-frame-id'] = 'f1',
                    ['x-object-index'] = '1',
                    ['x-coordinate-space'] = first.coordinate_space,
                    ['x-bounding-box'] = '[1,2,3,4]',
                },
            }
        end
        options.onCompleted = function(final, getCrop)
            local member = { frameIndex = 1, frame = final.results[1],
                objectIndex = 1, object = final.results[1].objects[1] }
            assert.are.equal('DELETE', calls[2].method)
            assert.are.equal('jpeg bytes', getCrop(member).bytes)
            assert.are.equal('jpeg bytes', getCrop(member).bytes)
            assert.are.equal(1, fetches)
            member.objectIndex = 2
            assert.is_nil(getCrop(member))
            return { approved = {} }
        end
        local response = Batch.run(request, options)
        assert.same({ approved = {} }, response.confirmations)
        assert.are.equal('DELETE', calls[2].method)
    end)

    it('reports missing or mismatched crops and accepts an already absent session', function()
        local first = result('f1', 'identified')
        first.objects = { { bounding_box = { 1, 2, 3, 4 } } }
        first.coordinate_space = 'original:supplied_preview'
        local options = fixture({
            reply(201, progress({}, { first, result('f2') }, {}, 'completed')),
        })
        local request = manifest()
        request.include_review_images = true
        local send = options.transport.request
        options.transport.request = function(method, ...)
            if method == 'DELETE' then
                return { status = 404, body = '{"error":{"code":"batch_not_found"}}' }
            end
            return send(method, ...)
        end
        options.transport.get = function()
            return {
                status = 200, body = 'jpeg bytes',
                normalizedHeaders = {
                    ['content-type'] = 'image/jpeg',
                    ['x-frame-id'] = 'f1',
                    ['x-object-index'] = '1',
                    ['x-coordinate-space'] = first.coordinate_space,
                    ['x-bounding-box'] = '[1,2,3,5]',
                },
            }
        end
        options.onCompleted = function(final, getCrop)
            local member = { frameIndex = 1, frame = final.results[1],
                objectIndex = 1, object = final.results[1].objects[1] }
            assert.is_nil(getCrop(member))
            return { approved = {} }
        end
        local response = Batch.run(request, options)
        assert.are.equal(1, response.missingReviewImages)
        assert.is_false(response.cleanupPending)
    end)

    it('releases the completed session if review is canceled', function()
        local options, calls = fixture({
            reply(201, progress({}, { result('f1'), result('f2') }, {}, 'completed')),
        })
        options.onCompleted = function()
            error('Batch canceled', 0)
        end
        assert.has_error(function()
            Batch.run(manifest(), options)
        end, 'Batch canceled')
        assert.are.equal('DELETE', calls[2].method)
    end)

    it('names oversized files when the server rejects the declared upload size', function()
        local request = manifest()
        request.frames[1].representations[2].byte_count = 120000000
        request.frames[2].representations[1].byte_count = 50000000
        local options = fixture({ reply(413, { error = {
            code = 'payload_too_large',
            message = 'Uploaded file exceeds the configured size limit of 100,000,000 bytes.',
        } }) })
        assert.has_error(function()
            Batch.run(request, options)
        end, 'Image too large for identification (HTTP 413): source.ARW; no results returned')
    end)

    it('reports an oversized requested asset and cleans up the session', function()
        local options, calls = fixture({
            reply(201, progress({ asset('f1', 'full') })),
            reply(413, {}),
        })
        assert.has_error(function()
            Batch.run(manifest(), options)
        end, 'Image too large for identification (HTTP 413): source.ARW; no results returned')
        assert.are.equal('DELETE', calls[#calls].method)
    end)

    it('reports only safe request stage and status when diagnostics are enabled', function()
        local options = fixture({ reply(400, { detail = 'private backend response' }) })
        options.diagnostics = true
        assert.has_error(function()
            Batch.run(manifest(), options)
        end, 'Batch identification failed at create (HTTP 400); no results returned')
    end)

end)


describe('WildCatalogBatch local transport', function()
    it('uses local registration then uploads once if the asset is requested again', function()
        local request = asset('f1', 'full')
        local options, calls = fixture({
            reply(201, progress({ request })),
            reply(200, progress()),
            reply(200, progress({ request })),
            reply(200, progress()),
            reply(200, progress({}, { result('f1'), result('f2') }, {}, 'completed')),
        })
        local attempts = 0
        options.localSession = function()
            return function(url, path, role, _, headers)
                attempts = attempts + 1
                assert.are.equal('full', role)
                return options.transport.request('POST', url .. '/local', path, headers)
            end
        end
        local final = Batch.run(manifest(), options)
        assert.are.equal(2, #final.results)
        assert.are.equal(1, attempts)
        assert.are.equal('POST', calls[2].method)
        assert.are.equal('PUT', calls[4].method)
    end)

    it('uploads after a rejected local registration', function()
        local options, calls = fixture({
            reply(201, progress({ asset('f1', 'full') })),
            reply(404, {}),
            reply(200, progress({}, { result('f1'), result('f2') }, {}, 'completed')),
        })
        options.localSession = function()
            return function(url, path, _role, _batchUrl, headers)
                return options.transport.request('POST', url .. '/local', path, headers)
            end
        end
        Batch.run(manifest(), options)
        assert.are.equal('PUT', calls[3].method)
    end)

    it('uploads if negotiation fails', function()
        local options, calls = fixture({
            reply(201, progress({ asset('f1', 'full') })),
            reply(200, progress({}, { result('f1'), result('f2') }, {}, 'completed')),
        })
        options.localSession = function() error('unavailable') end
        Batch.run(manifest(), options)
        assert.are.equal('PUT', calls[2].method)
    end)
end)


describe('WildCatalogBatch local embedded previews', function()
    it('avoids preview materialization when a RAW reference succeeds', function()
        local options, calls = fixture({
            reply(201, progress({ asset('f1', 'preview') })),
            reply(200, progress({}, { result('f1'), result('f2') }, {}, 'completed')),
        })
        options.resolveLocalSource = function()
            return '/photos/bird.ARW'
        end
        options.resolveAsset = function()
            error('must not generate a preview')
        end
        options.localSession = function()
            return function(url, path, role, _, headers)
                assert.are.equal('preview', role)
                assert.are.equal('/photos/bird.ARW', path)
                return options.transport.request('POST', url .. '/local', path, headers)
            end
        end
        Batch.run(manifest(), options)
        assert.are.equal(3, #calls)
        assert.are.equal('POST', calls[2].method)
    end)

    it('materializes the preview only when local registration is rejected', function()
        local options, calls = fixture({
            reply(201, progress({ asset('f1', 'preview') })),
            reply(404, {}),
            reply(200, progress({}, { result('f1'), result('f2') }, {}, 'completed')),
        })
        options.resolveLocalSource = function()
            return '/photos/bird.ARW'
        end
        options.localSession = function()
            return function(url, path, role, _, headers)
                assert.are.equal('preview', role)
                return options.transport.request('POST', url .. '/local', path, headers)
            end
        end
        Batch.run(manifest(), options)
        assert.are.equal('PUT', calls[3].method)
        assert.are.equal('/private/f1/preview', calls[3].body)
    end)
end)


describe('WildCatalogBatch Lightroom rendering', function()
    it('negotiates a distinct Lightroom-rendered representation and uploads only on request', function()
        local rendered = { frame_id = 'f1', representation_id = 'lightroom-render', role = 'rendered' }
        local options, calls = fixture({
            reply(201, progress({ asset('f1', 'full') })),
            reply(200, progress()),
            reply(200, progress({ rendered })),
            reply(200, progress()),
            reply(200, progress({}, { result('f1'), result('f2') }, {}, 'completed')),
        })
        local renders = 0
        options.transport.get = function(url)
            assert.is_truthy(url:match('/capabilities$'))
            return { status = 200, body = '{"lightroom_render_fallback":true}' }
        end
        options.resolveRendered = function(id)
            assert.are.equal('f1', id)
            renders = renders + 1
            return '/tmp/adobe.jpg'
        end
        local input = manifest()
        Batch.run(input, options)
        assert.are.equal(1, renders)
        assert.are.equal(2, #input.frames[1].representations)
        local wire = JSON:decode(calls[1].body)
        assert.are.equal('rendered', wire.frames[1].representations[3].role)
        assert.are.equal('/tmp/adobe.jpg', calls[4].body)
        assert.are.equal('PUT', calls[4].method)
    end)

    it('retains the older manifest when the server does not support rendering', function()
        local options, calls = fixture({
            reply(201, progress({}, { result('f1'), result('f2') }, {}, 'completed')),
        })
        options.transport.get = function() return { status = 404 } end
        options.resolveRendered = function() error('must not render') end
        Batch.run(manifest(), options)
        local wire = JSON:decode(calls[1].body)
        assert.are.equal(2, #wire.frames[1].representations)
    end)
end)
