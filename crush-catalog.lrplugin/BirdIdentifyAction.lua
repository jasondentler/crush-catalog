local LrApplication = import("LrApplication")
local LrDialogs = import("LrDialogs")
local LrHttp = import("LrHttp")
local LrTasks = import("LrTasks")
local LrPrefs = import("LrPrefs")
local LrLogger = import("LrLogger")
local LrPathUtils = import("LrPathUtils")
local LrProgressScope = import("LrProgressScope")
local JSON = require("JSON")
local MetadataHelpers = require("MetadataHelpers")
local LuaHelpers = require("LuaHelpers")
local ImageHelpers = require("ImageHelpers")
local ConfirmDetection = require("ConfirmDetection")

local myLogger = LrLogger("com.jasondentler.crushcatalog.BirdIdentifyAction")
myLogger:enable("logfile")

local DEFAULT_BACKEND_URL = "http://127.0.0.1:8000/identify"

local function outputToLog(message)
	myLogger:trace(message)
end

local function getPrefs()
	return LrPrefs.prefsForPlugin()
end

local function getSelectedPhotoExports(photos)
	local exportedFiles = ImageHelpers.exportToTempFile(photos)

	local exports = {}

	for _, exportResult in ipairs(exportedFiles) do
		if exportResult.exportedJpegPath then
			outputToLog(string.format(
				"Export result originalPhotoPath=%s exportedPhotoPath=%s photoIdentifier=%s",
				tostring(exportResult.originalPhotoPath),
				tostring(exportResult.exportedJpegPath),
				tostring(exportResult.photoIdentifier)
			))
			table.insert(exports, {
				exportedPhotoPath = exportResult.exportedJpegPath,
				originalPhotoPath = exportResult.originalPhotoPath,
			})
		else
			LrDialogs.message(
				"Failed to export",
				string.format("A file failed to export: %s", exportResult.errorMessage)
			)
		end
	end

	return exports
end

local function setProgress(progressScope, completed, total, caption)
	if not progressScope then
		return
	end

	progressScope:setCaption(caption)
	progressScope:setPortionComplete(completed, total)
end

local function leafName(path)
	if not path or path == "" then
		return "photo"
	end

	return LrPathUtils.leafName(path)
end

local function askForLocationFallback(photoPath)
	local fallbackRegion = tostring(getPrefs().defaultEbirdRegion or ""):match("^%s*(.-)%s*$") or ""

	if fallbackRegion == "" then
		outputToLog("Photo does not contain GPS coordinates and no default eBird region is configured for photoPath=" .. tostring(photoPath))
		return nil
	end

	outputToLog(string.format(
		"Photo does not contain GPS coordinates; using default eBird region %s for photoPath=%s",
		fallbackRegion,
		tostring(photoPath)
	))
	return fallbackRegion
end

local function writeConfirmedBirds(birds, originalPhotoPath)
	if #birds == 0 then
		outputToLog("No confirmed birds to write for originalPhotoPath=" .. tostring(originalPhotoPath))
		return
	end

	if not originalPhotoPath or originalPhotoPath == "" then
		LrDialogs.message("Metadata Error", "Could not determine the original catalog photo path.")
		return
	end

	outputToLog(string.format("Writing %d confirmed birds to originalPhotoPath=%s", #birds, tostring(originalPhotoPath)))
	MetadataHelpers.writeBirds(birds, originalPhotoPath)
end

local function showResponse(exportedPhotoPath, originalPhotoPath, response)
	if not response then
		LrDialogs.message("Bird ID Error", "The backend returned an empty response.")
		return true
	end

	if response.error and (not response.detections or #response.detections == 0) then
		LrDialogs.message("Bird ID Error", response.error)
		return true
	end

	local birds = {}
	for detectionIndex, detection in ipairs(response.detections or {}) do
		outputToLog(string.format(
			"Reviewing detection index=%d originalPhotoPath=%s exportedPhotoPath=%s bestMatch=%s box=%s",
			detectionIndex,
			tostring(originalPhotoPath),
			tostring(exportedPhotoPath),
			tostring(detection.best_match and detection.best_match.comName),
			tostring(detection.box and table.concat(detection.box, ","))
		))
		local confirmation = ConfirmDetection.confirm(exportedPhotoPath, detection, originalPhotoPath)

		if confirmation and confirmation.status == "confirmed" then
			outputToLog(string.format(
				"Confirmed detection index=%d originalPhotoPath=%s commonName=%s scientificName=%s",
				detectionIndex,
				tostring(originalPhotoPath),
				tostring(confirmation.commonName),
				tostring(confirmation.scientificName)
			))
			table.insert(birds, {
				commonName = confirmation.commonName,
				scientificName = confirmation.scientificName,
				confidence = tonumber(confirmation.confidence)
			})
		elseif confirmation and confirmation.status == "stopped" then
			outputToLog("Stopping review at originalPhotoPath=" .. tostring(originalPhotoPath))
			writeConfirmedBirds(birds, originalPhotoPath)
			return false
		else
			outputToLog(string.format(
				"Skipped detection index=%d originalPhotoPath=%s status=%s reason=%s",
				detectionIndex,
				tostring(originalPhotoPath),
				tostring(confirmation and confirmation.status),
				tostring(confirmation and confirmation.reason)
			))
		end
	end

	writeConfirmedBirds(birds, originalPhotoPath)
	return true
end

local function postPayload(payload)
	local backendUrl = tostring(getPrefs().backendUrl or DEFAULT_BACKEND_URL)
	if backendUrl == "" then
		backendUrl = DEFAULT_BACKEND_URL
	end

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

local function sendIdentifyRequest(exportedPhotoPath, originalPhotoPath)
	outputToLog(string.format("Sending identify request originalPhotoPath=%s exportedPhotoPath=%s", tostring(originalPhotoPath), tostring(exportedPhotoPath)))
	local ebirdToken = tostring(getPrefs().ebirdApiKey or "")

	if ebirdToken == "" then
		LrDialogs.message(
			"Missing eBird API Key",
			"Please configure an eBird API key in the plugin preferences before identifying birds."
		)
		return false
	end

	local payload = LuaHelpers.build_identify_payload(exportedPhotoPath, ebirdToken, nil)

	local response, err = postPayload(payload)
	if err then
		LrDialogs.message("Connection Failed", "Could not connect to the backend: " .. err)
		return true
	end

	if response and response.error and response.error:match("[Ll]ocation") then
		local locationFallback = askForLocationFallback(originalPhotoPath)
		if not locationFallback or locationFallback == "" then
			LrDialogs.message(
				"Location Required",
				"Identification cancelled because no location fallback was provided."
			)
			return true
		end

		payload = LuaHelpers.build_identify_payload(exportedPhotoPath, ebirdToken, locationFallback)
		response, err = postPayload(payload)
		if err then
			LrDialogs.message("Connection Failed", "Could not connect to the backend: " .. err)
			return true
		end
	end

	return showResponse(exportedPhotoPath, originalPhotoPath, response)
end

local function identifySelectedPhotos()
	local catalog = LrApplication.activeCatalog()
	local photos = catalog:getTargetPhotos()
	local photoCount = #photos

	if photoCount == 0 then
		LrDialogs.message("No Photos Selected", "Please select one or more photos before running the bird identifier.")
		return
	end

	local progressScope = LrProgressScope({
		title = "Identify Birds",
	})

	if progressScope.setCancelable then
		progressScope:setCancelable(false)
	end

	local completedPhotos = 0
	local stopped = false

	local success, error = LrTasks.pcall(function()
		setProgress(progressScope, 0, photoCount, string.format("Exporting %d photo(s)...", photoCount))

		local photoExports = getSelectedPhotoExports(photos)

		if #photoExports == 0 then
			setProgress(progressScope, 0, photoCount, "No photos were exported.")
			LrDialogs.message("No Photos Exported", "No selected photos could be exported for bird identification.")
			return
		end

		for i = 1, #photoExports do
			local photoExport = photoExports[i]
			local photoName = leafName(photoExport.originalPhotoPath)
			local shouldContinue = true

			setProgress(
				progressScope,
				completedPhotos,
				photoCount,
				string.format("Identifying photo %d of %d: %s", i, photoCount, photoName)
			)

			local photoSuccess, photoError = LrTasks.pcall(function()
				shouldContinue = sendIdentifyRequest(photoExport.exportedPhotoPath, photoExport.originalPhotoPath)
			end)

			if not photoSuccess then
				LrDialogs.message("Error Identifying Birds", "An error occurred while identifying birds in photo: " .. tostring(photoExport.originalPhotoPath) .. "\n\nError details: " .. tostring(photoError))
			end

			completedPhotos = completedPhotos + 1

			if photoSuccess and shouldContinue == false then
				stopped = true
				setProgress(
					progressScope,
					completedPhotos,
					photoCount,
					string.format("Stopped after photo %d of %d.", completedPhotos, photoCount)
				)
				return
			end

			setProgress(
				progressScope,
				completedPhotos,
				photoCount,
				string.format("Finished photo %d of %d: %s", completedPhotos, photoCount, photoName)
			)
		end

		setProgress(progressScope, photoCount, photoCount, string.format("Finished identifying %d photo(s).", photoCount))
	end)

	if not success then
		LrDialogs.message("Error Identifying Birds", "An error occurred while identifying birds.\n\nError details: " .. tostring(error))
	end

	if stopped then
		LrTasks.sleep(0.5)
	elseif success then
		LrTasks.sleep(0.5)
	end

	progressScope:done()
end

local function runIdentifySelectedPhotos()
	local success, error = LrTasks.pcall(function()
		identifySelectedPhotos()
	end)

	if not success then
		LrDialogs.message("Error Identifying Birds", "An error occurred while identifying birds.\n\nError details: " .. tostring(error))
	end
end

LrTasks.startAsyncTask(function()
	runIdentifySelectedPhotos()
end)
