local LrDialogs = import 'LrDialogs'
local LrView = import 'LrView'

local LrBinding = import 'LrBinding'
local LrFunctionContext = import 'LrFunctionContext'
local LrFileUtils = import 'LrFileUtils'
local LrLogger = import 'LrLogger'
local LrPathUtils = import 'LrPathUtils'
local JSON = require("JSON")
local ImageHelpers = require("ImageHelpers")

local myLogger = LrLogger("com.jasondentler.crushcatalog.ConfirmDetection")
myLogger:enable("logfile")

local ConfirmDetection = {}

local function outputToLog(message)
    myLogger:trace(message)
end

local function formatBox(box)
    if not box then
        return "nil"
    end

    return table.concat(box, ",")
end

function ConfirmDetection.confirm(entirePhotoPath, detection, displayPhotoPath)
    outputToLog(string.format(
        "Cropping detection for displayPhotoPath=%s exportedPhotoPath=%s box=%s imageWidth=%s imageHeight=%s",
        tostring(displayPhotoPath),
        tostring(entirePhotoPath),
        formatBox(detection and detection.box),
        tostring(detection and detection.image_width),
        tostring(detection and detection.image_height)
    ))
    local croppedImagePath = ImageHelpers.crop(entirePhotoPath, detection.box, detection.image_width, detection.image_height)
    return ConfirmDetection.showBirdConfirmationDialog(croppedImagePath, detection, displayPhotoPath)
end

function ConfirmDetection.showBirdConfirmationDialog(croppedImagePath, detection, displayPhotoPath)
    if not croppedImagePath then
        LrDialogs.message("Error", "Failed to get cropped JPEG file path")
        return { status = "cancelled" }
    end

    if not LrFileUtils.exists(croppedImagePath) then
        LrDialogs.message("Error", string.format("Cropped JPEG file doesn't exist. %s", croppedImagePath))
        return { status = "cancelled" }
    end

    local matches = {}
    local dropdownItems = {}
    local photoName = LrPathUtils.leafName(displayPhotoPath or croppedImagePath)
    outputToLog(string.format("Showing confirmation dialog photoName=%s croppedImagePath=%s", tostring(photoName), tostring(croppedImagePath)))

    local function matchToDropDownItem(match)
        local commonName = match.comName or match.species
        local sciName = match.sciName or match.species
        local title = commonName

        if commonName and sciName and commonName ~= sciName then
            title = string.format("%s (%s)", commonName, sciName)
        end

        return {
            title = title,
            value = sciName
        }
    end

    if detection.best_match then
        table.insert(matches, detection.best_match)
        table.insert(dropdownItems, matchToDropDownItem(detection.best_match))
    end

    for _, alternative in ipairs(detection.alternatives or {}) do
        table.insert(matches, alternative)
        table.insert(dropdownItems, matchToDropDownItem(alternative))
    end

    if not next(dropdownItems) then
        for _, prediction in ipairs(detection.predictions or {}) do
            table.insert(matches, prediction)
            table.insert(dropdownItems, matchToDropDownItem(prediction))
        end
    end

    if not dropdownItems or not next(dropdownItems) then
        return { status = "rejected", reason = "no_matches" }
    end

    local result = LrFunctionContext.callWithContext("showBirdConfirmationDialog", function (context)
        local f = LrView.osFactory()
        local props = LrBinding.makePropertyTable(context)
        props.selectedSpeciesValue = dropdownItems[1].value

        local contents
        contents = f:column {
            spacing = 12,
            bind_to_object = props,
            f:row {
                -- 1. The Cropped Photo
                f:picture {
                    value = croppedImagePath,
                    width = 400,
                    height = 400,
                },
            },
            -- 2. Dropdown for Species Selection
            f:row {
                fill_horizontal = 1,
                f:static_text {
                    title = "Species:",
                    alignment = 'right',
                },
                f:popup_menu {
                    items = dropdownItems,
                    value = LrView.bind('selectedSpeciesValue'),
                },
            },
            -- 3. Feedback / Alternative Action
            f:row {
                f:push_button {
                    title = "Not a bird",
                    action = function()
                        props.notABird = true
                        LrDialogs.stopModalWithResult(contents, "notABird")
                    end,
                },
                f:push_button {
                    title = "Species not listed",
                    action = function ()
                        props.differentSpecies = true
                        LrDialogs.stopModalWithResult(contents, "differentSpecies")
                    end
                },
                f:push_button {
                    title = "Unsure",
                    action=function ()
                        props.unsure = true
                        LrDialogs.stopModalWithResult(contents, "unsure")
                    end
                }
            },
        }

        local dialogResult = LrDialogs.presentModalDialog({
            title = "Confirm Bird Species - " .. photoName,
            contents = contents,
            props = props,
            actionVerb = "Confirm",
            cancelVerb = "Stop"
        })

        return {
            result = dialogResult,
            selectedSpecies = props.selectedSpeciesValue
        }
    end)

    -- Cleanup
    LrFileUtils.delete(croppedImagePath)

    -- Handle Results
    if result.result == "ok" then
        for _, match in ipairs(matches) do
            local sciName = match.sciName or match.species
            local commonName = match.comName or match.species
            if sciName == result.selectedSpecies then
                outputToLog(string.format(
                    "Confirmed detection photoName=%s commonName=%s scientificName=%s croppedImagePath=%s",
                    tostring(photoName),
                    tostring(commonName),
                    tostring(sciName),
                    tostring(croppedImagePath)
                ))
                return {
                    status = "confirmed",
                    commonName = commonName,
                    scientificName = sciName,
                    confidence = (match.confidence or 0) * 100,
                }
            end
        end

        return { status = "cancelled" }
    elseif result.result == "notABird" then
        outputToLog("Rejected detection reason=not_a_bird photoName=" .. tostring(photoName))
        return { status = "rejected", reason = "not_a_bird" }
    elseif result.result == "differentSpecies" then
        outputToLog("Rejected detection reason=different_species photoName=" .. tostring(photoName))
        return { status = "rejected", reason = "different_species" }
    elseif result.result == "unsure" then
        outputToLog("Rejected detection reason=unsure photoName=" .. tostring(photoName))
        return { status = "rejected", reason = "unsure" }
    else
        outputToLog("Stopped detection review photoName=" .. tostring(photoName))
        return { status = "stopped" }
    end
end

return ConfirmDetection
