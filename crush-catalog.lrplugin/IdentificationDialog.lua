local LrBinding = import 'LrBinding'
local LrDialogs = import 'LrDialogs'
local LrFileUtils = import 'LrFileUtils'
local LrFunctionContext = import 'LrFunctionContext'
local LrPathUtils = import 'LrPathUtils'
local LrView = import 'LrView'

local IdentificationDialog = {}

local function pluginPath()
    if _PLUGIN ~= nil and _PLUGIN.path ~= nil then
        return _PLUGIN.path
    end

    local source = debug.getinfo(1, 'S').source
    return source:match('^@(.+)/[^/]+$') or '.'
end

local IdentificationLogic = assert(
    loadfile(pluginPath() .. '/Core/IdentificationLogic.lua')
)()
local AutomaticModesLogic = assert(
    loadfile(pluginPath() .. '/Core/AutomaticModesLogic.lua')
)()
local TaxonomyNames = assert(loadfile(pluginPath() .. '/Core/TaxonomyNames.lua'))()

function IdentificationDialog.predictionItems(predictions)
    return IdentificationLogic.predictionItems(
        predictions,
        LOC '$$$/CrushCatalog/NoPredictions=No predictions',
        TaxonomyNames
    )
end

local function writeDetectedImage(detectedImage)
    local suggestedName = LrPathUtils.leafName(
        detectedImage.filename or 'crush-catalog-detection.jpg'
    )
    local imagePath = LrFileUtils.chooseUniqueFileName(
        LrPathUtils.child(LrPathUtils.getStandardFilePath('temp'), suggestedName)
    )
    local file, openError = io.open(imagePath, 'wb')

    if file == nil then
        error('Unable to create temporary detected image: ' .. tostring(openError))
    end

    file:write(detectedImage.bytes)
    file:close()

    return imagePath
end

local function show(photo, result, detectedImage, position)
    local imagePath = writeDetectedImage(detectedImage)

    return LrFunctionContext.callWithContext('identificationDialog', function(context)
        context:addCleanupHandler(function()
            LrFileUtils.delete(imagePath)
        end)

        local properties = LrBinding.makePropertyTable(context)
        local items = IdentificationDialog.predictionItems(result.predictions)
        local factory = LrView.osFactory()
        local photoTitle = photo:getFormattedMetadata('fileName')
            or LOC '$$$/CrushCatalog/PredictionDialogTitle=Identification'

        local function closeWithResult(button, modalResult)
            LrDialogs.stopModalWithResult(button, modalResult)
        end

        properties.selectedPrediction = items[1].value

        local dialogResult = LrDialogs.presentModalDialog {
            title = string.format(
                'Image %d of %d: %s (Animal %d of %d)',
                position.imageIndex,
                position.imageCount,
                photoTitle,
                position.detectionIndex,
                position.detectionCount
            ),
            contents = factory:column {
                spacing = factory:control_spacing(),
                bind_to_object = properties,
                factory:picture {
                    value = imagePath,
                    width = 640,
                    height = 480,
                    frame_width = 1,
                },
                factory:popup_menu {
                    items = items,
                    value = LrView.bind('selectedPrediction'),
                    width = 640,
                },
            },
            accessoryView = factory:row {
                spacing = factory:control_spacing(),
                fill_horizontal = 1,
                factory:push_button {
                    title = LOC '$$$/CrushCatalog/Stop=Stop',
                    action = function(button)
                        closeWithResult(button, 'other')
                    end,
                },
                factory:spacer {
                    fill_horizontal = 1,
                },
                factory:push_button {
                    title = LOC '$$$/CrushCatalog/NextImage=Next Image',
                    action = function(button)
                        closeWithResult(button, 'cancel')
                    end,
                },
                factory:push_button {
                    title = LOC '$$$/CrushCatalog/NotAnAnimal=Not An Animal',
                    action = function(button)
                        closeWithResult(button, 'not_an_animal')
                    end,
                },
                factory:push_button {
                    title = LOC '$$$/CrushCatalog/Unsure=Unsure',
                    action = function(button)
                        closeWithResult(button, 'unsure')
                    end,
                },
            },
            actionVerb = LOC '$$$/CrushCatalog/Confirm=Confirm',
            cancelVerb = '< exclude >',
            resizable = false,
        }

        return {
            action = dialogResult,
            selectedPredictionIndex = properties.selectedPrediction,
        }
    end)
end

function IdentificationDialog.showForResponse(photo, response, imageIndex, imageCount, options)
    local results = response.result.results or response.result
    local detectedImages = response.detectedImages or {}
    local dispositions = {}
    options = options or { mode = 'manual' }

    for index, result in ipairs(results) do
        local disposition

        if AutomaticModesLogic.shouldShowManual(result, options) then
            local detectedImage = detectedImages[index]

            if detectedImage == nil then
                error('Wild Catalog response is missing detected image ' .. index)
            end

            local dialogResult = show(photo, result, detectedImage, {
                imageIndex = imageIndex,
                imageCount = imageCount,
                detectionIndex = index,
                detectionCount = #results,
            })

            if dialogResult.action == 'other' then
                return 'stop'
            end

            if dialogResult.action == 'cancel' then
                return 'next_image'
            end

            disposition = IdentificationLogic.disposition(dialogResult, result)
        else
            disposition = AutomaticModesLogic.automaticDisposition(
                result,
                options.threshold
            )
        end

        dispositions[#dispositions + 1] = disposition
    end

    return 'continue', dispositions
end

return IdentificationDialog
