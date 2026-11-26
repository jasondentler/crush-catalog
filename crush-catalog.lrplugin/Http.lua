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

function Http.upload(url, path, headers, protect, isCanceled)
    local file = io.open(path, 'rb')
    if not file then
        error('Unable to open requested representation', 0)
    end
    local ok, result = protect(function()
        local size = file:seek('end')
        if not size or size <= 0 or not file:seek('set', 0) then
            error('Unable to determine representation size', 0)
        end
        -- Lightroom's totalSize argument describes the callback, but the
        -- HTTP request also needs an unambiguous wire-level body length.
        local uploadHeaders = {}
        for _, header in ipairs(headers or {}) do
            local name = header.field:lower()
            if name ~= 'content-length' and name ~= 'transfer-encoding' then
                uploadHeaders[#uploadHeaders + 1] = header
            end
        end
        uploadHeaders[#uploadHeaders + 1] = { field = 'Content-Length', value = tostring(size) }
        local sent = 0
        local interrupted = false
        local response = Http.request('PUT', url, function()
            -- The SDK byte getter must not yield. End the body on cancellation.
            if isCanceled and isCanceled() then
                interrupted = true
                return nil
            end
            if sent == size then return nil end
            local chunk = file:read(math.min(256 * 1024, size - sent))
            if not chunk or #chunk == 0 then error('Representation ended prematurely', 0) end
            sent = sent + #chunk
            return chunk
        end, uploadHeaders, size)
        if interrupted or (isCanceled and isCanceled()) then error('Batch canceled', 0) end
        if response.status == 200 and sent ~= size then
            error('Incomplete representation upload', 0)
        end
        return response
    end)
    file:close()
    if not ok then
        if result == 'Batch canceled' or (isCanceled and isCanceled()) then
            error('Batch canceled', 0)
        end
        error('Representation upload failed', 0)
    end
    return result
end

Http.logic = HttpLogic

return Http
