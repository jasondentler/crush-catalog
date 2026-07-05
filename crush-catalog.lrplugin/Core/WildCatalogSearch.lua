local WildCatalogSearch = {}

local DEFAULT_BASE_URL = 'http://localhost:8000'

local function trim(value)
    if value == nil then
        return ''
    end

    return tostring(value):match('^%s*(.-)%s*$') or ''
end

local function normalizeBaseUrl(value)
    local baseUrl = trim(value)

    if baseUrl == '' then
        baseUrl = DEFAULT_BASE_URL
    end

    baseUrl = baseUrl:gsub('/+$', '')

    if baseUrl:lower():sub(-9) == '/identify' then
        baseUrl = baseUrl:sub(1, -10)
    elseif baseUrl:lower():sub(-7) == '/search' then
        baseUrl = baseUrl:sub(1, -8)
    end

    return baseUrl
end

local function urlEncode(value)
    return tostring(value):gsub('\n', '\r\n'):gsub('([^%w%-_%.~])', function(char)
        return string.format('%%%02X', string.byte(char))
    end)
end

local function addParam(params, name, value)
    if value == nil or value == '' then
        return
    end

    params[#params + 1] = urlEncode(name) .. '=' .. urlEncode(value)
end

local function gpsCoordinates(options)
    local gps = options.gpsCoordinates
        or options.gps_coordinates
        or options.gps

    if gps == nil then
        return nil
    end

    return {
        latitude = gps.latitude or gps.lat,
        longitude = gps.longitude or gps.lng,
    }
end

function WildCatalogSearch.normalizeItem(item)
    item = item or {}

    return {
        taxonomy = item.taxonomy or {},
        taxonomyRanks = item.taxonomyRanks
            or item.taxonomy_rank_names
            or item.taxonomy_ranks
            or {},
        commonNameTaxonomy = item.commonNameTaxonomy
            or item.taxonomyCommonNames
            or item.taxonomy_common_names
            or {},
    }
end

function WildCatalogSearch.buildRequest(query, options)
    options = options or {}
    local params = {}
    local gps = gpsCoordinates(options)

    addParam(params, 'query', trim(query))

    if gps ~= nil then
        addParam(params, 'lat', gps.latitude)
        addParam(params, 'lng', gps.longitude)
    end

    local url = normalizeBaseUrl(options.baseUrl) .. '/search'

    if #params > 0 then
        url = url .. '?' .. table.concat(params, '&')
    end

    local headers = {
        { field = 'Accept', value = 'application/json' },
    }
    local language = trim(
        options.acceptLanguage
            or options.accept_language
            or options.commonNameLanguage
            or options.common_name_language
    )

    if language ~= '' then
        headers[#headers + 1] = {
            field = 'Accept-Language',
            value = language,
        }
    end

    return {
        url = url,
        headers = headers,
    }
end

function WildCatalogSearch.parseResponse(response, json)
    if response.body == nil or response.body == '' then
        error('Wild Catalog returned an empty search response')
    end

    local decoded = json:decode(response.body)
    local items = {}

    for _, item in ipairs(decoded.items or {}) do
        items[#items + 1] = WildCatalogSearch.normalizeItem(item)
    end

    return {
        totalItems = decoded.total_items or #items,
        items = items,
        headers = response.headers,
    }
end

return WildCatalogSearch
