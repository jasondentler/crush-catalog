local LrBinding = import 'LrBinding'
local LrDialogs = import 'LrDialogs'
local LrFunctionContext = import 'LrFunctionContext'
local LrTasks = import 'LrTasks'
local LrView = import 'LrView'

local IdentificationSearchDialog = {}

local function pluginPath()
    if _PLUGIN ~= nil and _PLUGIN.path ~= nil then
        return _PLUGIN.path
    end

    local source = debug.getinfo(1, 'S').source
    return source:match('^@(.+)/[^/]+$') or '.'
end

local SearchLogic = assert(
    loadfile(pluginPath() .. '/Core/IdentificationSearchLogic.lua')
)()

local function defaultSearch(query, options)
    local WildCatalogApi = assert(loadfile(pluginPath() .. '/WildCatalogApi.lua'))()
    return WildCatalogApi.search(query, options)
end

local function selectedResult(properties)
    return properties.searchResults[properties.selectedResult]
end

local function selectedPredictionItems(predictions)
    local items = {}

    for index, prediction in ipairs(predictions or {}) do
        items[#items + 1] = {
            title = SearchLogic.resultTitle(prediction),
            value = index,
        }
    end

    if #items == 0 then
        items[1] = {
            title = LOC '$$$/CrushCatalog/SearchNoSelectedSpecies=No selected species',
            value = 0,
        }
    end

    return items
end

local function updateConfirm(properties, multipleSelection)
    if multipleSelection then
        properties.canConfirm = #properties.selectedPredictions > 0
    else
        properties.canConfirm = selectedResult(properties) ~= nil
    end
end

local function updateSelection(properties, multipleSelection)
    local result = selectedResult(properties)
    properties.taxonomyTree = SearchLogic.taxonomyTree(result)
    properties.canAddResult = result ~= nil
    updateConfirm(properties, multipleSelection)
end

local function updateSelectedPredictions(properties)
    properties.selectedPredictionItems = selectedPredictionItems(
        properties.selectedPredictions
    )

    if properties.selectedPredictions[properties.selectedPrediction] == nil then
        properties.selectedPrediction = #properties.selectedPredictions > 0 and 1 or 0
    end

    properties.canRemovePrediction = properties.selectedPredictions[
        properties.selectedPrediction
    ] ~= nil
    updateConfirm(properties, true)
end

local function addSelectedPrediction(properties)
    local result = selectedResult(properties)

    if result == nil then
        return
    end

    properties.selectedPredictions[#properties.selectedPredictions + 1] = result
    properties.selectedPrediction = #properties.selectedPredictions
    updateSelectedPredictions(properties)
end

local function removeSelectedPrediction(properties)
    if properties.selectedPredictions[properties.selectedPrediction] == nil then
        return
    end

    table.remove(properties.selectedPredictions, properties.selectedPrediction)
    updateSelectedPredictions(properties)
end

local function applyResults(properties, response, multipleSelection)
    properties.searchResults = response.items or {}
    properties.resultItems = SearchLogic.resultItems(
        properties.searchResults,
        LOC '$$$/CrushCatalog/SearchNoResults=No results'
    )

    if properties.searchResults[properties.selectedResult] == nil then
        properties.selectedResult = #properties.searchResults > 0 and 1 or 0
    end

    updateSelection(properties, multipleSelection)
end

local function performSearch(properties, query, options)
    local search = options.searchFunction or defaultSearch
    local multipleSelection = options.selectionMode == 'multiple'
    local searchOptions = {
        gpsCoordinates = options.gpsCoordinates,
        commonNameLanguage = options.commonNameLanguage,
    }

    local succeeded, response = LrTasks.pcall(search, query, searchOptions)

    if succeeded then
        properties.searchError = ''
        applyResults(properties, response, multipleSelection)
    else
        properties.searchResults = {}
        properties.resultItems = SearchLogic.resultItems(
            {},
            LOC '$$$/CrushCatalog/SearchFailed=Search failed'
        )
        properties.selectedResult = 0
        properties.taxonomyTree = tostring(response)
        properties.canAddResult = false
        updateConfirm(properties, multipleSelection)
        properties.searchError = tostring(response)
    end
end

function IdentificationSearchDialog.show(options)
    options = options or {}
    local multipleSelection = options.selectionMode == 'multiple'

    return LrFunctionContext.callWithContext('identificationSearchDialog', function(context)
        local properties = LrBinding.makePropertyTable(context)
        local factory = LrView.osFactory()
        local searchToken = 0

        properties.query = ''
        properties.searchResults = {}
        properties.resultItems = SearchLogic.resultItems(
            {},
            LOC '$$$/CrushCatalog/SearchTypeToSearch=Type to search'
        )
        properties.selectedResult = 0
        properties.taxonomyTree = ''
        properties.canConfirm = false
        properties.canAddResult = false
        properties.searchError = ''
        properties.selectedPredictions = {}
        properties.selectedPredictionItems = selectedPredictionItems({})
        properties.selectedPrediction = 0
        properties.canRemovePrediction = false

        properties:addObserver('query', function()
            searchToken = searchToken + 1
            local token = searchToken
            local query = properties.query

            if query == nil or query:match('^%s*$') then
                properties.searchResults = {}
                properties.resultItems = SearchLogic.resultItems(
                    {},
                    LOC '$$$/CrushCatalog/SearchTypeToSearch=Type to search'
                )
                properties.selectedResult = 0
                properties.taxonomyTree = ''
                properties.canAddResult = false
                updateConfirm(properties, multipleSelection)
                return
            end

            LrTasks.startAsyncTask(function()
                LrTasks.sleep(options.debounceSeconds or 0.25)

                if token ~= searchToken then
                    return
                end

                performSearch(properties, query, options)
            end)
        end)

        properties:addObserver('selectedResult', function()
            updateSelection(properties, multipleSelection)
        end)

        properties:addObserver('selectedPrediction', function()
            properties.canRemovePrediction = properties.selectedPredictions[
                properties.selectedPrediction
            ] ~= nil
        end)

        local function closeWithResult(button, modalResult)
            LrDialogs.stopModalWithResult(button, modalResult)
        end

        local resultPicker = factory:popup_menu {
            items = LrView.bind('resultItems'),
            value = LrView.bind('selectedResult'),
            width = 520,
        }
        local contents = {
            spacing = factory:control_spacing(),
            bind_to_object = properties,
            factory:edit_field {
                value = LrView.bind('query'),
                width_in_chars = 48,
                immediate = true,
            },
        }

        if multipleSelection then
            contents[#contents + 1] = factory:row {
                spacing = factory:control_spacing(),
                resultPicker,
                factory:push_button {
                    title = LOC '$$$/CrushCatalog/SearchAdd=Add',
                    enabled = LrView.bind('canAddResult'),
                    action = function()
                        addSelectedPrediction(properties)
                    end,
                },
            }
        else
            contents[#contents + 1] = resultPicker
        end

        contents[#contents + 1] = factory:static_text {
            title = LrView.bind('taxonomyTree'),
            width = 520,
            height_in_lines = 14,
        }

        if multipleSelection then
            contents[#contents + 1] = factory:popup_menu {
                items = LrView.bind('selectedPredictionItems'),
                value = LrView.bind('selectedPrediction'),
                width = 520,
            }
            contents[#contents + 1] = factory:row {
                spacing = factory:control_spacing(),
                factory:spacer {
                    fill_horizontal = 1,
                },
                factory:push_button {
                    title = LOC '$$$/CrushCatalog/SearchRemove=Remove',
                    enabled = LrView.bind('canRemovePrediction'),
                    action = function()
                        removeSelectedPrediction(properties)
                    end,
                },
            }
        end

        local dialogResult = LrDialogs.presentModalDialog {
            title = LOC '$$$/CrushCatalog/SearchTitle=Search',
            contents = factory:column(contents),
            accessoryView = factory:row {
                spacing = factory:control_spacing(),
                fill_horizontal = 1,
                factory:spacer {
                    fill_horizontal = 1,
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

        if dialogResult ~= 'ok' then
            return {
                action = dialogResult,
            }
        end

        if multipleSelection then
            if #properties.selectedPredictions == 0 then
                return {
                    action = 'unsure',
                }
            end

            return {
                action = 'manual',
                selectedPredictions = properties.selectedPredictions,
            }
        end

        local result = selectedResult(properties)

        if result == nil then
            return {
                action = 'unsure',
            }
        end

        return {
            action = 'manual',
            selectedPrediction = result,
        }
    end)
end

IdentificationSearchDialog.logic = SearchLogic

return IdentificationSearchDialog
