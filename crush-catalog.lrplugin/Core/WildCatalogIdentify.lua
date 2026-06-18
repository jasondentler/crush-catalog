local WildCatalogIdentify = {}

local function stripTrailingSlash(value)
    return (value:gsub('/+$', ''))
end

function WildCatalogIdentify.buildPayload(options)
    local payload = {
        return_detected_images = true,
    }

    if options == nil then
        return payload
    end

    if options.originalFilename ~= nil then
        payload.original_filename = options.originalFilename
    elseif options.original_filename ~= nil then
        payload.original_filename = options.original_filename
    end

    if options.exifOverride ~= nil then
        payload.exif_override = options.exifOverride
    elseif options.exif_override ~= nil then
        payload.exif_override = options.exif_override
    end

    if options.commonNameLanguage ~= nil then
        payload.common_name_language = options.commonNameLanguage
    elseif options.common_name_language ~= nil then
        payload.common_name_language = options.common_name_language
    end

    return payload
end

function WildCatalogIdentify.buildRequest(imagePath, options, json)
    if imagePath == nil or imagePath == '' then
        error('imagePath is required')
    end

    options = options or {}

    local baseUrl = stripTrailingSlash(options.baseUrl or 'http://localhost:8000')
    local payload = WildCatalogIdentify.buildPayload(options)

    return {
        url = baseUrl .. '/identify',
        parts = {
            {
                name = 'image',
                filePath = imagePath,
                fileName = options.originalFilename or options.original_filename,
                contentType = options.imageContentType or 'image/jpeg',
            },
            {
                name = 'payload',
                value = json:encode(payload),
                contentType = 'application/json',
            },
        },
        headers = {
            { field = 'Accept', value = 'multipart/mixed' },
        },
    }
end

function WildCatalogIdentify.parseResponse(response, json, httpLogic)
    local contentType = response.normalizedHeaders['content-type']

    if response.body == nil or response.body == '' then
        error('Wild Catalog returned an empty response')
    end

    if contentType ~= nil and contentType:lower():find('application/json', 1, true) then
        return {
            result = json:decode(response.body),
            detectedImages = {},
            headers = response.headers,
        }
    end

    local parts = httpLogic.parseMultipartMixed(response.body, contentType)
    local result = json:decode(parts[1].body)
    local detectedImages = {}

    for index = 2, #parts do
        local part = parts[index]
        local partContentType = part.headers['content-type'] or 'image/jpeg'

        if partContentType:lower():find('image/jpeg', 1, true) then
            detectedImages[#detectedImages + 1] = {
                bytes = part.body,
                contentType = partContentType,
                filename = httpLogic.filenameFromContentDisposition(part.headers['content-disposition']),
            }
        end
    end

    return {
        result = result,
        detectedImages = detectedImages,
        headers = response.headers,
    }
end

return WildCatalogIdentify
