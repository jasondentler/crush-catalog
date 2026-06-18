local LrHttp = import 'LrHttp'

local function pluginPath()
    if _PLUGIN ~= nil and _PLUGIN.path ~= nil then
        return _PLUGIN.path
    end

    local source = debug.getinfo(1, 'S').source
    return source:match('^@(.+)/[^/]+$') or '.'
end

local HttpLogic = assert(loadfile(pluginPath() .. '/Core/HttpLogic.lua'))()

local Http = {}

function Http.postMultipart(url, parts, headers)
    local body, responseHeaders = LrHttp.postMultipart(url, parts, headers)

    return {
        body = body,
        headers = responseHeaders,
        normalizedHeaders = HttpLogic.normalizeHeaders(responseHeaders),
    }
end

Http.logic = HttpLogic

return Http
