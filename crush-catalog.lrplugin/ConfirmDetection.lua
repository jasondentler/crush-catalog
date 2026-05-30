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

local function trim(value)
    return tostring(value or ""):match("^%s*(.-)%s*$") or ""
end

local function formatBox(box)
    if not box then
        return "nil"
    end

    return table.concat(box, ",")
end

local function speciesToDropDownItem(species)
    local commonName = species.comName or species.commonName or species.species
    local sciName = species.sciName or species.scientificName or species.species
    local title = commonName

    if commonName and sciName and commonName ~= sciName then
        title = string.format("%s (%s)", commonName, sciName)
    end

    return {
        title = title,
        value = sciName
    }
end

function ConfirmDetection.confirm(entirePhotoPath, detection, displayPhotoPath, localSpecies)
    outputToLog(string.format(
        "Cropping detection for displayPhotoPath=%s exportedPhotoPath=%s box=%s imageWidth=%s imageHeight=%s",
        tostring(displayPhotoPath),
        tostring(entirePhotoPath),
        formatBox(detection and detection.box),
        tostring(detection and detection.image_width),
        tostring(detection and detection.image_height)
    ))
    local croppedImagePath = ImageHelpers.crop(entirePhotoPath, detection.box, detection.image_width, detection.image_height)
    return ConfirmDetection.showBirdConfirmationDialog(croppedImagePath, detection, displayPhotoPath, localSpecies)
end

function ConfirmDetection.showDifferentSpeciesDialog(localSpecies, photoName)
    local speciesItems = {}
    local speciesByValue = {}

    for _, species in ipairs(localSpecies or {}) do
        local item = speciesToDropDownItem(species)
        if item.value and item.value ~= "" and not speciesByValue[item.value] then
            table.insert(speciesItems, item)
            speciesByValue[item.value] = species
        end
    end

    local hasLocalSpecies = next(speciesItems) ~= nil

    local result = LrFunctionContext.callWithContext("showDifferentSpeciesDialog", function(context)
        local f = LrView.osFactory()
        local props = LrBinding.makePropertyTable(context)
        props.speciesEntryMode = hasLocalSpecies and "local" or "manual"
        props.selectedSpeciesValue = hasLocalSpecies and speciesItems[1].value or ""
        props.manualCommonName = ""
        props.manualScientificName = ""

        local function enabledWhen(mode)
            return LrView.bind {
                key = "speciesEntryMode",
                transform = function(value)
                    return value == mode
                end,
            }
        end

        local contents
        contents = f:column {
            spacing = 12,
            bind_to_object = props,
            f:row {
                f:radio_button {
                    title = "Choose from local species",
                    value = LrView.bind("speciesEntryMode"),
                    checked_value = "local",
                    enabled = hasLocalSpecies,
                },
            },
            f:row {
                fill_horizontal = 1,
                f:static_text {
                    title = "Species:",
                    alignment = "right",
                    enabled = enabledWhen("local"),
                },
                f:popup_menu {
                    items = speciesItems,
                    value = LrView.bind("selectedSpeciesValue"),
                    enabled = enabledWhen("local"),
                },
            },
            f:row {
                f:radio_button {
                    title = "Enter species manually",
                    value = LrView.bind("speciesEntryMode"),
                    checked_value = "manual",
                },
            },
            f:row {
                fill_horizontal = 1,
                f:static_text {
                    title = "Common name:",
                    alignment = "right",
                    enabled = enabledWhen("manual"),
                },
                f:edit_field {
                    value = LrView.bind("manualCommonName"),
                    width_in_chars = 36,
                    enabled = enabledWhen("manual"),
                },
            },
            f:row {
                fill_horizontal = 1,
                f:static_text {
                    title = "Scientific name:",
                    alignment = "right",
                    enabled = enabledWhen("manual"),
                },
                f:edit_field {
                    value = LrView.bind("manualScientificName"),
                    width_in_chars = 36,
                    enabled = enabledWhen("manual"),
                },
            },
        }

        local dialogResult = LrDialogs.presentModalDialog({
            title = "Choose Bird Species - " .. tostring(photoName),
            contents = contents,
            props = props,
            actionVerb = "Use Species",
            cancelVerb = "Back",
        })

        return {
            result = dialogResult,
            speciesEntryMode = props.speciesEntryMode,
            selectedSpecies = props.selectedSpeciesValue,
            manualCommonName = trim(props.manualCommonName),
            manualScientificName = trim(props.manualScientificName),
        }
    end)

    if result.result ~= "ok" then
        return { status = "rejected", reason = "different_species_cancelled" }
    end

    if result.speciesEntryMode == "manual" then
        if result.manualCommonName == "" and result.manualScientificName == "" then
            LrDialogs.message("Species Required", "Enter a common name, a scientific name, or both.")
            return ConfirmDetection.showDifferentSpeciesDialog(localSpecies, photoName)
        end

        return {
            status = "confirmed",
            commonName = result.manualCommonName ~= "" and result.manualCommonName or result.manualScientificName,
            scientificName = result.manualScientificName ~= "" and result.manualScientificName or result.manualCommonName,
            confidence = 0,
            selectionSource = "manual",
        }
    end

    local selectedSpecies = speciesByValue[result.selectedSpecies]
    if selectedSpecies then
        local commonName = selectedSpecies.comName or selectedSpecies.commonName or result.selectedSpecies
        local scientificName = selectedSpecies.sciName or selectedSpecies.scientificName or result.selectedSpecies
        return {
            status = "confirmed",
            commonName = commonName,
            scientificName = scientificName,
            confidence = 0,
            selectionSource = "local_species",
        }
    end

    return { status = "rejected", reason = "different_species_not_found" }
end

function ConfirmDetection.showBirdConfirmationDialog(croppedImagePath, detection, displayPhotoPath, localSpecies)
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

    if detection.best_match then
        table.insert(matches, detection.best_match)
        table.insert(dropdownItems, speciesToDropDownItem(detection.best_match))
    end

    for _, alternative in ipairs(detection.alternatives or {}) do
        table.insert(matches, alternative)
        table.insert(dropdownItems, speciesToDropDownItem(alternative))
    end

    if not next(dropdownItems) then
        for _, prediction in ipairs(detection.predictions or {}) do
            table.insert(matches, prediction)
            table.insert(dropdownItems, speciesToDropDownItem(prediction))
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
        return ConfirmDetection.showDifferentSpeciesDialog(localSpecies, photoName)
    elseif result.result == "unsure" then
        outputToLog("Rejected detection reason=unsure photoName=" .. tostring(photoName))
        return { status = "rejected", reason = "unsure" }
    else
        outputToLog("Stopped detection review photoName=" .. tostring(photoName))
        return { status = "stopped" }
    end
end

return ConfirmDetection
