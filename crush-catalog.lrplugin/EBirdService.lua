local LrHttp = import("LrHttp")
local LrDialogs = import("LrDialogs")
local JSON = require("JSON")

local EBirdService = {}

function EBirdService.testConnection(apiKey)
	if not apiKey or apiKey == "" then
		return false, "Missing API key", nil, { status = 400 }
	end

	local url = "https://api.ebird.org/v2/ref/taxonomy/ebird?fmt=json"
	local headers = { ["X-eBirdApiToken"] = apiKey }

	local result = LrHttp.get(url, headers)
	if not result then
		return false, "No response from eBird API", nil, nil
	end

	local decoded = JSON:decode(result)
	if decoded then
		return true, "API key validated", result, { status = 200 }
	end

	return false, "Invalid response from eBird", result, nil
end

return EBirdService
