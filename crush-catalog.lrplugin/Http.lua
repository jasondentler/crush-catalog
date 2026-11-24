local LrHttp = import 'LrHttp'
local LrFileUtils = import 'LrFileUtils'

local function pluginPath()
    if _PLUGIN ~= nil and _PLUGIN.path ~= nil then
        return _PLUGIN.path
    end

    local source = debug.getinfo(1, 'S').source
    return source:match('^@(.+)/[^/]+$') or '.'
end

local HttpLogic = assert(loadfile(pluginPath() .. '/Core/HttpLogic.lua'))()

local Http = {}

local function populateFileSizes(parts)
    for _, part in ipairs(parts or {}) do
        if part.filePath ~= nil and part.fileSize == nil then
            local attributes = LrFileUtils.fileAttributes(part.filePath)
            local fileSize = attributes and attributes.fileSize

            if fileSize == nil then
                error('Could not determine file size for multipart upload: '
                    .. tostring(part.filePath))
            end

            part.fileSize = fileSize
        end
    end
end

function Http.postMultipart(url, parts, headers)
    populateFileSizes(parts)
    local body, responseHeaders = LrHttp.postMultipart(url, parts, headers)

    return {
        body = body,
        headers = responseHeaders,
        normalizedHeaders = HttpLogic.normalizeHeaders(responseHeaders),
    }
end

function Http.get(url, headers)
    local body, responseHeaders = LrHttp.get(url, headers)

    return {
        body = body,
        headers = responseHeaders,
        normalizedHeaders = HttpLogic.normalizeHeaders(responseHeaders),
    }
end

function Http.request(method, url, body, headers, totalSize)
    local responseBody, responseHeaders = LrHttp.post(
        url, body, headers, method, 300, totalSize
    )
    return {
        body = responseBody,
        status = responseHeaders and tonumber(responseHeaders.status),
    }
end

function Http.upload(url, path, headers, protect)
    local file = io.open(path, 'rb')
    if not file then
        error('Unable to open requested representation', 0)
    end
    local ok, result = protect(function()
        local size = file:seek('end')
        if not size or size <= 0 or not file:seek('set', 0) then
            error('Unable to determine representation size', 0)
        end
        return Http.request('PUT', url, function()
            return file:read(256 * 1024)
        end, headers, size)
    end)
    file:close()
    if not ok then
        error('Representation upload failed', 0)
    end
    return result
end

Http.logic = HttpLogic

return Http
