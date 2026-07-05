describe('IdentificationSearchDialog', function()
    local originalImport
    local originalLoc

    before_each(function()
        originalImport = _G.import
        originalLoc = _G.LOC
        _G.LOC = function(value)
            return value:match('=(.*)$') or value
        end
    end)

    after_each(function()
        _G.import = originalImport
        _G.LOC = originalLoc
    end)

    it('searches immediately as the user types and hides cancel', function()
        local observers = {}
        local searchCalls = {}
        local dialogArguments

        _G.import = function(name)
            local imports = {
                LrBinding = {
                    makePropertyTable = function()
                        return {
                            addObserver = function(_, key, callback)
                                observers[key] = callback
                            end,
                        }
                    end,
                },
                LrDialogs = {
                    presentModalDialog = function(arguments)
                        dialogArguments = arguments
                        local properties = arguments.contents.bind_to_object
                        properties.query = 'ibis'
                        observers.query()
                        return 'ok'
                    end,
                    stopModalWithResult = function() end,
                },
                LrFunctionContext = {
                    callWithContext = function(_, callback)
                        return callback({})
                    end,
                },
                LrTasks = {
                    pcall = function(...)
                        return pcall(...)
                    end,
                    sleep = function() end,
                    startAsyncTask = function(callback) callback() end,
                },
                LrView = {
                    bind = function(key)
                        return { key = key }
                    end,
                    osFactory = function()
                        return {
                            column = function(_, value) return value end,
                            control_spacing = function() return 4 end,
                            edit_field = function(_, value) return value end,
                            popup_menu = function(_, value) return value end,
                            push_button = function(_, value) return value end,
                            row = function(_, value) return value end,
                            spacer = function(_, value) return value end,
                            static_text = function(_, value) return value end,
                        }
                    end,
                },
            }

            return assert(imports[name], 'Unexpected Lightroom import: ' .. tostring(name))
        end

        local dialog = assert(loadfile(
            'crush-catalog.lrplugin/IdentificationSearchDialog.lua'
        ))()
        local result = dialog.show({
            debounceSeconds = 0,
            searchFunction = function(query, options)
                searchCalls[#searchCalls + 1] = {
                    query = query,
                    options = options,
                }

                return {
                    items = { {
                        taxonomy = { 'Animalia', 'Eudocimus', 'albus' },
                        taxonomyRanks = { 'kingdom', 'genus', 'species' },
                        commonNameTaxonomy = { 'Animals', 'Ibises', 'White Ibis' },
                    } },
                }
            end,
            gpsCoordinates = { latitude = 29.5, longitude = -94.3 },
            commonNameLanguage = 'en-US',
        })

        assert.are.equal('manual', result.action)
        assert.are.equal('ibis', searchCalls[1].query)
        assert.same(
            { latitude = 29.5, longitude = -94.3 },
            searchCalls[1].options.gpsCoordinates
        )
        assert.are.equal('en-US', searchCalls[1].options.commonNameLanguage)
        assert.are.equal('White Ibis', result.selectedPrediction.commonNameTaxonomy[3])
        assert.are.equal('Search', dialogArguments.title)
        assert.are.equal('< exclude >', dialogArguments.cancelVerb)
        assert.is_true(dialogArguments.contents[1].immediate)
        assert.are.equal(1, dialogArguments.accessoryView[1].fill_horizontal)
        assert.are.equal('Unsure', dialogArguments.accessoryView[2].title)
    end)
end)
