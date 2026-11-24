local LrPrefs = import 'LrPrefs'

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
local Search = assert(loadfile(pluginPath() .. '/Core/WildCatalogSearch.lua'))()
local Batch = assert(loadfile(pluginPath() .. '/Core/WildCatalogBatch.lua'))()

local function trim(value)
    if value == nil then
        return ''
    end

    return tostring(value):match('^%s*(.-)%s*$') or ''
end

local function configuredBaseUrl()
    local prefs = LrPrefs.prefsForPlugin()
    local backendUrl = trim(prefs.backendUrl)

    if backendUrl ~= '' then
        return backendUrl
    end

    return WildCatalogApi.DEFAULT_BASE_URL
end

function WildCatalogApi.identify(imagePath, options)
    local effectiveOptions = {}

    for key, value in pairs(options or {}) do
        effectiveOptions[key] = value
    end

    effectiveOptions.baseUrl = effectiveOptions.baseUrl or configuredBaseUrl()

    local request = Identify.buildRequest(imagePath, effectiveOptions, JSON)
    local response = Http.postMultipart(request.url, request.parts, request.headers)

    return Identify.parseResponse(response, JSON, Http.logic)
end

function WildCatalogApi.search(query, options)
    local effectiveOptions = {}

    for key, value in pairs(options or {}) do
        effectiveOptions[key] = value
    end

    effectiveOptions.baseUrl = effectiveOptions.baseUrl or configuredBaseUrl()

    local request = Search.buildRequest(query, effectiveOptions)
    local response = Http.get(request.url, request.headers)

    return Search.parseResponse(response, JSON)
end

-- Call within a Lightroom asynchronous task with a function context.
function WildCatalogApi.identifyBatch(manifest, options)
    local LrTasks = import 'LrTasks'
    options = options or {}
    return Batch.run(manifest, {
        baseUrl = options.baseUrl or configuredBaseUrl(),
        json = JSON,
        protect = LrTasks.pcall,
        resolveAsset = options.resolveAsset,
        isCanceled = options.isCanceled,
        onProgress = options.onProgress,
        transport = {
            request = Http.request,
            upload = function(url, path, headers)
                return Http.upload(url, path, headers, LrTasks.pcall)
            end,
        },
    })
end

WildCatalogApi.JSON = JSON
WildCatalogApi.Http = Http
WildCatalogApi.Identify = Identify
WildCatalogApi.Search = Search

return WildCatalogApi
