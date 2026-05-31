local LrApplication = import("LrApplication")
local LrDialogs = import("LrDialogs")
local LrHttp = import("LrHttp")
local LrTasks = import("LrTasks")
local LrPrefs = import("LrPrefs")
local LrLogger = import("LrLogger")
local LrPathUtils = import("LrPathUtils")
local LrProgressScope = import("LrProgressScope")
local LrFileUtils = import("LrFileUtils")
local LrView = import("LrView")
local LrBinding = import("LrBinding")
local LrFunctionContext = import("LrFunctionContext")
local JSON = require("JSON")
local MetadataHelpers = require("MetadataHelpers")
local LuaHelpers = require("LuaHelpers")
local ImageHelpers = require("ImageHelpers")
local ConfirmDetection = require("ConfirmDetection")

local myLogger = LrLogger("com.jasondentler.crushcatalog.BirdIdentifyAction")
myLogger:enable("logfile")

local DEFAULT_BACKEND_URL = "http://127.0.0.1:8000/identify"
local EXPORT_BATCH_SIZE = 25

local function outputToLog(message)
	myLogger:trace(message)
end

local function getPrefs()
	return LrPrefs.prefsForPlugin()
end

local function trim(value)
	return tostring(value or ""):match("^%s*(.-)%s*$") or ""
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

local function cleanupPhotoExports(photoExports)
	for _, photoExport in ipairs(photoExports or {}) do
		local exportedPhotoPath = photoExport.exportedPhotoPath
		if exportedPhotoPath and LrFileUtils.exists(exportedPhotoPath) then
			local success, err = LrTasks.pcall(function()
				LrFileUtils.delete(exportedPhotoPath)
			end)

			if success then
				outputToLog("Deleted exported temp JPEG: " .. tostring(exportedPhotoPath))
			else
				outputToLog(string.format(
					"Failed to delete exported temp JPEG: %s error=%s",
					tostring(exportedPhotoPath),
					tostring(err)
				))
			end
		end
	end
end

local function setProgress(progressScope, completed, total, caption)
	if not progressScope then
		return
	end

	progressScope:setCaption(caption)
	progressScope:setPortionComplete(completed, total)
end

local function isProgressCanceled(progressScope)
	if not progressScope then
		return false
	end

	local success, canceled = LrTasks.pcall(function()
		return progressScope:isCanceled()
	end)

	return success and canceled == true
end

local function isProgressPaused(progressScope)
	if not progressScope then
		return false
	end

	local success, paused = LrTasks.pcall(function()
		return progressScope:isPaused()
	end)

	return success and paused == true
end

local function setProgressCaption(progressScope, caption)
	if not progressScope then
		return
	end

	LrTasks.pcall(function()
		progressScope:setCaption(caption)
	end)
end

local function waitIfProgressPaused(progressScope, caption)
	if not isProgressPaused(progressScope) then
		return not isProgressCanceled(progressScope)
	end

	outputToLog("Progress scope paused")
	setProgressCaption(progressScope, caption or "Paused identifying birds.")

	while isProgressPaused(progressScope) do
		if isProgressCanceled(progressScope) then
			outputToLog("Progress scope canceled while paused")
			return false
		end

		LrTasks.sleep(0.2)
	end

	outputToLog("Progress scope resumed")
	return not isProgressCanceled(progressScope)
end

local function setProgressControls(progressScope, pausable, cancelable)
	if not progressScope then
		return
	end

	local success, err = LrTasks.pcall(function()
		progressScope:setPausable(pausable, cancelable)
	end)

	if not success then
		outputToLog("Unable to set progress pausable state: " .. tostring(err))
		success, err = LrTasks.pcall(function()
			progressScope:setCancelable(cancelable)
		end)

		if not success then
			outputToLog("Unable to set progress cancelable state: " .. tostring(err))
		end
	end
end

local function leafName(path)
	if not path or path == "" then
		return "photo"
	end

	return LrPathUtils.leafName(path)
end

local function getPhotoBatch(photos, startIndex, batchSize)
	local batch = {}
	local endIndex = math.min(startIndex + batchSize - 1, #photos)

	for i = startIndex, endIndex do
		table.insert(batch, photos[i])
	end

	return batch, endIndex
end

local function numberFromPluginProperty(photo, fieldId)
	local success, value = LrTasks.pcall(function()
		return photo:getPropertyForPlugin(_PLUGIN, fieldId)
	end)

	if not success then
		outputToLog(string.format(
			"Failed to read plugin metadata fieldId=%s error=%s",
			tostring(fieldId),
			tostring(value)
		))
		return 0
	end

	return tonumber(value) or 0
end

local function reviewedDetectionCount(photo, includeUnsure)
	local reviewed = numberFromPluginProperty(photo, "birdSuggestedCount")
		+ numberFromPluginProperty(photo, "birdLocalSpeciesCount")
		+ numberFromPluginProperty(photo, "birdManualCount")
		+ numberFromPluginProperty(photo, "birdNotBirdCount")

	if includeUnsure then
		reviewed = reviewed + numberFromPluginProperty(photo, "birdUnsureCount")
	end

	return reviewed
end

local function isIdentificationComplete(photo, includeUnsure)
	local detections = numberFromPluginProperty(photo, "birdDetectionCount")
	if detections <= 0 then
		return false
	end

	return reviewedDetectionCount(photo, includeUnsure) >= detections
end

local function filterPhotosForReview(photos, reviewOptions)
	if not reviewOptions or not reviewOptions.skipCompleted then
		return photos
	end

	local filtered = {}
	local skipped = 0
	local includeUnsure = reviewOptions.skipUnsure == true
	for _, photo in ipairs(photos) do
		if isIdentificationComplete(photo, includeUnsure) then
			skipped = skipped + 1
			if includeUnsure then
				outputToLog("Skipping reviewed photo including unsure detections: " .. tostring(photo:getRawMetadata("path")))
			else
				outputToLog("Skipping completed photo: " .. tostring(photo:getRawMetadata("path")))
			end
		else
			table.insert(filtered, photo)
		end
	end

	if includeUnsure then
		outputToLog(string.format("Skipped %d reviewed photo(s), counting unsure detections", skipped))
	else
		outputToLog(string.format("Skipped %d completed photo(s)", skipped))
	end
	return filtered
end

local function showMultiPhotoOptionsDialog(photoCount)
	return LrFunctionContext.callWithContext("showMultiPhotoOptionsDialog", function(context)
		local f = LrView.osFactory()
		local props = LrBinding.makePropertyTable(context)
		props.skipCompleted = true
		props.skipUnsure = false
		props.reviewMode = "prompt_always"
		props.confidenceThreshold = tostring(getPrefs().autoAcceptConfidenceThreshold or "95")

		local skipUnsureEnabled = LrView.bind {
			key = "skipCompleted",
			transform = function(value)
				return value == true
			end,
		}

		local contents = f:column {
			spacing = 12,
			bind_to_object = props,
			f:static_text {
				title = string.format("Choose how to review %d selected photos.", photoCount),
				width_in_chars = 56,
			},
			f:checkbox {
				title = "Skip photos with complete identification metadata",
				value = LrView.bind("skipCompleted"),
			},
			f:row {
				f:spacer {
					width = 20,
				},
				f:checkbox {
					title = "Also skip photos where remaining detections are marked unsure",
					value = LrView.bind("skipUnsure"),
					enabled = skipUnsureEnabled,
				},
			},
			f:row {
				f:radio_button {
					title = "Prompt for every detection",
					value = LrView.bind("reviewMode"),
					checked_value = "prompt_always",
				},
			},
			f:row {
				f:radio_button {
					title = "Auto-accept best suggestion at or above",
					value = LrView.bind("reviewMode"),
					checked_value = "prompt_threshold",
				},
				f:edit_field {
					value = LrView.bind("confidenceThreshold"),
					width_in_chars = 5,
				},
				f:static_text {
					title = "% confidence, then prompt for lower-confidence detections",
				},
			},
			f:row {
				f:radio_button {
					title = "Run unattended: accept every top suggestion",
					value = LrView.bind("reviewMode"),
					checked_value = "unattended_always",
				},
			},
			f:row {
				f:radio_button {
					title = LrView.bind {
						key = "confidenceThreshold",
						transform = function(value)
							local thresholdText = trim(value)
							if thresholdText == "" then
								thresholdText = "?"
							end
							return string.format(
								"Run unattended: accept at/above %s%% and mark lower-confidence detections unsure",
								thresholdText
							)
						end,
					},
					value = LrView.bind("reviewMode"),
					checked_value = "unattended_threshold",
				},
			},
		}

		local dialogResult = LrDialogs.presentModalDialog({
			title = "Identify Bird Options",
			contents = contents,
			props = props,
			actionVerb = "Start",
			cancelVerb = "Cancel",
		})

		if dialogResult ~= "ok" then
			return nil
		end

		local threshold = tonumber(trim(props.confidenceThreshold))
		if not threshold or threshold < 0 or threshold > 100 then
			LrDialogs.message("Invalid Threshold", "Enter a confidence threshold from 0 to 100.")
			return showMultiPhotoOptionsDialog(photoCount)
		end

		getPrefs().autoAcceptConfidenceThreshold = tostring(threshold)

		return {
			skipCompleted = props.skipCompleted == true,
			skipUnsure = props.skipUnsure == true,
			reviewMode = props.reviewMode,
			autoAcceptHighConfidence = props.reviewMode == "prompt_threshold",
			autoAcceptThreshold = threshold,
			unattended = props.reviewMode == "unattended_always" or props.reviewMode == "unattended_threshold",
			unattendedMode = props.reviewMode == "unattended_always" and "always" or "threshold",
		}
	end)
end

local function getReviewOptions(photoCount)
	if photoCount <= 1 then
		return {
			skipCompleted = false,
			skipUnsure = false,
			reviewMode = "prompt_always",
			autoAcceptHighConfidence = false,
			autoAcceptThreshold = tonumber(getPrefs().autoAcceptConfidenceThreshold) or 95,
			unattended = false,
			unattendedMode = "threshold",
		}
	end

	return showMultiPhotoOptionsDialog(photoCount)
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

local function writeBirdReview(birds, originalPhotoPath, reviewStats)
	if #birds == 0 and not reviewStats then
		outputToLog("No confirmed birds to write for originalPhotoPath=" .. tostring(originalPhotoPath))
		return
	end

	if not originalPhotoPath or originalPhotoPath == "" then
		LrDialogs.message("Metadata Error", "Could not determine the original catalog photo path.")
		return
	end

	outputToLog(string.format("Writing %d confirmed birds and review stats to originalPhotoPath=%s", #birds, tostring(originalPhotoPath)))
	MetadataHelpers.writeBirdReview(birds, originalPhotoPath, reviewStats)
end

local function getDetectionCount(response)
	local count = 0
	for _, _ in ipairs(response.detections or {}) do
		count = count + 1
	end
	return count
end

local function newReviewStats(response)
	local location = response.location or {}
	return {
		detectedCount = getDetectionCount(response),
		suggestedCount = 0,
		localSpeciesCount = 0,
		manualCount = 0,
		notBirdCount = 0,
		unsureCount = 0,
		topSuggestionConfidence = 0,
		ebirdRegionCode = location.region_code or "",
		ebirdHotspotName = location.hotspot_name or "",
	}
end

local function updateTopSuggestionConfidence(reviewStats, detection)
	local confidence = tonumber(detection and detection.best_match and detection.best_match.confidence)
	if confidence and confidence * 100 > reviewStats.topSuggestionConfidence then
		reviewStats.topSuggestionConfidence = confidence * 100
	end
end

local function getBestMatchConfidencePercent(detection)
	local confidence = tonumber(detection and detection.best_match and detection.best_match.confidence)
	return confidence and confidence * 100 or 0
end

local function confirmBestMatch(detection, selectionSource)
	local match = detection and detection.best_match
	if not match then
		return { status = "rejected", reason = "unsure" }
	end

	local scientificName = match.sciName or match.species
	local commonName = match.comName or match.species
	if not scientificName or not commonName then
		return { status = "rejected", reason = "unsure" }
	end

	return {
		status = "confirmed",
		commonName = commonName,
		scientificName = scientificName,
		confidence = getBestMatchConfidencePercent(detection),
		selectionSource = selectionSource or "suggested",
	}
end

local function autoReviewDetection(detection, reviewOptions)
	if not reviewOptions then
		return nil
	end

	local confidence = getBestMatchConfidencePercent(detection)

	if reviewOptions.unattended then
		if reviewOptions.unattendedMode == "always" then
			outputToLog(string.format("Auto-confirming detection in unattended always mode confidence=%.1f", confidence))
			return confirmBestMatch(detection, "suggested")
		end

		if confidence >= reviewOptions.autoAcceptThreshold then
			outputToLog(string.format("Auto-confirming detection in unattended threshold mode confidence=%.1f", confidence))
			return confirmBestMatch(detection, "suggested")
		end

		outputToLog(string.format("Marking detection unsure in unattended threshold mode confidence=%.1f", confidence))
		return { status = "rejected", reason = "unsure" }
	end

	if reviewOptions.autoAcceptHighConfidence and confidence >= reviewOptions.autoAcceptThreshold then
		outputToLog(string.format("Auto-confirming high-confidence detection confidence=%.1f", confidence))
		return confirmBestMatch(detection, "suggested")
	end

	return nil
end

local function countConfirmation(reviewStats, confirmation)
	if not confirmation then
		return
	end

	if confirmation.status == "confirmed" then
		if confirmation.selectionSource == "local_species" then
			reviewStats.localSpeciesCount = reviewStats.localSpeciesCount + 1
		elseif confirmation.selectionSource == "manual" then
			reviewStats.manualCount = reviewStats.manualCount + 1
		else
			reviewStats.suggestedCount = reviewStats.suggestedCount + 1
		end
	elseif confirmation.status == "rejected" then
		if confirmation.reason == "not_a_bird" then
			reviewStats.notBirdCount = reviewStats.notBirdCount + 1
		elseif confirmation.reason == "unsure" then
			reviewStats.unsureCount = reviewStats.unsureCount + 1
		end
	end
end

local function showResponse(exportedPhotoPath, originalPhotoPath, response, reviewOptions, progressScope)
	if not response then
		LrDialogs.message("Bird ID Error", "The backend returned an empty response.")
		return true
	end

	if response.error and (not response.detections or #response.detections == 0) then
		writeBirdReview({}, originalPhotoPath, newReviewStats(response))
		LrDialogs.message("Bird ID Error", response.error)
		return true
	end

	local birds = {}
	local reviewStats = newReviewStats(response)
	for detectionIndex, detection in ipairs(response.detections or {}) do
		if not waitIfProgressPaused(progressScope, "Paused reviewing birds.") then
			outputToLog("Progress scope canceled while paused during review at originalPhotoPath=" .. tostring(originalPhotoPath))
			return false
		end

		if isProgressCanceled(progressScope) then
			outputToLog("Progress scope canceled during review at originalPhotoPath=" .. tostring(originalPhotoPath))
			return false
		end

		updateTopSuggestionConfidence(reviewStats, detection)

		outputToLog(string.format(
			"Reviewing detection index=%d originalPhotoPath=%s exportedPhotoPath=%s bestMatch=%s box=%s",
			detectionIndex,
			tostring(originalPhotoPath),
			tostring(exportedPhotoPath),
			tostring(detection.best_match and detection.best_match.comName),
			tostring(detection.box and table.concat(detection.box, ","))
		))
		local confirmation = autoReviewDetection(detection, reviewOptions)
		while not confirmation or confirmation.status == "paused" do
			if confirmation and confirmation.status == "paused" then
				if not waitIfProgressPaused(progressScope, "Paused reviewing birds.") then
					outputToLog("Progress scope canceled while paused during detection review at originalPhotoPath=" .. tostring(originalPhotoPath))
					return false
				end
			end

			confirmation = ConfirmDetection.confirm(exportedPhotoPath, detection, originalPhotoPath, response.local_species, progressScope)
		end

		countConfirmation(reviewStats, confirmation)

		if confirmation and confirmation.status == "confirmed" then
			outputToLog(string.format(
				"Confirmed detection index=%d originalPhotoPath=%s commonName=%s scientificName=%s selectionSource=%s",
				detectionIndex,
				tostring(originalPhotoPath),
				tostring(confirmation.commonName),
				tostring(confirmation.scientificName),
				tostring(confirmation.selectionSource)
			))
			table.insert(birds, {
				commonName = confirmation.commonName,
				scientificName = confirmation.scientificName,
				confidence = tonumber(confirmation.confidence)
			})
		elseif confirmation and confirmation.status == "stopped" then
			outputToLog("Stopping review at originalPhotoPath=" .. tostring(originalPhotoPath))
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

	writeBirdReview(birds, originalPhotoPath, reviewStats)
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

local function sendIdentifyRequest(exportedPhotoPath, originalPhotoPath, reviewOptions, progressScope)
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

	if not waitIfProgressPaused(progressScope, "Paused before identifying birds.") then
		outputToLog("Progress scope canceled while paused before backend request originalPhotoPath=" .. tostring(originalPhotoPath))
		return false
	end

	if isProgressCanceled(progressScope) then
		outputToLog("Progress scope canceled before backend request originalPhotoPath=" .. tostring(originalPhotoPath))
		return false
	end

	local response, err = postPayload(payload)
	if err then
		LrDialogs.message("Connection Failed", "Could not connect to the backend: " .. err)
		return true
	end

	if not waitIfProgressPaused(progressScope, "Paused after identifying birds.") then
		outputToLog("Progress scope canceled while paused after backend request originalPhotoPath=" .. tostring(originalPhotoPath))
		return false
	end

	if isProgressCanceled(progressScope) then
		outputToLog("Progress scope canceled after backend request originalPhotoPath=" .. tostring(originalPhotoPath))
		return false
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

		if not waitIfProgressPaused(progressScope, "Paused after identifying birds.") then
			outputToLog("Progress scope canceled while paused after location fallback request originalPhotoPath=" .. tostring(originalPhotoPath))
			return false
		end

		if isProgressCanceled(progressScope) then
			outputToLog("Progress scope canceled after location fallback request originalPhotoPath=" .. tostring(originalPhotoPath))
			return false
		end
	end

	return showResponse(exportedPhotoPath, originalPhotoPath, response, reviewOptions, progressScope)
end

local function identifySelectedPhotos()
	local catalog = LrApplication.activeCatalog()
	local photos = catalog:getTargetPhotos()
	local selectedPhotoCount = #photos

	if selectedPhotoCount == 0 then
		LrDialogs.message("No Photos Selected", "Please select one or more photos before running the bird identifier.")
		return
	end

	local reviewOptions = getReviewOptions(selectedPhotoCount)
	if not reviewOptions then
		outputToLog("Identification cancelled from multi-photo options dialog")
		return
	end

	photos = filterPhotosForReview(photos, reviewOptions)
	local photoCount = #photos

	if photoCount == 0 then
		LrDialogs.message("No Photos To Identify", "All selected photos already have complete identification metadata.")
		return
	end

	local progressScope = LrProgressScope({
		title = "Identify Birds",
	})

	setProgressControls(progressScope, true, true)

	local completedPhotos = 0
	local stopped = false

	local success, error = LrTasks.pcall(function()
		for batchStart = 1, photoCount, EXPORT_BATCH_SIZE do
			if not waitIfProgressPaused(progressScope, "Paused identifying birds.") then
				stopped = true
				setProgress(progressScope, completedPhotos, photoCount, "Stopping identification...")
				return
			end

			if isProgressCanceled(progressScope) then
				stopped = true
				setProgress(progressScope, completedPhotos, photoCount, "Stopping identification...")
				return
			end

			local photoBatch, batchEnd = getPhotoBatch(photos, batchStart, EXPORT_BATCH_SIZE)

			setProgress(
				progressScope,
				completedPhotos,
				photoCount,
				string.format("Exporting photos %d-%d of %d...", batchStart, batchEnd, photoCount)
			)

			local photoExports = getSelectedPhotoExports(photoBatch)

			if #photoExports == 0 then
				outputToLog(string.format("No photos were exported for batchStart=%d batchEnd=%d", batchStart, batchEnd))
			end

			if not waitIfProgressPaused(progressScope, "Paused identifying birds.") then
				stopped = true
				cleanupPhotoExports(photoExports)
				setProgress(progressScope, completedPhotos, photoCount, "Stopped identifying birds.")
				return
			end

			if isProgressCanceled(progressScope) then
				stopped = true
				cleanupPhotoExports(photoExports)
				setProgress(progressScope, completedPhotos, photoCount, "Stopped identifying birds.")
				return
			end

			for batchIndex = 1, #photoExports do
				local photoExport = photoExports[batchIndex]
				local photoNumber = batchStart + batchIndex - 1
				local photoName = leafName(photoExport.originalPhotoPath)
				local shouldContinue = true

				if not waitIfProgressPaused(progressScope, "Paused identifying birds.") then
					stopped = true
					cleanupPhotoExports(photoExports)
					setProgress(progressScope, completedPhotos, photoCount, "Stopped identifying birds.")
					return
				end

				if isProgressCanceled(progressScope) then
					stopped = true
					cleanupPhotoExports(photoExports)
					setProgress(progressScope, completedPhotos, photoCount, "Stopped identifying birds.")
					return
				end

				setProgress(
					progressScope,
					completedPhotos,
					photoCount,
					string.format("Identifying photo %d of %d: %s", photoNumber, photoCount, photoName)
				)

				local photoSuccess, photoError = LrTasks.pcall(function()
					shouldContinue = sendIdentifyRequest(photoExport.exportedPhotoPath, photoExport.originalPhotoPath, reviewOptions, progressScope)
				end)

				if not photoSuccess then
					LrDialogs.message("Error Identifying Birds", "An error occurred while identifying birds in photo: " .. tostring(photoExport.originalPhotoPath) .. "\n\nError details: " .. tostring(photoError))
				end

				completedPhotos = completedPhotos + 1

				if photoSuccess and shouldContinue == false then
					stopped = true
					cleanupPhotoExports(photoExports)
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

			cleanupPhotoExports(photoExports)
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
