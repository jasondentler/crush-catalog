local LrApplication = import("LrApplication")
local LrDialogs = import("LrDialogs")
local LrHttp = import("LrHttp")
local LrTasks = import("LrTasks")
local LrPrefs = import("LrPrefs")
local JSON = require("JSON")
local LuaHelpers = require("LuaHelpers")

local prefs = LrPrefs.prefsForPlugin()
local DEFAULT_BACKEND_URL = "http://127.0.0.1:8000/identify"

local function getSelectedPhotoPaths()
	local catalog = LrApplication.activeCatalog()
	local photos = catalog:getTargetPhotos()
	local paths = {}

	for _, photo in ipairs(photos) do
		local path = photo:getRawMetadata("path")
		if path then
			table.insert(paths, path)
		end
	end

	return paths
end

local function askForLocationFallback(photoPath)
	return LrDialogs.promptForString(
		"Location Required",
		"This photo does not contain GPS coordinates. Enter an eBird hotspot/region code, city & state, or county & state for:\n"
			.. photoPath,
		""
	)
end

local function formatAlternativeList(alternatives)
	return LuaHelpers.format_alternative_list(alternatives)
end

local function promptConfirmOrChoose(response)
	if not response or not response.best_match then
		return nil
	end

	local altText = ""
	if response.alternatives and #response.alternatives > 0 then
		altText = "\n\nAlternatives:\n" .. formatAlternativeList(response.alternatives)
	end

	local message = string.format(
		"Top match: %s (%.1f%%)%s\n\nAccept this identification or choose an alternative?",
		response.best_match.species or "Unknown",
		(response.best_match.confidence or 0) * 100,
		altText
	)

	local accepted = LrDialogs.confirm("Confirm Bird Identification", message, "Accept", "Choose Alternate")
	if accepted then
		return response.best_match
	end

	if not response.alternatives or #response.alternatives == 0 then
		LrDialogs.message("No alternatives", "There are no alternate species to choose.")
		return nil
	end

	local choice = LrDialogs.promptForString(
		"Choose Alternate Species",
		"Enter the number of the species to accept:\n" .. formatAlternativeList(response.alternatives),
		"1"
	)

	if not choice then
		return nil
	end

	local index = tonumber(choice)
	if index and response.alternatives[index] then
		return response.alternatives[index]
	end

	LrDialogs.message("Invalid selection", "The number you entered does not match an available alternative.")
	return nil
end

local function showResponse(photoPath, response)
	if not response then
		LrDialogs.message("Bird ID Error", "The backend returned an empty response.")
		return
	end

	if response.error then
		LrDialogs.message("Bird ID Error", response.error)
		return
	end

	local title = "Bird ID Results"
	local lines = {}

	if response.detections and #response.detections > 0 then
		table.insert(lines, "Detected birds: " .. tostring(#response.detections))
	end

	for _, detection in ipairs(response.detections or {}) do
		local best_match = detection.best_match
		local comName = best_match.comName
		local sciName = best_match.sciName
	 	local confidence = (best_match.confidence or 0) * 100
		local line = string.format("- %s (%s) (%.1f%% confidence)", comName or "Unknown", sciName or "Unknown", confidence)
		table.insert(lines, line)
	end

	LrDialogs.message(title, table.concat(lines, "\n"))

	local acceptedChoice = promptConfirmOrChoose(response)
	if acceptedChoice then
		LrDialogs.message("Selection saved", "Accepted species: " .. (acceptedChoice.species or "Unknown"))
	end
end

local function postPayload(payload)
	local backendUrl = tostring(prefs.backendUrl or DEFAULT_BACKEND_URL)

	local photoFileName = payload.photo_path:match("[^/\\]+$") or "photo.jpg"
	local parts = {
		{
			name = "image_data",
			filePath = payload.photo_path,
			fileName = photoFileName,
			contentType = "image/jpeg",
		},
		{
			name = "ebird_token",
			value = payload.ebird_token,
		},
	}

	if payload.location_fallback then
		table.insert(parts, {
			name = "location_fallback",
			value = payload.location_fallback,
		})
	end

	local result = LrHttp.postMultipart(backendUrl, parts)

	if not result then
		return nil, "No response from backend"
	end

	local decoded = JSON:decode(result)
	return decoded, nil
end

local function sendIdentifyRequest(photoPath)
	local ebirdToken = tostring(prefs.ebirdApiKey or "")

	if ebirdToken == "" then
		LrDialogs.message(
			"Missing eBird API Key",
			"Please configure an eBird API key in the plugin preferences before identifying birds."
		)
		return
	end

	local payload = LuaHelpers.build_identify_payload(photoPath, ebirdToken, nil)

	local response, err = postPayload(payload)
	if err then
		LrDialogs.message("Connection Failed", "Could not connect to the backend: " .. err)
		return
	end

	if response and response.error and response.error:match("[Ll]ocation") then
		local locationFallback = askForLocationFallback(photoPath)
		if not locationFallback or locationFallback == "" then
			LrDialogs.message(
				"Location Required",
				"Identification cancelled because no location fallback was provided."
			)
			return
		end

		payload = LuaHelpers.build_identify_payload(photoPath, ebirdToken, locationFallback)
		response, err = postPayload(payload)
		if err then
			LrDialogs.message("Connection Failed", "Could not connect to the backend: " .. err)
			return
		end
	end

	showResponse(photoPath, response)
end

local function identifySelectedPhotos()
	local photoPaths = getSelectedPhotoPaths()

	if #photoPaths == 0 then
		LrDialogs.message("No Photos Selected", "Please select one or more photos before running the bird identifier.")
		return
	end

	for _, photoPath in ipairs(photoPaths) do
		sendIdentifyRequest(photoPath)
	end
end

LrTasks.startAsyncTask(function()
	identifySelectedPhotos()
end)
