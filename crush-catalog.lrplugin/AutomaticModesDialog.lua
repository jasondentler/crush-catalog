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

        properties.threshold = '70'
        properties.processingScope = 'new'
        properties.mode = 'automatic'
        properties.detectorThreshold = '0'
        properties.cropDetailThreshold = '5'
        properties.selectedTab = 'general'

        local function updateValidity()
            properties.valid = AutomaticModesLogic.validOptions(properties)
                and AutomaticModesLogic.threshold(properties.detectorThreshold) ~= nil
                and AutomaticModesLogic.threshold(properties.cropDetailThreshold) ~= nil
        end

        properties:addObserver('threshold', updateValidity)
        properties:addObserver('mode', updateValidity)
        properties:addObserver('processingScope', updateValidity)
        properties:addObserver('detectorThreshold', updateValidity)
        properties:addObserver('cropDetailThreshold', updateValidity)
        updateValidity()

        local result = LrDialogs.presentModalDialog {
            title = LOC '$$$/CrushCatalog/AutomaticModesTitle=Identify Selected Images',
            contents = factory:tab_view {
                bind_to_object = properties,
                value = LrView.bind('selectedTab'),
                factory:tab_view_item {
                    title = 'General',
                    identifier = 'general',
                    factory:row {
                        spacing = factory:control_spacing(),
                        fill_horizontal = 1,
                        factory:column {
                            fill_horizontal = 1,
                            spacing = factory:control_spacing(),
                            factory:static_text {
                                title = LOC '$$$/CrushCatalog/ImagesToProcess=Images to Process',
                            },
                            factory:view {
                                place = 'vertical',
                                margin = 4,
                                spacing = factory:control_spacing(),
                                factory:radio_button {
                                    title = LOC '$$$/CrushCatalog/OnlyNewImages=Only New images',
                                    value = LrView.bind('processingScope'),
                                    checked_value = 'new',
                                },
                                factory:radio_button {
                                    title = LOC '$$$/CrushCatalog/NewAndUnsure=New + Unsure',
                                    value = LrView.bind('processingScope'),
                                    checked_value = 'new_and_unsure',
                                },
                                factory:radio_button {
                                    title = LOC '$$$/CrushCatalog/ReprocessAllImages=Reprocess All Images',
                                    value = LrView.bind('processingScope'),
                                    checked_value = 'all',
                                },
                            },
                        },
                        factory:column {
                            fill_horizontal = 1,
                            spacing = factory:control_spacing(),
                            factory:static_text {
                                title = LOC '$$$/CrushCatalog/Mode=Mode:',
                            },
                            factory:view {
                                place = 'vertical',
                                margin = 4,
                                spacing = factory:control_spacing(),
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
                        },
                    },
                },
                factory:tab_view_item {
                    title = 'Advanced',
                    identifier = 'advanced',
                    factory:column {
                        spacing = factory:control_spacing(),
                        factory:row {
                            factory:static_text {
                                title = LOC '$$$/CrushCatalog/SpeciesConfidence=Species confidence',
                                width = 140,
                            },
                            factory:edit_field {
                                value = LrView.bind('threshold'),
                                width_in_digits = 3,
                            },
                            factory:static_text { title = '%', width = 36 },
                            factory:static_text { title = 'Minimum score to auto-accept.' },
                        },
                        factory:row {
                            factory:static_text { title = 'Detection confidence', width = 140 },
                            factory:edit_field {
                                value = LrView.bind('detectorThreshold'),
                                width_in_digits = 3,
                            },
                            factory:static_text { title = '%', width = 36 },
                            factory:static_text { title = 'Filter weak detections (0 = off).' },
                        },
                        factory:row {
                            factory:static_text { title = 'Subject detail', width = 140 },
                            factory:edit_field {
                                value = LrView.bind('cropDetailThreshold'),
                                width_in_digits = 3,
                            },
                            factory:static_text { title = '/100', width = 36 },
                            factory:static_text { title = 'Filter low-detail crops (0 = off).' },
                        },
                        factory:static_text {
                            title = 'Higher detection and detail filters may miss real subjects.',
                        },
                    },
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
            processingScope = properties.processingScope,
            mode = properties.mode,
            engine = 'batch',
            detectorThreshold = AutomaticModesLogic.threshold(properties.detectorThreshold),
            cropDetailThreshold = AutomaticModesLogic.threshold(properties.cropDetailThreshold),
        }
    end)
end

return AutomaticModesDialog
