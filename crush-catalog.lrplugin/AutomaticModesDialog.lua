local LrBinding = import 'LrBinding'
local LrDialogs = import 'LrDialogs'
local LrFunctionContext = import 'LrFunctionContext'
local LrView = import 'LrView'

local AutomaticModesDialog = {}

local function pluginPath()
    if _PLUGIN ~= nil and _PLUGIN.path ~= nil then
        return _PLUGIN.path
    end

    local source = debug.getinfo(1, 'S').source
    return source:match('^@(.+)/[^/]+$') or '.'
end

local AutomaticModesLogic = assert(
    loadfile(pluginPath() .. '/Core/AutomaticModesLogic.lua')
)()

function AutomaticModesDialog.show()
    return LrFunctionContext.callWithContext('automaticModesDialog', function(context)
        local properties = LrBinding.makePropertyTable(context)
        local factory = LrView.osFactory()

        properties.threshold = '90'
        properties.reprocess = false
        properties.mode = 'assisted'

        local function updateValidity()
            properties.valid = AutomaticModesLogic.validOptions(properties)
        end

        properties:addObserver('threshold', updateValidity)
        properties:addObserver('mode', updateValidity)
        updateValidity()

        local result = LrDialogs.presentModalDialog {
            title = LOC '$$$/CrushCatalog/AutomaticModesTitle=Identify Selected Images',
            contents = factory:column {
                spacing = factory:control_spacing(),
                bind_to_object = properties,
                factory:row {
                    factory:static_text {
                        title = LOC '$$$/CrushCatalog/ConfidenceThreshold=Confidence Threshold:',
                    },
                    factory:edit_field {
                        value = LrView.bind('threshold'),
                        width_in_digits = 3,
                    },
                    factory:static_text { title = '%' },
                },
                factory:checkbox {
                    title = LOC '$$$/CrushCatalog/ReprocessImages=Reprocess Images',
                    value = LrView.bind('reprocess'),
                },
                factory:static_text {
                    title = LOC '$$$/CrushCatalog/Mode=Mode:',
                },
                factory:radio_button {
                    title = LOC '$$$/CrushCatalog/AutomaticMode=Automatic Mode',
                    value = LrView.bind('mode'),
                    checked_value = 'automatic',
                },
                factory:radio_button {
                    title = LOC '$$$/CrushCatalog/AssistedMode=Assisted Mode',
                    value = LrView.bind('mode'),
                    checked_value = 'assisted',
                },
                factory:radio_button {
                    title = LOC '$$$/CrushCatalog/ManualMode=Manual Mode',
                    value = LrView.bind('mode'),
                    checked_value = 'manual',
                },
            },
            actionVerb = LOC '$$$/CrushCatalog/Okay=Okay',
            actionBinding = {
                enabled = LrView.bind('valid'),
            },
            resizable = false,
        }

        if result ~= 'ok' then
            return nil
        end

        return {
            threshold = AutomaticModesLogic.threshold(properties.threshold),
            reprocess = properties.reprocess,
            mode = properties.mode,
        }
    end)
end

return AutomaticModesDialog
