local LrApplication = import("LrApplication")
local LrDialogs = import("LrDialogs")
local LrLogger = import("LrLogger")
local LrPathUtils = import("LrPathUtils")
local LrProgressScope = import("LrProgressScope")
local LrTasks = import("LrTasks")

local myLogger = LrLogger("com.jasondentler.crushcatalog.ExportSpeciesCsvAction")
myLogger:enable("logfile")

local function outputToLog(message)
	myLogger:trace(message)
end

local function trim(value)
	return tostring(value or ""):match("^%s*(.-)%s*$") or ""
end

local function splitCsvMetadata(value)
	local values = {}
	for item in tostring(value or ""):gmatch("([^,]+)") do
		local trimmed = trim(item)
		if trimmed ~= "" then
			table.insert(values, trimmed)
		end
	end
	return values
end

local function csvEscape(value)
	local text = tostring(value or "")
	if text:find('[,"\r\n]') then
		text = '"' .. text:gsub('"', '""') .. '"'
	end
	return text
end

local function csvLine(values)
	local escaped = {}
	for _, value in ipairs(values) do
		table.insert(escaped, csvEscape(value))
	end
	return table.concat(escaped, ",")
end

local function getPluginProperty(photo, fieldId)
	local success, value = LrTasks.pcall(function()
		return photo:getPropertyForPlugin(_PLUGIN, fieldId)
	end)

	if success then
		return value
	end

	outputToLog(string.format("Failed to read plugin metadata fieldId=%s error=%s", tostring(fieldId), tostring(value)))
	return nil
end

local function getPhotoPath(photo)
	local success, path = LrTasks.pcall(function()
		return photo:getRawMetadata("path")
	end)

	if success then
		return tostring(path or "")
	end

	outputToLog("Failed to read photo path: " .. tostring(path))
	return ""
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

local function setProgressCancelable(progressScope, cancelable)
	if not progressScope then
		return
	end

	local success, err = LrTasks.pcall(function()
		progressScope:setCancelable(cancelable)
	end)

	if not success then
		outputToLog("Unable to set progress cancelable state: " .. tostring(err))
	end
end

local function addIdentifiedSpeciesRows(rows, seen, photo)
	local photoPath = getPhotoPath(photo)
	local commonNames = splitCsvMetadata(getPluginProperty(photo, "birdCommonNames"))
	local scientificNames = splitCsvMetadata(getPluginProperty(photo, "birdScientificNames"))
	local maxCount = math.max(#commonNames, #scientificNames)

	for index = 1, maxCount do
		local commonName = commonNames[index] or ""
		local scientificName = scientificNames[index] or ""

		if commonName ~= "" or scientificName ~= "" then
			local key = table.concat({ photoPath, commonName, scientificName }, "\31")
			if not seen[key] then
				table.insert(rows, {
					photoPath = photoPath,
					commonName = commonName,
					scientificName = scientificName,
				})
				seen[key] = true
			end
		end
	end
end

local function buildCsv(rows)
	local lines = {
		csvLine({ "Photo Path", "Common Name", "Scientific Name" }),
	}

	for _, row in ipairs(rows) do
		table.insert(lines, csvLine({ row.photoPath, row.commonName, row.scientificName }))
	end

	return table.concat(lines, "\n") .. "\n"
end

local function writeFile(path, contents)
	local file, err = io.open(path, "w")
	if not file then
		return false, err
	end

	file:write(contents)
	file:close()
	return true, nil
end

local function exportIdentifiedSpeciesCsv()
	local catalog = LrApplication.activeCatalog()
	local photos = catalog:getTargetPhotos()

	if #photos == 0 then
		LrDialogs.message(
			"Select Photos First",
			"Choose the photos you want included in the species CSV, then run the export again.",
			"info"
		)
		return
	end

	local savePath = LrDialogs.runSavePanel({
		title = "Export Identified Species CSV",
		prompt = "Export",
		requiredFileType = "csv",
		canCreateDirectories = true,
	})

	if not savePath then
		outputToLog("Identified species CSV export cancelled")
		return
	end

	local rows = {}
	local seen = {}
	local progressScope = LrProgressScope({
		title = "Export Identified Species CSV",
	})
	setProgressCancelable(progressScope, true)

	local canceled = false

	for index, photo in ipairs(photos) do
		progressScope:setPortionComplete(index - 1, #photos)
		progressScope:setCaption(string.format("Scanning photo %d of %d...", index, #photos))

		if isProgressCanceled(progressScope) then
			canceled = true
			break
		end

		addIdentifiedSpeciesRows(rows, seen, photo)
	end

	progressScope:done()

	if canceled then
		outputToLog("Identified species CSV export cancelled during catalog scan")
		LrDialogs.message("Export Stopped", "No CSV was written.", "info")
		return
	end

	local success, err = writeFile(savePath, buildCsv(rows))
	if not success then
		LrDialogs.message(
			"Could Not Save CSV",
			"Lightroom could not write the file. Try choosing a different folder or filename.\n\nDetails: " .. tostring(err),
			"critical"
		)
		return
	end

	LrDialogs.message(
		"Species CSV Ready",
		string.format(
			"Saved %d unique species row(s) from your selected photos to %s.",
			#rows,
			LrPathUtils.leafName(savePath)
		),
		"info"
	)
end

LrTasks.startAsyncTask(function()
	local success, err = LrTasks.pcall(exportIdentifiedSpeciesCsv)
	if not success then
		LrDialogs.message(
			"Could Not Export Species CSV",
			"Something went wrong while creating the CSV.\n\nDetails: " .. tostring(err),
			"critical"
		)
	end
end)
