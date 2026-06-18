local HttpLogic = {}

local function getBoundary(contentType)
    if contentType == nil then
        return nil
    end

    return contentType:match('boundary="?([^";]+)"?')
end

local function trimLeadingNewline(value)
    if value:sub(1, 2) == '\r\n' then
        return value:sub(3)
    elseif value:sub(1, 1) == '\n' then
        return value:sub(2)
    end

    return value
end

local function trimTerminatingNewline(value)
    if value:sub(-2) == '\r\n' then
        return value:sub(1, -3)
    elseif value:sub(-1) == '\n' then
        return value:sub(1, -2)
    end

    return value
end

local function parsePart(rawPart)
    rawPart = trimLeadingNewline(rawPart)

    local headerEndStart, headerEndFinish = rawPart:find('\r\n\r\n', 1, true)

    if headerEndStart == nil then
        headerEndStart, headerEndFinish = rawPart:find('\n\n', 1, true)
    end

    if headerEndStart == nil then
        return nil
    end

    local rawHeaders = rawPart:sub(1, headerEndStart - 1)
    local body = trimTerminatingNewline(rawPart:sub(headerEndFinish + 1))
    local headers = {}

    for line in rawHeaders:gmatch('[^\r\n]+') do
        local name, value = line:match('^([^:]+):%s*(.*)$')
        if name ~= nil then
            headers[name:lower()] = value
        end
    end

    return {
        headers = headers,
        body = body,
    }
end

function HttpLogic.normalizeHeaders(headers)
    local normalized = {}

    if type(headers) ~= 'table' then
        return normalized
    end

    for key, value in pairs(headers) do
        if type(key) == 'string' then
            normalized[key:lower()] = value
        elseif type(value) == 'table' then
            local name = value.name or value.field

            if name ~= nil then
                normalized[tostring(name):lower()] = value.value
            end
        end
    end

    return normalized
end

function HttpLogic.parseMultipartMixed(body, contentType)
    local boundary = getBoundary(contentType)

    if boundary == nil then
        error('Missing multipart boundary in Content-Type: ' .. tostring(contentType))
    end

    local marker = '--' .. boundary
    local parts = {}
    local position = 1

    while true do
        local markerStart, markerEnd = body:find(marker, position, true)
        if markerStart == nil then
            break
        end

        if body:sub(markerEnd + 1, markerEnd + 2) == '--' then
            break
        end

        local nextMarkerStart = body:find(marker, markerEnd + 1, true)
        if nextMarkerStart == nil then
            break
        end

        local part = parsePart(body:sub(markerEnd + 1, nextMarkerStart - 1))

        if part ~= nil then
            parts[#parts + 1] = part
        end

        position = nextMarkerStart
    end

    if #parts == 0 then
        error('Multipart response did not contain any parseable parts')
    end

    return parts
end

function HttpLogic.filenameFromContentDisposition(contentDisposition)
    if contentDisposition == nil then
        return nil
    end

    return contentDisposition:match('filename="?([^";]+)"?')
end

return HttpLogic
