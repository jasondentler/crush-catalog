local LrExportSession = import("LrExportSession")
local LrPathUtils = import("LrPathUtils")
local LrTasks = import("LrTasks")
local LrApplication = import("LrApplication")
local LrDialogs = import("LrDialogs")
local LrFileUtils = import("LrFileUtils")
local LrUUID = import("LrUUID")
local JSON = require("JSON")
local CommandHelpers = require("CommandHelpers")

local ImageHelpers = {}

local function isTableEmpty(t)
	return t == nil or next(t) == nil
end

--- Exports photos (in a table) to a temp location and return a table of the full paths
--- This should probably be run within an LrTask
---@param photos table the catalog photos to be exported
---@return table of results { photo, photoIdentifier, originalPhotoPath, exportedJpegPath, errorMessage } (only exportedJpegPath or errorMessage, never both)
function ImageHelpers.exportToTempFile(photos)
	if isTableEmpty(photos) then
		return {}
	end

	if #photos == 0 then
		return {}
	end

	local absoluteFolderPath = LrPathUtils.getStandardFilePath("temp")

	local exportSettings = {
		LR_exportServiceProvider = "com.adobe.ag.export.file",
		LR_exportServiceProviderTitle = "Crush Catalog",
		LR_export_destinationType = "specificFolder",
		LR_export_destinationPathPrefix = absoluteFolderPath,
		LR_format = "JPEG",
		LR_jpeg_quality = 1,
		LR_collisionHandling = "overwrite",

		-- Metadata
		LR_metadata_filter = "all", -- Includes all metadata
		LR_minimizeEmbeddedMetadata = false, -- Don't strip for file size
		LR_removeLocationMetadata = false, -- Keep GPS
		LR_removeEditMetadata = false, -- Keep develop settings info
		LR_export_includeCopyright = true, -- Include copyright notice
	}

	local exportSession = LrExportSession({
		photosToExport = photos,
		exportSettings = exportSettings,
	})

	-- Process the export on the current background task
	exportSession:doExportOnCurrentTask()

	local results = {}

	for _, rendition in exportSession:renditions() do
		local success, pathOrMessage = rendition:waitForRender()
		local originalPhotoPath = rendition.photo:getRawMetadata("path")
		if success then
			table.insert(results, {
				photo = rendition.photo,
				photoIdentifier = rendition.photo.localIdentifier,
				originalPhotoPath = originalPhotoPath,
				exportedJpegPath = pathOrMessage,
				errorMessage = nil,
			})
		else
			table.insert(results, {
				photo = rendition.photo,
				photoIdentifier = rendition.photo.localIdentifier,
				originalPhotoPath = originalPhotoPath,
				exportedJpegPath = nil,
				errorMessage = pathOrMessage,
			})
		end
	end

	return results
end

local function calculateOutputPath(imagePath)
	local tempDir = LrPathUtils.getStandardFilePath("temp")
	local fileName = LrPathUtils.leafName(imagePath)
	local baseName = LrPathUtils.removeExtension(fileName)

	local uniqueName = string.format("%s_%s_cropped.jpg", baseName, LrUUID.generateUUID())

	return LrPathUtils.child(tempDir, uniqueName)
end

--- Retrieves dimensions from a JPEG file on disk using system tools
--- @param imagePath string Absolute path to the JPEG file.
--- @return number | nil, number | nil imgW (Number), imgH (Number) or nil if failed.
function ImageHelpers.getImageDimensions(imagePath)
	local imgW, imgH

	if WIN_ENV then
		-- PowerShell to read image dimensions without catalog metadata
		local cmd = string.format(
			"powershell -ExecutionPolicy Bypass -Command \"[Reflection.Assembly]::LoadWithPartialName('System.Drawing') | Out-Null; "
				.. "$img = [System.Drawing.Image]::FromFile('%s'); "
				.. 'Write-Output $img.Width; Write-Output $img.Height; $img.Dispose();"',
			imagePath
		)
		local output = LrTasks.execute(cmd)
		if output then
			local w, h = output:match("(%d+)%s+(%d+)")
			imgW, imgH = tonumber(w), tonumber(h)
		end
	else
		-- macOS 'sips' utility
		local wCmd = string.format("sips -g pixelWidth '%s' | awk '/pixelWidth/ {print $2}'", imagePath)
		local hCmd = string.format("sips -g pixelHeight '%s' | awk '/pixelHeight/ {print $2}'", imagePath)

		local exitCode, output = CommandHelpers.executeWithCapture(wCmd)

		if exitCode ~= 0 then
			LrDialogs.message("Error", string.format("%s\n\nexit code %d\n%s", wCmd, exitCode, output))
			return nil, nil
		else
			imgW = tonumber(output)
		end

		exitCode, output = CommandHelpers.executeWithCapture(hCmd)

		if exitCode ~= 0 then
			LrDialogs.message("Error", string.format("%s\n\nexit code %d\n%s", wCmd, exitCode, output))
			return nil, nil
		else
			imgH = tonumber(output)
		end
	end

	return imgW, imgH
end

--- crops the image and returns the file path
---@param imagePath string the path to the whole photo jpeg file
---@param boundingBox any a bounding box from backend
---@param imageWidth number | nil width of the image in pixels, when already known
---@param imageHeight number | nil height of the image in pixels, when already known
---@return string | nil the path to the cropped photo jpeg, or nil if something failed
function ImageHelpers.crop(imagePath, boundingBox, imageWidth, imageHeight)
	if not imagePath then
		LrDialogs.message("Error", "JPEG file path was nil")
		return nil
	end

	if not LrFileUtils.exists(imagePath) then
		LrDialogs.message("Error", string.format("JPEG file doesn't exist. %s", imagePath))
		return nil
	end

	local imgW = tonumber(imageWidth)
	local imgH = tonumber(imageHeight)

	if not imgW or not imgH then
		imgW, imgH = ImageHelpers.getImageDimensions(imagePath)
		if not imgW or not imgH then
			return nil
		end
	end

	-- 20% Margin
	local xmin, ymin, xmax, ymax = boundingBox[1], boundingBox[2], boundingBox[3], boundingBox[4]
	local bw, bh = xmax - xmin, ymax - ymin

	local left = math.max(0, xmin - bw * 0.2)
	local top = math.max(0, ymin - bh * 0.2)
	local right = math.min(imgW, xmax + bw * 0.2)
	local bottom = math.min(imgH, ymax + bh * 0.2)

	local cropW = right - left
	local cropH = bottom - top

	-- Build crop command
	local outputPath = calculateOutputPath(imagePath)
	local cmd
	if WIN_ENV then
		cmd = string.format(
			"powershell -ExecutionPolicy Bypass -Command \"[Reflection.Assembly]::LoadWithPartialName('System.Drawing') | Out-Null; "
				.. "$src = [System.Drawing.Image]::FromFile('%s'); "
				.. "$bmp = new-object System.Drawing.Bitmap(%d, %d); "
				.. "$g = [System.Drawing.Graphics]::FromImage($bmp); "
				.. "$g.DrawImage($src, new-object System.Drawing.Rectangle(0, 0, %d, %d), %d, %d, %d, %d, [System.Drawing.GraphicsUnit]::Pixel); "
				.. "$bmp.Save('%s', [System.Drawing.Imaging.ImageFormat]::Jpeg); $g.Dispose(); $bmp.Dispose(); $src.Dispose();\"",
			imagePath,
			cropW,
			cropH,
			cropW,
			cropH,
			left,
			top,
			cropW,
			cropH,
			outputPath
		)
	else
		cmd = string.format(
			"sips --cropOffset %d %d --cropToHeightWidth %d %d '%s' --out '%s'",
			top,
			left,
			cropH,
			cropW,
			imagePath,
			outputPath
		)
	end

	-- Do the crop
	local exitCode, output = CommandHelpers.executeWithCapture(cmd)

	if exitCode ~= 0 then
		LrDialogs.message("Error", string.format("%s\n\nexit code %d\n%s", cmd, exitCode, output))
		return nil
	end

	-- Final check
	if LrFileUtils.exists(outputPath) then
		return outputPath
	else
		LrDialogs.message("Error", string.format("Failed to create cropped image %s", outputPath))
		return nil
	end
end

return ImageHelpers
