-- Automatic Lightroom integration. Unsupported platforms use HTTP uploads.
local function pluginPath()
    if _PLUGIN and _PLUGIN.path then return _PLUGIN.path end
    return debug.getinfo(1, 'S').source:match('^@(.+)/[^/]+$') or '.'
end

local Local = assert(loadfile(pluginPath() .. '/Core/LocalTransport.lua'))()
local Adapter = {}

local function hex(bytes)
    return (bytes:gsub('.', function(char) return string.format('%02x', char:byte()) end))
end

function Adapter.session(options)
    if not Local.loopbackUrl(options.baseUrl) then return nil end
    local files = import 'LrFileUtils'
    local tasks = import 'LrTasks'
    local function privateDirectory(path)
        -- Verify the server's rendezvous belongs to this OS user. Only a
        -- constrained, ASCII directory name may enter the shell command.
        if not path:match('^/tmp/wildcatalog%-local%-v2%-[a-f0-9]+%-[a-z0-9_]+$')
            or files.exists(path) ~= 'directory' then return false end
        local command = 'test ! -L ' .. path
            .. ' && test "$(/usr/bin/stat -f %u:%Lp ' .. path .. ')" = "$(/usr/bin/id -u):700"'
        return tasks.execute(command) == 0
    end
    local function remove(path)
        if not files.exists(path) then return true end
        return files.delete(path) == true or not files.exists(path)
    end
    local function writeTicket(directory, content)
        local random = io.open('/dev/urandom', 'rb')
        if not random then return nil end
        local bytes = random:read(16)
        random:close()
        if not bytes or #bytes ~= 16 then return nil end
        local id = hex(bytes)
        local path = directory .. '/' .. id .. '.ticket'
        if files.exists(path) then return nil end
        local file = io.open(path, 'wb')
        if not file then return nil end
        local written = file:write(content)
        local closed = file:close()
        if not written or not closed then remove(path); return nil end
        return path, id
    end
    return Local.automaticSession({
        baseUrl = options.baseUrl, json = options.json, transport = options.transport,
        protect = options.protect, writeTicket = writeTicket, removeTicket = remove,
        isDirectory = privateDirectory,
    })
end

return Adapter
