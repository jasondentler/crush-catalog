local WildCatalogApi = {}

WildCatalogApi.DEFAULT_BASE_URL = 'http://localhost:8000'

local function pluginPath()
    if _PLUGIN ~= nil and _PLUGIN.path ~= nil then
        return _PLUGIN.path
    end

    local source = debug.getinfo(1, 'S').source
    return source:match('^@(.+)/[^/]+$') or '.'
end

local JSON = assert(loadfile(pluginPath() .. '/JSON.lua'))()
local Http = assert(loadfile(pluginPath() .. '/Http.lua'))()
local Identify = assert(loadfile(pluginPath() .. '/Core/WildCatalogIdentify.lua'))()

function WildCatalogApi.identify(imagePath, options)
    local effectiveOptions = {}

    for key, value in pairs(options or {}) do
        effectiveOptions[key] = value
    end

    effectiveOptions.baseUrl = effectiveOptions.baseUrl or WildCatalogApi.DEFAULT_BASE_URL

    local request = Identify.buildRequest(imagePath, effectiveOptions, JSON)
    local response = Http.postMultipart(request.url, request.parts, request.headers)

    return Identify.parseResponse(response, JSON, Http.logic)
end

WildCatalogApi.JSON = JSON
WildCatalogApi.Http = Http
WildCatalogApi.Identify = Identify

return WildCatalogApi
