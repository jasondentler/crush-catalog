local LrHttp = import "LrHttp"
local LrErrors = import "LrErrors"
local LrPathUtils = import "LrPathUtils"
local LrDialogs = import 'LrDialogs'
local EBirdService = {}
local Logger = require 'Logger'

local jsonPath = LrPathUtils.child(_PLUGIN.path, "JSON.lua")
local JSON = dofile(jsonPath)

local function logError(url, message)
    Logger.error(message, url)
end

local function logInfo(url, message)
    Logger.info(message, url)
end

local function logDebug(url, message)
    Logger.debug(message, url)
end

local function logNetworkError(url, info)
    if info and info.status == 200 then
        return
    elseif info and info.error then
        local errorMsg = "Network Error:"
        for k, v in pairs(info.error) do
            errorMsg = errorMsg .. string.format("\n\t%s: %s", tostring(k), tostring(v))
        end
        logError(url, errorMsg)
    else
        logError(url, "Unknown Network Error");
    end
end

local function logHttpError(url, response, info)
    if not info or not info.status or info.status == 200 then
        return
    end

    -- Lightroom doesn't have a built-in JSON pretty-printer, 
    -- but we can log the raw string or format a custom message.
    local errorLog = string.format(
        "eBird API Error Trace:\nStatus: %s\nResponse Body: %s", 
        tostring(info.status), 
        tostring(response))

    logError(url, errorLog)
end

local function getHumanReadableError(info)
    -- 1. Check for success
    if info and info.status == 200 then
        return true, LOC "$$$/CrushCatalog/eBirdService/Error/200=Success."
    end

    -- 2. Check for Low-Level Network Errors (No internet, DNS failure, etc.)
    if not info or (info and info.error and info.error.name) then
        local errorName = (info and info.error and info.error.name) or unknownNetworkError
        return false, LOC("$$$/CrushCatalog/eBirdService/Error/Network=Network error: ^1", errorName)
    end

    -- 3. Map HTTP Status Codes to Localized Strings
    local status = info.status
    if status == 401 then
        return false, LOC "$$$/CrushCatalog/eBirdService/Error/401=Invalid API Key. Please check your settings."
    elseif status == 429 then
        return false, LOC "$$$/CrushCatalog/eBirdService/Error/429=Too many requests. Please try again later."
    elseif status >= 500 then
        return false, LOC "$$$/CrushCatalog/eBirdService/Error/500=eBird server error. Try again shortly."
    else
        -- Fallback for any other non-200 code
        return false, LOC("$$$/CrushCatalog/eBirdService/Error/Unknown=An unexpected error occurred (^1).", tostring(status))
    end
end

local function processResponse(url, response, info)
    local success, message = getHumanReadableError(info)
    if not success then
        if info.status then
            logHttpError(url, response, info)
            return success, message, nil
        else
            logNetworkError(url, info)
            return success, message, nil
        end
    end

    local json = nil
    logInfo(url, response)
    json = JSON:decode(response)
    return success, message, json
end

local function httpGet(url, headers)
    logInfo(url, "Invoking GET")
    local response, info = LrHttp.get(url, headers)
    logDebug(url, JSON:encode_pretty({
        url = url,
        headers = headers,
        info = info,
        response = response,
    }))
    local success, message, json = processResponse(url, response, info)
    return success, message, json, info
end

function EBirdService.testConnection(eBirdApiKey)
    local url = "https://api.ebird.org/v2/data/obs/US/recent/notable"
    local headers = {{
        field = "x-ebirdapitoken",
        value = eBirdApiKey
    }, {
        field = "Accept",
        value = "application/json"
    }}

    return httpGet(url, headers)
end

if not JSON then
    local message = "Could not load JSON.lua from " .. jsonPath
    logError(nil, message)
    LrDialogs.message("Error", message)
end

return EBirdService
