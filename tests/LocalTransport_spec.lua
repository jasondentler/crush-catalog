local Local = assert(loadfile('crush-catalog.lrplugin/Core/LocalTransport.lua'))()
local JSON = assert(loadfile('crush-catalog.lrplugin/JSON.lua'))()

local HASH = string.rep('a', 64)
local KEY = string.rep('b', 64)

describe('LocalTransport', function()
    it('restricts cleartext access to exact loopback hosts', function()
        assert.is_true(Local.trustedUrl('http://localhost:8000'))
        assert.is_true(Local.trustedUrl('http://127.0.0.1:8000'))
        assert.is_true(Local.trustedUrl('https://server.example'))
        for _, url in ipairs({
            'http://localhost.example:8000', 'http://server.example',
            'https://user@server.example', 'https://server.example?x=1',
            'https://server.example\\evil', 'file:///tmp',
        }) do
            assert.is_false(Local.trustedUrl(url))
        end
    end)

    it('maps only contained root-relative file paths', function()
        assert.are.equal('a/b.ARW', Local.relative('/photos/', '/photos/a/b.ARW'))
        for _, path in ipairs({
            '/photos2/a.ARW', '/photos/../a.ARW', '/photos/a//b.ARW',
            '/photos/a\\b.ARW', '/photos/a:b.ARW', '/photos/',
        }) do
            assert.is_nil(Local.relative('/photos', path))
        end
    end)

    it('samples sorted unique offsets and handles small files', function()
        local path = os.tmpname()
        local file = assert(io.open(path, 'wb'))
        local data = string.rep('a', 65536) .. string.rep('b', 65536)
            .. string.rep('c', 65536)
        file:write(data)
        file:close()
        local size, hash = Local.sample(path, function(bytes)
            assert.are.equal(data, bytes)
            return HASH
        end)
        os.remove(path)
        assert.are.equal(#data, size)
        assert.are.equal(HASH, hash)
    end)

    local function fixture(path, proof, capabilityStatus, embedded)
        local calls = {}
        local root = path:match('^(.+)/[^/]+$')
        local options = {
            baseUrl = 'http://localhost:8000', base = 'http://localhost:8000/v1/batches',
            key = KEY, roots = { photos = root }, json = JSON,
            sha256 = function() return HASH end,
            createProbe = function()
                calls[#calls + 1] = 'create'
                return 'probe', string.rep('c', 32), 'secret'
            end,
            removeProbe = function()
                calls[#calls + 1] = 'remove'
                return true
            end,
            transport = {
                get = function(_, headers)
                    assert.are.equal(KEY, headers[2].value)
                    calls[#calls + 1] = 'capabilities'
                    return { status = capabilityStatus or 200, body = JSON:encode({
                        local_file_transport = true, local_verification_version = 1,
                        local_embedded_previews = embedded == true,
                        root_ids = { 'photos' },
                    }) }
                end,
                request = function(method, url, body, headers)
                    assert.are.equal('POST', method)
                    assert.are.equal(KEY, headers[#headers].value)
                    local payload = JSON:decode(body)
                    assert.are.equal('photos', payload.root_id)
                    if url:match('/probe$') then
                        calls[#calls + 1] = 'probe'
                        assert.is_nil(body:find('secret', 1, true))
                        assert.are.equal(string.rep('c', 32), payload.challenge_id)
                        return { status = 200, body = JSON:encode({ sha256 = proof }) }
                    end
                    calls[#calls + 1] = 'local'
                    assert.are.equal(path:match('[^/]+$'), payload.relative_path)
                    assert.are.equal(3, payload.byte_count)
                    assert.are.equal(HASH, payload.sample_sha256)
                    assert.are.equal(embedded and true or nil, payload.embedded_preview)
                    return { status = 200 }
                end,
            },
        }
        return options, calls
    end

    it('verifies once per root and never registers temporary previews', function()
        local path = os.tmpname()
        local file = assert(io.open(path, 'wb'))
        file:write('abc')
        file:close()
        local options, calls = fixture(path, HASH)
        local session = Local.session(options)
        assert.is_nil(session('/asset', path, 'preview', '/batch', {}))
        assert.are.equal(200, session('/asset', path, 'full', '/batch', {}).status)
        assert.are.equal(200, session('/asset2', path, 'full', '/batch', {}).status)
        os.remove(path)
        assert.same({ 'capabilities', 'create', 'probe', 'remove', 'local', 'local' }, calls)
    end)

    it('registers a RAW-backed preview only when the server advertises support', function()
        local temporary = os.tmpname()
        os.remove(temporary)
        local path = temporary .. '.ARW'
        local file = assert(io.open(path, 'wb'))
        file:write('abc')
        file:close()
        local options, calls = fixture(path, HASH, 200, true)
        local session = Local.session(options)
        assert.are.equal(200, session('/asset', path, 'preview', '/batch', {}).status)
        os.remove(path)
        assert.same({ 'capabilities', 'create', 'probe', 'remove', 'local' }, calls)
    end)

    it('fails closed on wrong proof and older servers', function()
        local path = '/photos/source.ARW'
        local options, calls = fixture(path, string.rep('0', 64))
        local session = Local.session(options)
        assert.is_nil(session('/asset', path, 'full', '/batch', {}))
        assert.is_nil(session('/asset', path, 'full', '/batch', {}))
        assert.same({ 'capabilities', 'create', 'probe', 'remove' }, calls)
        local old = fixture(path, HASH, 404)
        assert.is_nil(Local.session(old))
        options.baseUrl = 'http://remote.example'
        assert.is_nil(Local.session(options))
    end)
end)


describe('Automatic local transport', function()
    local function fixture(directoryAvailable, directoryId)
        local calls = {}
        local path = os.tmpname()
        local file = assert(io.open(path, 'wb'))
        file:write('abc')
        file:close()
        local name = directoryId or ('wildcatalog-local-v2-' .. string.rep('a', 32) .. '-abc12345')
        local url = '/batch/frames/a/representations/full'
        local options = {
            baseUrl = 'http://127.0.0.1:8000', json = JSON,
            isDirectory = function(directory)
                assert.are.equal('/tmp/' .. name, directory)
                return directoryAvailable
            end,
            writeTicket = function(directory, content)
                local header, samples = content:match('^([^\n]+)\n(.*)$')
                assert.are.equal('abc', samples)
                local data = JSON:decode(header)
                assert.are.equal(path, data.path)
                assert.are.equal('a', data.frame_id)
                assert.are.equal('full', data.representation_id)
                assert.are.equal(3, data.byte_count)
                assert.is_false(data.embedded_preview)
                calls[#calls + 1] = 'write'
                return directory .. '/ticket', string.rep('b', 32)
            end,
            removeTicket = function()
                calls[#calls + 1] = 'remove'
            end,
            transport = {
                request = function(method, address, body)
                    assert.are.equal('POST', method)
                    if address == '/batch/local/rendezvous' then
                        calls[#calls + 1] = 'rendezvous'
                        return { status = 200, body = JSON:encode({ directory_id = name }) }
                    end
                    assert.are.equal(url .. '/local-ticket', address)
                    assert.same({ ticket_id = string.rep('b', 32) }, JSON:decode(body))
                    calls[#calls + 1] = 'register'
                    return { status = 200 }
                end,
            },
        }
        return options, calls, path, url
    end

    it('uses one private rendezvous per batch without settings or a transport key', function()
        local options, calls, path, url = fixture(true)
        local session = Local.automaticSession(options)
        assert.are.equal(200, session(url, path, 'full', '/batch', {}).status)
        assert.are.equal(200, session(url, path, 'full', '/batch', {}).status)
        os.remove(path)
        assert.same({ 'rendezvous', 'write', 'register', 'remove',
            'write', 'register', 'remove' }, calls)
    end)

    it('falls back if the private directory is missing or belongs to another user', function()
        local options, calls, path, url = fixture(false)
        local session = Local.automaticSession(options)
        assert.is_nil(session(url, path, 'full', '/batch', {}))
        assert.is_nil(session(url, path, 'full', '/batch', {}))
        os.remove(path)
        assert.same({ 'rendezvous' }, calls)
    end)

    it('rejects arbitrary directory names and never attempts remote direct access', function()
        local options, calls, path, url = fixture(true, '../../photos')
        local session = Local.automaticSession(options)
        assert.is_nil(session(url, path, 'full', '/batch', {}))
        options.baseUrl = 'https://server.example'
        assert.is_nil(Local.automaticSession(options))
        os.remove(path)
        assert.same({ 'rendezvous' }, calls)
    end)
end)
