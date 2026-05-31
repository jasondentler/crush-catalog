local LrApplication = import("LrApplication")
local LrBinding = import("LrBinding")
local LrColor = import("LrColor")
local LrDialogs = import("LrDialogs")
local LrFunctionContext = import("LrFunctionContext")
local LrHttp = import("LrHttp")
local LrLogger = import("LrLogger")
local LrPathUtils = import("LrPathUtils")
local LrProgressScope = import("LrProgressScope")
local LrPrefs = import("LrPrefs")
local LrTasks = import("LrTasks")
local LrView = import("LrView")
local JSON = require("JSON")
local MetadataHelpers = require("MetadataHelpers")

local myLogger = LrLogger("com.jasondentler.crushcatalog.ExportEBirdRecordCsvAction")
myLogger:enable("logfile")

local ExportEBirdRecordCsvAction = {}

local DEFAULT_BACKEND_URL = "http://127.0.0.1:8000/identify"
local PRIMARY_PURPOSE_HELP_URL = "https://support.ebird.org/en/support/solutions/articles/48000967748-birding-as-your-primary-purpose-and-complete-checklists"
local COMPLETE_CHECKLIST_HELP_URL = "https://support.ebird.org/en/support/solutions/articles/48000967748-birding-as-your-primary-purpose-and-complete-checklists#anchorCompleteChecklists"
local PROTOCOL_GUIDE_URL = "https://support.ebird.org/en/support/solutions/articles/48000950859#anchorQuickProtocols"
local METERS_PER_MILE = 1609.344
local STATIONARY_THRESHOLD_METERS = 30
local LIGHTROOM_EPOCH_OFFSET = 978307200
local MONTH_NAMES = {
	"January",
	"February",
	"March",
	"April",
	"May",
	"June",
	"July",
	"August",
	"September",
	"October",
	"November",
	"December",
}
local WEEKDAY_NAMES = {
	"Sunday",
	"Monday",
	"Tuesday",
	"Wednesday",
	"Thursday",
	"Friday",
	"Saturday",
}
local NO_LOCATION_TEXT = "No location specified"
local EBIRD_RECORD_HEADERS = {
	"Common Name",
	"Genus",
	"Species",
	"Number",
	"Species Comments",
	"Location Name",
	"Latitude",
	"Longitude",
	"Date",
	"Start Time",
	"State/Province",
	"Country",
	"Protocol",
	"Number of Observers",
	"Duration",
	"All Observations Reported",
	"Distance Traveled Miles",
	"Effort Area Acres",
	"Submission Comments",
}
local PRIMARY_PURPOSE_PROTOCOL_OPTIONS = {
	{ title = "Stationary", value = "Stationary" },
	{ title = "Traveling", value = "Traveling" },
	{ title = "Historical", value = "Historical" },
}
local INCIDENTAL_PROTOCOL_OPTIONS = {
	{ title = "Incidental", value = "Incidental" },
}
math.randomseed(os.time())

local function outputToLog(message)
	myLogger:trace(message)
end

local function getPrefs()
	return LrPrefs.prefsForPlugin()
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

local function ebirdCsvValue(value)
	local text = tostring(value or "")
	text = text:gsub('"', "'")
	text = text:gsub("[\r\n]+", " ")
	text = text:gsub(",", " ")
	return trim(text)
end

local function csvLine(values)
	local escaped = {}
	for _, value in ipairs(values) do
		table.insert(escaped, ebirdCsvValue(value))
	end
	return table.concat(escaped, ",")
end

local function backendLocationUrl()
	local backendUrl = tostring(getPrefs().backendUrl or DEFAULT_BACKEND_URL)
	if backendUrl == "" then
		backendUrl = DEFAULT_BACKEND_URL
	end

	local locationUrl, replacements = backendUrl:gsub("/identify$", "/location")
	if replacements > 0 then
		return locationUrl
	end

	return backendUrl:gsub("/+$", "") .. "/location"
end

local function lookupBackendLocation(gps, locationCache)
	if not gps then
		return nil
	end

	local ebirdToken = trim(getPrefs().ebirdApiKey)
	if ebirdToken == "" then
		outputToLog("Skipping backend location lookup because no eBird API key is configured.")
		return nil
	end

	local cacheKey = string.format("%.4f,%.4f", gps.latitude, gps.longitude)
	if locationCache[cacheKey] ~= nil then
		return locationCache[cacheKey]
	end

	local payload = JSON:encode({
		latitude = gps.latitude,
		longitude = gps.longitude,
		ebird_token = ebirdToken,
	})
	local result, headers = LrHttp.post(backendLocationUrl(), payload, {
		{ field = "Content-Type", value = "application/json" },
	})

	if not result then
		outputToLog("Backend location lookup returned no response: " .. tostring(headers and headers.error and headers.error.name or "unknown error"))
		locationCache[cacheKey] = false
		return nil
	end

	local decoded = JSON:decode(result)
	local location = decoded and decoded.location or nil
	if not location then
		outputToLog(string.format(
			"Backend location lookup returned no location status=%s result=%s",
			tostring(headers and headers.status),
			tostring(result)
		))
		locationCache[cacheKey] = false
		return nil
	end

	locationCache[cacheKey] = location
	return location
end

local function fillMissingLocationFromBackend(photo, gps, locationName, regionCode, locationCache)
	if not gps or (locationName ~= "" and regionCode ~= "") then
		return locationName, regionCode
	end

	local originalLocationName = locationName
	local originalRegionCode = regionCode
	local location = lookupBackendLocation(gps, locationCache)
	if not location then
		return locationName, regionCode
	end

	if locationName == "" then
		locationName = trim(location.hotspot_name)
	end

	if regionCode == "" then
		regionCode = trim(location.region_code)
	end

	if locationName ~= originalLocationName or regionCode ~= originalRegionCode then
		MetadataHelpers.writeEbirdLocation(photo, regionCode, locationName)
	end

	return locationName, regionCode
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

local function getRawMetadata(photo, fieldId)
	local success, value = LrTasks.pcall(function()
		return photo:getRawMetadata(fieldId)
	end)

	if success then
		return value
	end

	outputToLog(string.format("Failed to read raw metadata fieldId=%s error=%s", tostring(fieldId), tostring(value)))
	return nil
end

local function getFormattedMetadata(photo, fieldId)
	local success, value = LrTasks.pcall(function()
		return photo:getFormattedMetadata(fieldId)
	end)

	if success then
		return value
	end

	outputToLog(string.format("Failed to read formatted metadata fieldId=%s error=%s", tostring(fieldId), tostring(value)))
	return nil
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

local function parseIsoDateTime(value)
	local text = tostring(value or "")
	local year, month, day, hour, minute = text:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)[T ](%d%d):(%d%d)")
	if not year then
		year, month, day = text:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)")
	end

	if not year then
		return nil
	end

	return {
		year = tonumber(year),
		month = tonumber(month),
		day = tonumber(day),
		hour = tonumber(hour),
		minute = tonumber(minute),
		sortValue = string.format("%s%s%s%s%s", year, month, day, hour or "00", minute or "00"),
	}
end

local function parseLightroomDateTime(value)
	local seconds = tonumber(value)
	if not seconds then
		return nil
	end

	local dateParts = os.date("!*t", seconds + LIGHTROOM_EPOCH_OFFSET)
	if not dateParts then
		return nil
	end

	return {
		year = dateParts.year,
		month = dateParts.month,
		day = dateParts.day,
		hour = dateParts.hour,
		minute = dateParts.min,
		sortValue = string.format("%04d%02d%02d%02d%02d", dateParts.year, dateParts.month, dateParts.day, dateParts.hour, dateParts.min),
	}
end

local function getPhotoDateTime(photo)
	return parseIsoDateTime(getRawMetadata(photo, "dateTimeOriginalISO8601"))
		or parseIsoDateTime(getRawMetadata(photo, "dateTimeISO8601"))
		or parseLightroomDateTime(getRawMetadata(photo, "dateTimeOriginal"))
		or parseLightroomDateTime(getRawMetadata(photo, "dateTime"))
end

local function formatDate(dateTime)
	if not dateTime then
		return ""
	end

	return string.format("%d/%d/%04d", dateTime.month, dateTime.day, dateTime.year)
end

local function formatTime(dateTime)
	if not dateTime or dateTime.hour == nil or dateTime.minute == nil then
		return ""
	end

	return string.format("%02d:%02d", dateTime.hour, dateTime.minute)
end

local function formatHumanTime(dateTime)
	if not dateTime or dateTime.hour == nil or dateTime.minute == nil then
		return ""
	end

	local hour = dateTime.hour
	local suffix = "AM"
	if hour >= 12 then
		suffix = "PM"
	end

	hour = hour % 12
	if hour == 0 then
		hour = 12
	end

	return string.format("%d:%02d %s", hour, dateTime.minute, suffix)
end

local function formatHumanDate(dateTime)
	if not dateTime then
		return "No capture date"
	end

	local timestamp = os.time({
		year = dateTime.year,
		month = dateTime.month,
		day = dateTime.day,
		hour = 12,
		min = 0,
		sec = 0,
	})
	local weekday = timestamp and WEEKDAY_NAMES[tonumber(os.date("%w", timestamp)) + 1] or ""
	local month = MONTH_NAMES[dateTime.month] or tostring(dateTime.month)

	return string.format("%s, %s %d, %04d", weekday, month, dateTime.day, dateTime.year)
end

local function dateKey(dateTime)
	if not dateTime then
		return ""
	end

	return string.format("%04d-%02d-%02d", dateTime.year, dateTime.month, dateTime.day)
end

local function regionParts(regionCode)
	local country, state, county = tostring(regionCode or ""):match("^(%a%a)%-([%a%d]+)%-?([%a%d]*)")
	return country or "", state or "", county or ""
end

local function getGps(photo)
	local gps = getRawMetadata(photo, "gps")
	if type(gps) ~= "table" then
		return nil
	end

	local latitude = tonumber(gps.latitude)
	local longitude = tonumber(gps.longitude)
	if not latitude or not longitude then
		return nil
	end

	return {
		latitude = latitude,
		longitude = longitude,
	}
end

local function getPhotoRating(photo)
	return tonumber(getRawMetadata(photo, "rating")) or 0
end

local function getPhotoPickStatus(photo)
	return tonumber(getRawMetadata(photo, "pickStatus")) or 0
end

local function parseDimensions(value)
	local width, height = tostring(value or ""):match("(%d+)%s*x%s*(%d+)")
	width = tonumber(width)
	height = tonumber(height)
	if not width or not height or width <= 0 or height <= 0 then
		return nil, nil
	end

	return width, height
end

local function getPhotoAspectRatioKey(photo)
	local width, height = parseDimensions(getFormattedMetadata(photo, "croppedDimensions"))
	if not width then
		width, height = parseDimensions(getFormattedMetadata(photo, "dimensions"))
	end

	if not width then
		return ""
	end

	local ratio = width / height
	return string.format("%.2f", math.floor(ratio * 20 + 0.5) / 20)
end

local function firstNonEmpty(...)
	for index = 1, select("#", ...) do
		local value = trim(select(index, ...))
		if value ~= "" then
			return value
		end
	end

	return ""
end

local function getPhotoCity(photo)
	return firstNonEmpty(
		getRawMetadata(photo, "city"),
		getRawMetadata(photo, "iptcCity"),
		getRawMetadata(photo, "location")
	)
end

local function getPhotoPostalCode(photo)
	return firstNonEmpty(
		getRawMetadata(photo, "postalCode"),
		getRawMetadata(photo, "iptcPostalCode")
	)
end

local function haversineMeters(a, b)
	local radiusMeters = 6371000
	local lat1 = math.rad(a.latitude)
	local lat2 = math.rad(b.latitude)
	local deltaLat = math.rad(b.latitude - a.latitude)
	local deltaLon = math.rad(b.longitude - a.longitude)
	local sinLat = math.sin(deltaLat / 2)
	local sinLon = math.sin(deltaLon / 2)
	local h = sinLat * sinLat + math.cos(lat1) * math.cos(lat2) * sinLon * sinLon
	local y = math.sqrt(h)
	local x = math.sqrt(1 - h)
	local angle = math.atan2 and math.atan2(y, x) or math.atan(y / x)
	return radiusMeters * 2 * angle
end

local function scientificParts(scientificName)
	local genus, species = trim(scientificName):match("^(%S+)%s+(.+)$")
	return genus or "", species or ""
end

local function addPhotoSpecies(checklist, commonNames, scientificNames)
	local maxCount = math.max(#commonNames, #scientificNames)

	for index = 1, maxCount do
		local commonName = commonNames[index] or ""
		local scientificName = scientificNames[index] or ""
		if commonName ~= "" or scientificName ~= "" then
			local key = table.concat({ commonName, scientificName }, "\31")
			if not checklist.speciesSeen[key] then
				table.insert(checklist.species, {
					commonName = commonName,
					scientificName = scientificName,
					key = key,
				})
				checklist.speciesSeen[key] = true
			end
		end
	end
end

local function speciesKey(commonName, scientificName)
	return table.concat({ commonName or "", scientificName or "" }, "\31")
end

local function recordHasSpecies(record, species)
	local maxCount = math.max(#record.commonNames, #record.scientificNames)

	for index = 1, maxCount do
		if speciesKey(record.commonNames[index] or "", record.scientificNames[index] or "") == species.key then
			return true
		end
	end

	return false
end

local function speciesGps(checklist, species, fallbackEffort)
	for _, record in ipairs(checklist.records) do
		if record.gps and recordHasSpecies(record, species) then
			return string.format("%.6f", record.gps.latitude), string.format("%.6f", record.gps.longitude)
		end
	end

	return fallbackEffort.latitude, fallbackEffort.longitude
end

local function newChecklist(groupKey, locationName, regionCode, country, state, county, dateText)
	return {
		key = groupKey,
		locationName = locationName,
		regionCode = regionCode,
		country = country,
		state = state,
		county = county,
		dateText = dateText,
		city = "",
		postalCode = "",
		photos = {},
		records = {},
		species = {},
		speciesSeen = {},
	}
end

local function collectPhotoRecords(photos, progressScope)
	local records = {}
	local locationCache = {}
	local canceled = false

	for index, photo in ipairs(photos) do
		progressScope:setPortionComplete(index - 1, #photos)
		progressScope:setCaption(string.format("Reading photo %d of %d...", index, #photos))

		if isProgressCanceled(progressScope) then
			canceled = true
			break
		end

		local commonNames = splitCsvMetadata(getPluginProperty(photo, "birdCommonNames"))
		local scientificNames = splitCsvMetadata(getPluginProperty(photo, "birdScientificNames"))
		if #commonNames > 0 or #scientificNames > 0 then
			local dateTime = getPhotoDateTime(photo)
			local gps = getGps(photo)
			local regionCode = trim(getPluginProperty(photo, "ebirdRegionCode"))
			local locationName = trim(getPluginProperty(photo, "ebirdHotspotName"))
			locationName, regionCode = fillMissingLocationFromBackend(photo, gps, locationName, regionCode, locationCache)
			local country, state, county = regionParts(regionCode)

			table.insert(records, {
				photo = photo,
				commonNames = commonNames,
				scientificNames = scientificNames,
				dateTime = dateTime,
				gps = gps,
				regionCode = regionCode,
				locationName = locationName,
				country = country,
				state = state,
				county = county,
				city = getPhotoCity(photo),
				postalCode = getPhotoPostalCode(photo),
				rating = getPhotoRating(photo),
				pickStatus = getPhotoPickStatus(photo),
				aspectRatioKey = getPhotoAspectRatioKey(photo),
			})
		end
	end

	return records, canceled
end

local function hasSavedLocation(record)
	return trim(record.locationName) ~= ""
end

local function hasCompleteLocation(record)
	return record.gps ~= nil and hasSavedLocation(record)
end

local function isMissingLocation(record)
	return record.dateTime ~= nil and record.gps == nil and not hasSavedLocation(record)
end

local function locationKey(record)
	return table.concat({
		record.locationName or "",
		record.regionCode or "",
		record.country or "",
		record.state or "",
		record.county or "",
		dateKey(record.dateTime),
	}, "\31")
end

local function matchingBoundaryLocation(leftRecord, rightRecord)
	if not leftRecord or not rightRecord then
		return false
	end

	return hasCompleteLocation(leftRecord) and hasCompleteLocation(rightRecord) and locationKey(leftRecord) == locationKey(rightRecord)
end

local function locationSummary(record)
	local parts = {}
	if trim(record.locationName) ~= "" then
		table.insert(parts, record.locationName)
	end
	if trim(record.regionCode) ~= "" then
		table.insert(parts, record.regionCode)
	end
	if #parts == 0 and record.gps then
		table.insert(parts, string.format("%.6f, %.6f", record.gps.latitude, record.gps.longitude))
	end

	return table.concat(parts, ", ")
end

local function checklistLocationSummary(checklist)
	local parts = {}

	if trim(checklist.locationName) ~= "" then
		table.insert(parts, checklist.locationName)
	end

	if trim(checklist.city) ~= "" then
		table.insert(parts, checklist.city)
	end

	if trim(checklist.county) ~= "" then
		table.insert(parts, checklist.county)
	end

	if trim(checklist.state) ~= "" then
		table.insert(parts, checklist.state)
	end

	if trim(checklist.postalCode) ~= "" then
		table.insert(parts, checklist.postalCode)
	end

	if #parts == 0 then
		return NO_LOCATION_TEXT
	end

	return table.concat(parts, ", ")
end

local function recordTimeSummary(record)
	if not record or not record.dateTime then
		return "unknown time"
	end

	local time = formatHumanTime(record.dateTime)
	if time == "" then
		return formatHumanDate(record.dateTime)
	end

	return formatHumanDate(record.dateTime) .. ", " .. time
end

local function gapPhotoCount(gaps)
	local count = 0
	for _, gap in ipairs(gaps or {}) do
		count = count + #gap.missingRecords
	end

	return count
end

local function promptUseBoundaryLocations(gaps, checklist)
	return LrFunctionContext.callWithContext("promptUseBoundaryLocations", function(context)
		local f = LrView.osFactory()
		local count = gapPhotoCount(gaps)
		local firstGap = gaps[1]
		local lastGap = gaps[#gaps]
		local contents = f:column {
			spacing = 10,
			f:static_text {
				title = string.format("%d photo(s) between located photos have no GPS or saved hotspot.", count),
				width_in_chars = 72,
			},
			f:static_text {
				title = "Location: " .. checklistLocationSummary(checklist),
				width_in_chars = 72,
			},
			f:static_text {
				title = string.format("Checklist photos: %d", #checklist.photos),
				width_in_chars = 72,
			},
			f:static_text {
				title = "From: " .. recordTimeSummary(firstGap.leftRecord),
				width_in_chars = 72,
			},
			f:static_text {
				title = "To: " .. recordTimeSummary(lastGap.rightRecord),
				width_in_chars = 72,
			},
			f:static_text {
				title = "Include all of these photos in this checklist?",
				width_in_chars = 72,
			},
		}

		local result = LrDialogs.presentModalDialog({
			title = "Include Gap Photos?",
			contents = contents,
			actionVerb = "Include Photos",
			cancelVerb = "Leave Unchanged",
		})

		return result == "ok"
	end)
end

local function copyBoundaryLocation(record, boundaryRecord)
	record.gps = boundaryRecord.gps
	record.regionCode = boundaryRecord.regionCode
	record.locationName = boundaryRecord.locationName
	record.country = boundaryRecord.country
	record.state = boundaryRecord.state
	record.county = boundaryRecord.county
	record.city = boundaryRecord.city
	record.postalCode = boundaryRecord.postalCode
	record.inferredLocation = true
end

local function copyChecklistLocation(record, checklist)
	local sourcePhoto = checklist.photos[1]
	record.gps = sourcePhoto and sourcePhoto.gps or nil
	record.regionCode = checklist.regionCode
	record.locationName = checklist.locationName
	record.country = checklist.country
	record.state = checklist.state
	record.county = checklist.county
	record.city = checklist.city
	record.postalCode = checklist.postalCode
	record.inferredLocation = true
end

local function detectLocationGaps(records)
	local timedRecords = {}
	for _, record in ipairs(records) do
		if record.dateTime and record.dateTime.sortValue then
			table.insert(timedRecords, record)
		end
	end

	table.sort(timedRecords, function(a, b)
		return tostring(a.dateTime and a.dateTime.sortValue or "") < tostring(b.dateTime and b.dateTime.sortValue or "")
	end)

	local gaps = {}
	local index = 1
	while index <= #timedRecords do
		if isMissingLocation(timedRecords[index]) then
			local startIndex = index
			local missingRecords = {}
			while index <= #timedRecords and isMissingLocation(timedRecords[index]) do
				table.insert(missingRecords, timedRecords[index])
				index = index + 1
			end

			local leftRecord = timedRecords[startIndex - 1]
			local rightRecord = timedRecords[index]
			if matchingBoundaryLocation(leftRecord, rightRecord) then
				local gap = {
					missingRecords = missingRecords,
					leftRecord = leftRecord,
					rightRecord = rightRecord,
					targetKey = table.concat({
						leftRecord.locationName,
						leftRecord.regionCode,
						leftRecord.state,
						leftRecord.country,
						dateKey(leftRecord.dateTime),
					}, "\31"),
					answered = false,
				}
				table.insert(gaps, gap)
				for _, missingRecord in ipairs(missingRecords) do
					missingRecord.pendingLocationGap = gap
				end
			end
		else
			index = index + 1
		end
	end

	return gaps
end

local function buildChecklistsFromRecords(records)
	local checklists = {}
	local checklistsByKey = {}

	for _, record in ipairs(records) do
		local photoDateKey = dateKey(record.dateTime)
		local groupKey = table.concat({ record.locationName, record.regionCode, record.state, record.country, photoDateKey }, "\31")

		local checklist = checklistsByKey[groupKey]
		if not checklist then
			checklist = newChecklist(groupKey, record.locationName, record.regionCode, record.country, record.state, record.county, formatDate(record.dateTime))
			checklistsByKey[groupKey] = checklist
			table.insert(checklists, checklist)
		end

		if checklist.city == "" then
			checklist.city = record.city
		end

		if checklist.postalCode == "" then
			checklist.postalCode = record.postalCode
		end

		table.insert(checklist.records, record)
		table.insert(checklist.photos, {
			photo = record.photo,
			dateTime = record.dateTime,
			gps = record.gps,
			rating = record.rating,
			pickStatus = record.pickStatus,
			aspectRatioKey = record.aspectRatioKey,
			inferredLocation = record.inferredLocation == true,
		})
		addPhotoSpecies(checklist, record.commonNames, record.scientificNames)
	end

	table.sort(checklists, function(a, b)
		local aSortValue = ""
		local bSortValue = ""

		for _, photo in ipairs(a.photos) do
			local sortValue = tostring(photo.dateTime and photo.dateTime.sortValue or "")
			if sortValue ~= "" and (aSortValue == "" or sortValue < aSortValue) then
				aSortValue = sortValue
			end
		end

		for _, photo in ipairs(b.photos) do
			local sortValue = tostring(photo.dateTime and photo.dateTime.sortValue or "")
			if sortValue ~= "" and (bSortValue == "" or sortValue < bSortValue) then
				bSortValue = sortValue
			end
		end

		return aSortValue < bSortValue
	end)

	return checklists
end

local function sortedPhotos(checklist)
	local photos = {}
	for _, photo in ipairs(checklist.photos) do
		table.insert(photos, photo)
	end

	table.sort(photos, function(a, b)
		return tostring(a.dateTime and a.dateTime.sortValue or "") < tostring(b.dateTime and b.dateTime.sortValue or "")
	end)

	return photos
end

local function summarizeChecklistEffort(checklist)
	local photos = sortedPhotos(checklist)
	local earliest = photos[1] and photos[1].dateTime or nil
	local latest = photos[#photos] and photos[#photos].dateTime or nil
	local allHaveGps = #photos > 0
	local allHaveTime = #photos > 0
	local firstGps = nil
	local totalDistanceMeters = 0
	local previousGps = nil

	for _, photo in ipairs(photos) do
		if not photo.gps then
			allHaveGps = false
		end

		if not photo.dateTime or photo.dateTime.hour == nil or photo.dateTime.minute == nil then
			allHaveTime = false
		end

		if photo.gps and not firstGps then
			firstGps = photo.gps
		end

		if photo.gps and previousGps then
			totalDistanceMeters = totalDistanceMeters + haversineMeters(previousGps, photo.gps)
		end

		if photo.gps then
			previousGps = photo.gps
		end
	end

	local duration = ""
	if #photos > 1 and earliest and latest and earliest.sortValue and latest.sortValue then
		local startMinutes = (earliest.hour or 0) * 60 + (earliest.minute or 0)
		local endMinutes = (latest.hour or 0) * 60 + (latest.minute or 0)
		duration = tostring(math.max(0, endMinutes - startMinutes))
	end

	local distanceMiles = ""
	if #photos > 1 and allHaveGps then
		distanceMiles = string.format("%.2f", totalDistanceMeters / METERS_PER_MILE)
	end

	return {
		photoCount = #photos,
		startDateTime = earliest,
		startTime = formatTime(earliest),
		latitude = firstGps and string.format("%.6f", firstGps.latitude) or "",
		longitude = firstGps and string.format("%.6f", firstGps.longitude) or "",
		duration = duration,
		distanceMiles = distanceMiles,
		allHaveGps = allHaveGps,
		allHaveTime = allHaveTime,
		totalDistanceMeters = totalDistanceMeters,
	}
end

local function humanTimeSummary(checklist)
	local photos = sortedPhotos(checklist)
	local earliest = photos[1] and photos[1].dateTime or nil
	local latest = photos[#photos] and photos[#photos].dateTime or nil

	if not earliest then
		return "No capture date or time"
	end

	local startDate = formatHumanDate(earliest)
	local startTime = formatHumanTime(earliest)
	local endTime = formatHumanTime(latest)

	if startTime == "" then
		return startDate .. " (time unknown)"
	end

	if not latest or latest.sortValue == earliest.sortValue or endTime == "" or endTime == startTime then
		return startDate .. ", " .. startTime
	end

	if dateKey(latest) ~= dateKey(earliest) then
		return startDate .. ", " .. startTime .. " to " .. formatHumanDate(latest) .. ", " .. endTime
	end

	return startDate .. ", " .. startTime .. " to " .. endTime
end

local function distanceSummary(effort)
	if not effort.allHaveGps then
		return "Not available"
	end

	if effort.distanceMiles == "" then
		return "0.00 miles"
	end

	return effort.distanceMiles .. " miles"
end

local function detailRow(f, label, value, valueFont)
	return f:row {
		spacing = 8,
		f:static_text {
			title = label,
			alignment = "right",
			width_in_chars = 10,
		},
		f:static_text {
			title = value,
			alignment = "left",
			width_in_chars = 62,
			font = valueFont or "<system>",
		},
	}
end

local function distanceSummaryView(f, effort)
	local summary = distanceSummary(effort)
	local font = summary == "Not available" and { name = "Helvetica Neue Italic", size = "regular" } or "<system>"

	return detailRow(f, "Distance", summary, font)
end

local function sortedSamplePhotos(checklist)
	local photos = sortedPhotos(checklist)
	return photos
end

local function shuffledPhotos(photos)
	local shuffled = {}
	for _, photo in ipairs(photos) do
		table.insert(shuffled, photo)
	end

	for index = #shuffled, 2, -1 do
		local swapIndex = math.random(index)
		shuffled[index], shuffled[swapIndex] = shuffled[swapIndex], shuffled[index]
	end

	return shuffled
end

local function addPhotos(chosen, candidates, count)
	for _, photo in ipairs(candidates) do
		if #chosen >= count then
			return
		end

		table.insert(chosen, photo)
	end
end

local function photosByAspect(candidates, aspectRatioKey)
	local matching = {}
	local other = {}

	for _, photo in ipairs(candidates) do
		if aspectRatioKey ~= "" and photo.aspectRatioKey == aspectRatioKey then
			table.insert(matching, photo)
		else
			table.insert(other, photo)
		end
	end

	local ordered = {}
	for _, photo in ipairs(shuffledPhotos(matching)) do
		table.insert(ordered, photo)
	end
	for _, photo in ipairs(shuffledPhotos(other)) do
		table.insert(ordered, photo)
	end

	return ordered
end

local function mostCommonAspectRatioKey(photos)
	local counts = {}
	local bestKey = ""
	local bestCount = 0

	for _, photo in ipairs(photos) do
		local key = photo.aspectRatioKey or ""
		if key ~= "" then
			counts[key] = (counts[key] or 0) + 1
			if counts[key] > bestCount then
				bestKey = key
				bestCount = counts[key]
			end
		end
	end

	return bestKey
end

local function priorityGroups(photos)
	local groups = {
		{},
		{},
		{},
		{},
		{},
		{},
		{},
		{},
	}

	for _, photo in ipairs(photos) do
		if photo.pickStatus == 1 then
			table.insert(groups[1], photo)
		elseif photo.pickStatus == -1 then
			table.insert(groups[8], photo)
		elseif photo.rating and photo.rating > 0 then
			local rating = math.min(5, math.max(1, photo.rating))
			table.insert(groups[7 - rating], photo)
		else
			table.insert(groups[7], photo)
		end
	end

	return groups
end

local function favoritePhotos(checklist, count)
	local groups = priorityGroups(sortedSamplePhotos(checklist))
	local chosen = {}
	local aspectRatioKey = ""

	for _, group in ipairs(groups) do
		if #chosen >= count then
			break
		end

		if #group > 0 then
			if aspectRatioKey == "" then
				aspectRatioKey = mostCommonAspectRatioKey(group)
			end

			addPhotos(chosen, photosByAspect(group, aspectRatioKey), count)
		end
	end

	return chosen
end

local function photoSampleView(f, checklist)
	local photos = favoritePhotos(checklist, 5)
	local rowItems = {
		spacing = 8,
	}

	for _, photo in ipairs(photos) do
		table.insert(rowItems, f:catalog_photo {
			photo = photo.photo,
			width = 132,
			height = 132,
		})
	end

	if #photos == 0 then
		table.insert(rowItems, f:static_text {
			title = "",
			width_in_chars = 18,
		})
	end

	return f:row(rowItems)
end

local function addressSummary(checklist)
	return checklistLocationSummary(checklist)
end

local function labeledControlRow(f, label, control, extraControl)
	local rowItems = {
		spacing = 8,
		f:static_text {
			title = label,
			alignment = "right",
			width_in_chars = 10,
		},
		control,
	}

	if extraControl then
		table.insert(rowItems, extraControl)
	end

	return f:row(rowItems)
end

local function whereSummaryView(f, checklist)
	local summary = addressSummary(checklist)
	local isMissingLocation = summary == NO_LOCATION_TEXT
	local font = isMissingLocation and { name = "Helvetica Neue Italic", size = "regular" } or "<system>"

	return detailRow(f, "Where", summary, font)
end

local function helpLink(f, url)
	return f:static_text {
		title = "?",
		alignment = "center",
		width_in_chars = 2,
		text_color = LrColor(0.1, 0.35, 0.8),
		mouse_down = function()
			LrTasks.pcall(function()
				LrHttp.openUrlInBrowser(url)
			end)
		end,
	}
end

local function inferProtocol(settings, effort)
	if not settings.primaryPurpose then
		return "Incidental"
	end

	if not effort.allHaveGps or not effort.allHaveTime then
		return "Historical"
	end

	if effort.totalDistanceMeters <= STATIONARY_THRESHOLD_METERS then
		return "Stationary"
	end

	return "Traveling"
end

local function promptChecklistSettings(checklist, checklistIndex, checklistCount)
	return LrFunctionContext.callWithContext("promptChecklistSettings", function(context)
		local f = LrView.osFactory()
		local props = LrBinding.makePropertyTable(context)
		local effort = summarizeChecklistEffort(checklist)
		props.primaryPurpose = true
		props.allObservationsReported = true
		props.protocol = inferProtocol({ primaryPurpose = true }, effort)
		local allObservationsEnabled = LrView.bind {
			key = "primaryPurpose",
			transform = function(value)
				return value == true
			end,
		}
		local protocolOptions = LrView.bind {
			key = "primaryPurpose",
			transform = function(value)
				if value == true then
					if props.protocol == "Incidental" then
						props.protocol = inferProtocol({ primaryPurpose = true }, effort)
					end
					return PRIMARY_PURPOSE_PROTOCOL_OPTIONS
				end

				props.protocol = "Incidental"
				return INCIDENTAL_PROTOCOL_OPTIONS
			end,
		}

		local contents = f:column {
			spacing = 12,
			bind_to_object = props,
			detailRow(f, "Checklist", string.format("#%d of %d", checklistIndex, checklistCount)),
			detailRow(f, "When", humanTimeSummary(checklist)),
			whereSummaryView(f, checklist),
			distanceSummaryView(f, effort),
			detailRow(f, "Photos", tostring(#checklist.photos)),
			photoSampleView(f, checklist),
			f:row {
				spacing = 6,
				f:checkbox {
					title = "Birding was my primary purpose",
					value = LrView.bind("primaryPurpose"),
				},
				helpLink(f, PRIMARY_PURPOSE_HELP_URL),
			},
			f:row {
				spacing = 6,
				f:checkbox {
					title = "All observations are reported for this checklist",
					value = LrView.bind("allObservationsReported"),
					enabled = allObservationsEnabled,
				},
				helpLink(f, COMPLETE_CHECKLIST_HELP_URL),
			},
			labeledControlRow(
				f,
				"Protocol",
				f:popup_menu {
					items = protocolOptions,
					value = LrView.bind("protocol"),
					width_in_chars = 12,
				},
				helpLink(f, PROTOCOL_GUIDE_URL)
			),
		}

		local result = LrDialogs.presentModalDialog({
			title = "eBird Checklist Details",
			contents = contents,
			props = props,
			actionVerb = "Use These Details",
			cancelVerb = "Cancel Export",
		})

		if result ~= "ok" then
			return nil
		end

		return {
			primaryPurpose = props.primaryPurpose == true,
			allObservationsReported = props.allObservationsReported == true,
			protocol = props.protocol or "Incidental",
		}
	end)
end

local function gapsByTargetKey(gaps)
	local byKey = {}
	for _, gap in ipairs(gaps) do
		if not byKey[gap.targetKey] then
			byKey[gap.targetKey] = {}
		end
		table.insert(byKey[gap.targetKey], gap)
	end

	return byKey
end

local function checklistIsOnlyPendingGap(checklist)
	if #checklist.records == 0 then
		return false
	end

	for _, record in ipairs(checklist.records) do
		if not record.pendingLocationGap or record.pendingLocationGap.answered then
			return false
		end
	end

	return true
end

local function checklistHasGps(checklist)
	for _, photo in ipairs(checklist.photos) do
		if photo.gps then
			return true
		end
	end

	return false
end

local function isBlankLocationChecklist(checklist)
	return trim(checklist.locationName) == "" and not checklistHasGps(checklist)
end

local function checklistChoiceTitle(checklist)
	local photos = sortedPhotos(checklist)
	local earliest = photos[1] and photos[1].dateTime or nil
	local latest = photos[#photos] and photos[#photos].dateTime or nil
	local startTime = formatHumanTime(earliest)
	local endTime = formatHumanTime(latest)
	local when = startTime
	if startTime == "" then
		when = "Time unknown"
	elseif latest and latest.sortValue ~= earliest.sortValue and endTime ~= "" and endTime ~= startTime then
		when = startTime .. " to " .. endTime
	end
	local where = addressSummary(checklist)
	if where == NO_LOCATION_TEXT then
		where = "No location"
	end

	return string.format("%s | %s | %d photo(s)", when, where, #checklist.photos)
end

local function dateTimeMinutes(dateTime)
	if not dateTime or dateTime.hour == nil or dateTime.minute == nil then
		return nil
	end

	return dateTime.hour * 60 + dateTime.minute
end

local function checklistStartEndMinutes(checklist)
	local photos = sortedPhotos(checklist)
	return dateTimeMinutes(photos[1] and photos[1].dateTime or nil), dateTimeMinutes(photos[#photos] and photos[#photos].dateTime or nil)
end

local function nearestMergeChecklistKey(checklists, blankChecklist)
	local blankStart, blankEnd = checklistStartEndMinutes(blankChecklist)
	if not blankStart and not blankEnd then
		return ""
	end

	local bestKey = ""
	local bestDistance = nil
	for _, checklist in ipairs(checklists) do
		if
			checklist.key ~= blankChecklist.key
			and not isBlankLocationChecklist(checklist)
			and checklist.dateText == blankChecklist.dateText
		then
			local candidateStart, candidateEnd = checklistStartEndMinutes(checklist)
			local distance = nil
			if candidateEnd and blankStart and candidateEnd <= blankStart then
				distance = blankStart - candidateEnd
			elseif candidateStart and blankEnd and candidateStart >= blankEnd then
				distance = candidateStart - blankEnd
			elseif candidateStart and blankStart then
				distance = math.abs(candidateStart - blankStart)
			end

			if distance and (not bestDistance or distance < bestDistance) then
				bestDistance = distance
				bestKey = checklist.key
			end
		end
	end

	return bestKey
end

local function mergeChecklistOptions(checklists, blankChecklist)
	local items = {
		{ title = string.format("Keep as a separate locationless checklist (%d photo(s))", #blankChecklist.photos), value = "" },
	}

	for _, checklist in ipairs(checklists) do
		if
			checklist.key ~= blankChecklist.key
			and not isBlankLocationChecklist(checklist)
			and checklist.dateText == blankChecklist.dateText
		then
			table.insert(items, {
				title = checklistChoiceTitle(checklist),
				value = checklist.key,
			})
		end
	end

	return items
end

local function promptMergeBlankLocationChecklist(blankChecklist, checklists)
	local items = mergeChecklistOptions(checklists, blankChecklist)
	if #items == 1 then
		return "", false
	end
	local defaultTargetKey = nearestMergeChecklistKey(checklists, blankChecklist)

	return LrFunctionContext.callWithContext("promptMergeBlankLocationChecklist", function(context)
		local f = LrView.osFactory()
		local props = LrBinding.makePropertyTable(context)
		props.targetChecklistKey = defaultTargetKey
		local contents = f:column {
			spacing = 10,
			bind_to_object = props,
			detailRow(f, "When", humanTimeSummary(blankChecklist)),
			detailRow(f, "Photos", tostring(#blankChecklist.photos)),
			photoSampleView(f, blankChecklist),
			f:static_text {
				title = "Choose an existing checklist to include them in, or keep them separate.",
				width_in_chars = 72,
			},
			f:popup_menu {
				items = items,
				value = LrView.bind("targetChecklistKey"),
				width_in_chars = 52,
			},
		}

		local result = LrDialogs.presentModalDialog({
			title = "Locationless Photos",
			contents = contents,
			props = props,
			actionVerb = "Continue",
			cancelVerb = "Cancel Export",
		})

		if result ~= "ok" then
			return nil, true
		end

		return props.targetChecklistKey or "", false
	end)
end

local function checklistByKey(checklists)
	local byKey = {}
	for _, checklist in ipairs(checklists) do
		byKey[checklist.key] = checklist
	end

	return byKey
end

local function promptLocationGapsForChecklist(checklist, gapsForChecklist)
	local unresolvedGaps = {}
	for _, gap in ipairs(gapsForChecklist or {}) do
		if not gap.answered then
			table.insert(unresolvedGaps, gap)
		end
	end

	if #unresolvedGaps == 0 then
		return
	end

	if promptUseBoundaryLocations(unresolvedGaps, checklist) then
		for _, gap in ipairs(unresolvedGaps) do
			for _, missingRecord in ipairs(gap.missingRecords) do
				copyBoundaryLocation(missingRecord, gap.leftRecord)
			end
		end
	end

	for _, gap in ipairs(unresolvedGaps) do
		gap.answered = true
	end
end

local function resolveBlankLocationChecklists(records, checklists)
	local changed = false
	local byKey = checklistByKey(checklists)

	for _, checklist in ipairs(checklists) do
		if isBlankLocationChecklist(checklist) then
			local targetKey, canceled = promptMergeBlankLocationChecklist(checklist, checklists)
			if canceled then
				return nil, true
			end

			if targetKey ~= "" then
				local targetChecklist = byKey[targetKey]
				if targetChecklist then
					for _, record in ipairs(checklist.records) do
						copyChecklistLocation(record, targetChecklist)
					end
					changed = true
				end
			end
		end
	end

	if changed then
		return buildChecklistsFromRecords(records), false
	end

	return checklists, false
end

local function collectChecklistSettingsAndResolveGaps(records, initialChecklists, gaps)
	local settingsByKey = {}
	local gapsForKey = gapsByTargetKey(gaps)

	for checklistIndex, checklist in ipairs(initialChecklists) do
		if not checklistIsOnlyPendingGap(checklist) and not isBlankLocationChecklist(checklist) then
			local settings = promptChecklistSettings(checklist, checklistIndex, #initialChecklists)
			if not settings then
				return nil, nil, true
			end

			settingsByKey[checklist.key] = settings
			promptLocationGapsForChecklist(checklist, gapsForKey[checklist.key])
		end
	end

	local finalChecklists = buildChecklistsFromRecords(records)
	local resolvedChecklists, mergeCanceled = resolveBlankLocationChecklists(records, finalChecklists)
	if mergeCanceled then
		return nil, nil, true
	end
	finalChecklists = resolvedChecklists

	for checklistIndex, checklist in ipairs(finalChecklists) do
		if not settingsByKey[checklist.key] then
			local settings = promptChecklistSettings(checklist, checklistIndex, #finalChecklists)
			if not settings then
				return nil, nil, true
			end

			settingsByKey[checklist.key] = settings
		end
	end

	return finalChecklists, settingsByKey, false
end

local function buildRows(checklists, settingsByKey)
	local lines = {
		csvLine(EBIRD_RECORD_HEADERS),
	}

	for _, checklist in ipairs(checklists) do
		local effort = summarizeChecklistEffort(checklist)
		local settings = settingsByKey[checklist.key] or {
			primaryPurpose = true,
			allObservationsReported = true,
			protocol = inferProtocol({ primaryPurpose = true }, effort),
		}
		local protocol = settings.protocol or inferProtocol(settings, effort)
		local allObservationsReported = "N"
		if protocol ~= "Incidental" and settings.allObservationsReported then
			allObservationsReported = "Y"
		end

		for _, species in ipairs(checklist.species) do
			local genus, speciesName = scientificParts(species.scientificName)
			local latitude, longitude = speciesGps(checklist, species, effort)
			table.insert(lines, csvLine({
				species.commonName,
				genus,
				speciesName,
				"x",
				"",
				checklist.locationName,
				latitude,
				longitude,
				checklist.dateText,
				effort.startTime,
				checklist.state,
				checklist.country,
				protocol,
				"1",
				effort.duration,
				allObservationsReported,
				effort.distanceMiles,
				"",
				"",
			}))
		end
	end

	return lines, false
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

function ExportEBirdRecordCsvAction.export()
	local catalog = LrApplication.activeCatalog()
	local photos = catalog:getTargetPhotos()

	if #photos == 0 then
		LrDialogs.message(
			"Select Photos First",
			"Choose the photos you want included in the eBird CSV, then run the export again.",
			"info"
		)
		return
	end

	local savePath = LrDialogs.runSavePanel({
		title = "Export eBird Record CSV",
		prompt = "Export",
		requiredFileType = "csv",
		canCreateDirectories = true,
	})

	if not savePath then
		outputToLog("eBird record CSV export cancelled")
		return
	end

	local progressScope = LrProgressScope({
		title = "Gathering Data for CSV Export",
	})
	setProgressCancelable(progressScope, true)

	local records, canceled = collectPhotoRecords(photos, progressScope)
	progressScope:done()

	if canceled then
		outputToLog("eBird record CSV export cancelled during photo scan")
		LrDialogs.message("Export Stopped", "No CSV was written.", "info")
		return
	end

	local gaps = detectLocationGaps(records)
	local initialChecklists = buildChecklistsFromRecords(records)

	if #initialChecklists == 0 then
		LrDialogs.message(
			"No Species To Export",
			"The selected photos do not have any identified Crush Catalog species yet.",
			"info"
		)
		return
	end

	local checklists, settingsByKey, promptCanceled = collectChecklistSettingsAndResolveGaps(records, initialChecklists, gaps)
	if promptCanceled then
		outputToLog("eBird record CSV export cancelled during checklist prompts")
		return
	end

	local lines = buildRows(checklists, settingsByKey)

	local success, err = writeFile(savePath, table.concat(lines, "\n") .. "\n")
	if not success then
		LrDialogs.message(
			"Could Not Save CSV",
			"Lightroom could not write the file. Try choosing a different folder or filename.\n\nDetails: " .. tostring(err),
			"critical"
		)
		return
	end

	LrDialogs.message(
		"eBird CSV Ready",
		string.format(
			"Saved %d species row(s) across %d checklist group(s) to %s.",
			math.max(0, #lines - 1),
			#checklists,
			LrPathUtils.leafName(savePath)
		),
		"info"
	)
end

return ExportEBirdRecordCsvAction
