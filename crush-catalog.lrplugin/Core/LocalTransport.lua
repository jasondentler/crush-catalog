-- Automatic same-user transport plus legacy shared-root compatibility. No Lightroom dependencies.
local Local = {}
local SAMPLE = 65536

local function digest(value)
    return type(value) == 'string' and #value == 64 and value:match('^[0-9a-f]+$')
end

function Local.trustedUrl(url)
    -- A user-configured endpoint is trusted only with explicit opt-in and a
    -- protected channel. Plain HTTP is restricted to exact loopback hosts.
    if type(url) ~= 'string' or url:find('[%s?#@\\]') then return false end
    local scheme, authority = url:match('^(https?)://([^/]+)')
    if scheme == 'https' then
        return authority ~= nil and (authority:match('^[%w.%-]+:%d+$') ~= nil
            or authority:match('^[%w.%-]+$') ~= nil)
    end
    if scheme ~= 'http' then return false end
    local host = authority:match('^([a-zA-Z0-9.]+):%d+$') or authority
    return host == 'localhost' or host == '127.0.0.1'
end

function Local.relative(root, path)
    if type(root) ~= 'string' or type(path) ~= 'string' then return nil end
    root = root:gsub('/+$', '')
    if root == '' or root:sub(1, 1) ~= '/' then return nil end
    if path:sub(1, #root + 1) ~= root .. '/' then return nil end
    local relative = path:sub(#root + 2)
    if relative == '' or relative:find('[:\\%z]') or relative:find('//', 1, true)
        or relative:sub(-1) == '/' then return nil end
    for part in relative:gmatch('[^/]+') do
        if part == '.' or part == '..' then return nil end
    end
    return relative
end

function Local.readSamples(path)
    local file = io.open(path, 'rb')
    if not file then return nil end
    local ok, size, hash = pcall(function()
        local count = file:seek('end')
        if not count or count <= 0 then return nil end
        local offsets = { 0, math.max(0, math.floor((count - SAMPLE) / 2)),
            math.max(0, count - SAMPLE) }
        local chunks, previous = {}, nil
        for _, offset in ipairs(offsets) do
            if offset ~= previous then
                local length = math.min(SAMPLE, count - offset)
                if not file:seek('set', offset) then return nil end
                local bytes = file:read(length)
                if not bytes or #bytes ~= length then return nil end
                chunks[#chunks + 1] = bytes
                previous = offset
            end
        end
        return count, table.concat(chunks)
    end)
    file:close()
    if ok and size and type(hash) == 'string' then return size, hash end
end

function Local.sample(path, sha256)
    local size, samples = Local.readSamples(path)
    if not size then return nil end
    local ok, hash = pcall(sha256, samples)
    if ok and digest(hash) then return size, hash end
end

function Local.loopbackUrl(url)
    if not Local.trustedUrl(url) then return false end
    local authority = url:match('^https?://([^/]+)')
    local host = authority:match('^([a-zA-Z0-9.]+):%d+$') or authority
    return host == 'localhost' or host == '127.0.0.1'
end

-- The server chooses a private batch-local directory; the client may only
-- use a constrained name under the OS-local /tmp namespace. No source path,
-- sample, or filesystem credential is sent over HTTP.
function Local.automaticSession(options)
    if not Local.loopbackUrl(options.baseUrl) then return nil end
    local protect = options.protect or pcall
    local directory
    local attempted = false
    local function decode(response)
        if type(response) ~= 'table' or response.status ~= 200 then return nil end
        local ok, result = pcall(options.json.decode, options.json, response.body)
        if ok and type(result) == 'table' then return result end
    end
    return function(url, path, role, batchUrl, headers)
        if type(path) ~= 'string' or path:sub(1, 1) ~= '/' then return nil end
        local embedded = role == 'preview'
        if role ~= 'full' and (not embedded or not path:lower():match('%.arw$')) then
            return nil
        end
        if not attempted then
            attempted = true
            local result = decode(options.transport.request(
                'POST', batchUrl .. '/local/rendezvous', '', headers))
            local name = result and result.directory_id
            if type(name) == 'string' then
                local nonce, suffix = name:match('^wildcatalog%-local%-v2%-([a-f0-9]+)%-([a-z0-9_]+)$')
                if nonce and #nonce == 32 and suffix and #suffix == 8 then
                    local candidate = '/tmp/' .. name
                    if options.isDirectory(candidate) then directory = candidate end
                end
            end
        end
        if not directory then return nil end
        local frame, rep = url:match('/frames/([%w_.%-]+)/representations/([%w_.%-]+)$')
        if not frame or not rep then return nil end
        local size, samples = Local.readSamples(path)
        if not size then return nil end
        local header = options.json:encode({
            frame_id = frame, representation_id = rep, path = path,
            byte_count = size, embedded_preview = embedded,
        })
        if #header > 8192 or header:find('\n', 1, true) then return nil end
        local ticket, ticketId = options.writeTicket(directory, header .. '\n' .. samples)
        if not ticket then return nil end
        local ok, response = protect(function()
            return options.transport.request('POST', url .. '/local-ticket',
                options.json:encode({ ticket_id = ticketId }), headers)
        end)
        options.removeTicket(ticket)
        if ok then return response end
    end
end

local function authenticated(headers, key)
    local result = {}
    for _, header in ipairs(headers) do result[#result + 1] = header end
    result[#result + 1] = { field = 'X-Local-Transport-Token', value = key }
    return result
end

-- The adapter supplies a secure nonce, owned probe creation/removal, and SHA-256.
-- No server-supplied paths or URLs are followed.
function Local.session(options)
    if not Local.trustedUrl(options.baseUrl) or type(options.key) ~= 'string'
        or #options.key < 32 or #options.key > 256
        or not options.key:match('^[a-zA-Z0-9_%-]+$')
        or type(options.roots) ~= 'table' then return nil end
    local protect = options.protect or pcall
    local function payload(response)
        if type(response) ~= 'table' or response.status ~= 200 then return nil end
        local ok, result = pcall(options.json.decode, options.json, response.body)
        if ok and type(result) == 'table' then return result end
    end
    local ok, response = protect(options.transport.get, options.base .. '/capabilities',
        authenticated({ { field = 'Accept', value = 'application/json' } }, options.key))
    local capabilities = ok and payload(response)
    if not capabilities or capabilities.local_file_transport ~= true
        or capabilities.local_verification_version ~= 1
        or type(capabilities.root_ids) ~= 'table' then return nil end
    local roots = {}
    for _, alias in ipairs(capabilities.root_ids) do
        local root = type(alias) == 'string' and options.roots[alias]
        if type(alias) == 'string' and #alias <= 64
            and alias:match('^[a-zA-Z0-9][a-zA-Z0-9_.%-]*$')
            and type(root) == 'string' and root:sub(1, 1) == '/' then
            roots[#roots + 1] = { alias = alias, path = root }
        end
    end
    table.sort(roots, function(a, b) return #a.path > #b.path end)
    local verified = {}
    return function(url, path, role, batchUrl, headers)
        local embedded = role == 'preview'
        if role ~= 'full' and (not embedded or capabilities.local_embedded_previews ~= true
            or type(path) ~= 'string' or not path:lower():match('%.arw$')) then return nil end
        for _, root in ipairs(roots) do
            local relative = Local.relative(root.path, path)
            if relative then
                if verified[root.alias] == nil then
                    verified[root.alias] = false
                    local probe, id, nonce = options.createProbe(root.path)
                    if probe then
                        local success, proof = protect(function()
                            local hash = options.sha256(nonce)
                            if not digest(hash) then return nil end
                            local result = payload(options.transport.request(
                                'POST', batchUrl .. '/local/probe',
                                options.json:encode({ root_id = root.alias, challenge_id = id }),
                                authenticated(headers, options.key)))
                            return result and result.sha256 == hash
                        end)
                        local removed = options.removeProbe(probe)
                        verified[root.alias] = success and proof == true and removed == true
                    end
                end
                if verified[root.alias] then
                    local size, hash = Local.sample(path, options.sha256)
                    if size then
                        return options.transport.request('POST', url .. '/local',
                            options.json:encode({
                                root_id = root.alias, relative_path = relative,
                                byte_count = size, sample_sha256 = hash,
                                embedded_preview = embedded and true or nil,
                            }), authenticated(headers, options.key))
                    end
                end
            end
        end
    end
end

return Local
