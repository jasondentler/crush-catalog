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

local function updateSelection(properties)
    local result = selectedResult(properties)
    properties.taxonomyTree = SearchLogic.taxonomyTree(result)
    properties.canConfirm = result ~= nil
end

local function applyResults(properties, response)
    properties.searchResults = response.items or {}
    properties.resultItems = SearchLogic.resultItems(
        properties.searchResults,
        LOC '$$$/CrushCatalog/SearchNoResults=No results'
    )

    if properties.searchResults[properties.selectedResult] == nil then
        properties.selectedResult = #properties.searchResults > 0 and 1 or 0
    end

    updateSelection(properties)
end

local function performSearch(properties, query, options)
    local search = options.searchFunction or defaultSearch
    local searchOptions = {
        gpsCoordinates = options.gpsCoordinates,
        commonNameLanguage = options.commonNameLanguage,
    }

    local succeeded, response = LrTasks.pcall(search, query, searchOptions)

    if succeeded then
        properties.searchError = ''
        applyResults(properties, response)
    else
        properties.searchResults = {}
        properties.resultItems = SearchLogic.resultItems(
            {},
            LOC '$$$/CrushCatalog/SearchFailed=Search failed'
        )
        properties.selectedResult = 0
        properties.taxonomyTree = tostring(response)
        properties.canConfirm = false
        properties.searchError = tostring(response)
    end
end

function IdentificationSearchDialog.show(options)
    options = options or {}

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
        properties.searchError = ''

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
                properties.canConfirm = false
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
            updateSelection(properties)
        end)

        local function closeWithResult(button, modalResult)
            LrDialogs.stopModalWithResult(button, modalResult)
        end

        local dialogResult = LrDialogs.presentModalDialog {
            title = LOC '$$$/CrushCatalog/SearchTitle=Search',
            contents = factory:column {
                spacing = factory:control_spacing(),
                bind_to_object = properties,
                factory:edit_field {
                    value = LrView.bind('query'),
                    width_in_chars = 48,
                    immediate = true,
                },
                factory:popup_menu {
                    items = LrView.bind('resultItems'),
                    value = LrView.bind('selectedResult'),
                    width = 520,
                },
                factory:static_text {
                    title = LrView.bind('taxonomyTree'),
                    width = 520,
                    height_in_lines = 10,
                },
            },
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
