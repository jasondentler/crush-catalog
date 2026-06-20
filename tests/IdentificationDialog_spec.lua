describe('IdentificationDialog', function()
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

    it('shows prediction choices for a detected image and returns Stop', function()
        local dialogs = {}
        local dialogResults = { 'ok', 'other', 'cancel' }
        local stoppedResult
        local photo = {
            getFormattedMetadata = function()
                return 'bird.jpg'
            end,
        }

        _G.import = function(name)
            local imports = {
                LrBinding = {
                    makePropertyTable = function()
                        return {}
                    end,
                },
                LrDialogs = {
                    presentModalDialog = function(arguments)
                        dialogs[#dialogs + 1] = arguments
                        return dialogResults[#dialogs] or 'ok'
                    end,
                    stopModalWithResult = function(_, result)
                        stoppedResult = result
                    end,
                },
                LrFileUtils = {
                    chooseUniqueFileName = function(path)
                        return path
                    end,
                    delete = function(path)
                        os.remove(path)
                    end,
                },
                LrFunctionContext = {
                    callWithContext = function(_, callback)
                        local cleanupHandlers = {}
                        local context = {
                            addCleanupHandler = function(_, handler)
                                cleanupHandlers[#cleanupHandlers + 1] = handler
                            end,
                        }
                        local result = callback(context)

                        for _, handler in ipairs(cleanupHandlers) do
                            handler()
                        end

                        return result
                    end,
                },
                LrPathUtils = {
                    child = function(parent, child)
                        return parent .. '/' .. child
                    end,
                    getStandardFilePath = function()
                        return '/tmp'
                    end,
                    leafName = function(path)
                        return path:match('[^/\\]+$')
                    end,
                },
                LrView = {
                    bind = function(key)
                        return { key = key }
                    end,
                    osFactory = function()
                        return {
                            column = function(_, value) return value end,
                            control_spacing = function() return 4 end,
                            picture = function(_, value) return value end,
                            popup_menu = function(_, value) return value end,
                            push_button = function(_, value) return value end,
                            row = function(_, value) return value end,
                            spacer = function(_, value) return value end,
                        }
                    end,
                },
            }

            return assert(imports[name], 'Unexpected Lightroom import: ' .. tostring(name))
        end

        local dialog = assert(loadfile('crush-catalog.lrplugin/IdentificationDialog.lua'))()
        local predictions = { {
            confidence = 0.982,
            taxonomy = {
                'Animalia',
                'Chordata',
                'Mammalia',
                'Rodentia',
                'Sciuridae',
                'Sciurus',
                'niger',
            },
            taxonomy_ranks = {
                'kingdom',
                'phylum',
                'class',
                'order',
                'family',
                'genus',
                'species',
            },
            taxonomy_common_names = {
                'Animals', '', '', '', 'Squirrels', '', 'Fox Squirrel',
            },
        } }
        local items = dialog.predictionItems(predictions)
        local action = dialog.showForResponse(photo, {
            result = { results = {
                { predictions = predictions },
                { predictions = predictions },
            } },
            detectedImages = {
                { bytes = 'first jpeg bytes' },
                { bytes = 'second jpeg bytes' },
            },
        }, 3, 5)

        assert.are.equal(
            'Fox Squirrel (Sciurus niger) 98.2%',
            items[1].title
        )
        assert.are.equal('Confirm', dialogs[1].actionVerb)
        assert.are.equal('< exclude >', dialogs[1].cancelVerb)
        assert.are.equal('Stop', dialogs[1].accessoryView[1].title)
        assert.are.equal('Next Image', dialogs[1].accessoryView[3].title)
        assert.are.equal('Not An Animal', dialogs[1].accessoryView[4].title)
        assert.are.equal('Unsure', dialogs[1].accessoryView[5].title)
        dialogs[1].accessoryView[1].action({})
        assert.are.equal('other', stoppedResult)
        dialogs[1].accessoryView[3].action({})
        assert.are.equal('cancel', stoppedResult)
        dialogs[1].accessoryView[4].action({})
        assert.are.equal('not_an_animal', stoppedResult)
        dialogs[1].accessoryView[5].action({})
        assert.are.equal('unsure', stoppedResult)
        assert.are.equal('Image 3 of 5: bird.jpg (Animal 1 of 2)', dialogs[1].title)
        assert.are.equal('Image 3 of 5: bird.jpg (Animal 2 of 2)', dialogs[2].title)
        assert.are.equal('stop', action)

        local nextImageAction = dialog.showForResponse(photo, {
            result = { results = {
                { predictions = predictions },
                { predictions = predictions },
            } },
            detectedImages = {
                { bytes = 'first jpeg bytes' },
                { bytes = 'second jpeg bytes' },
            },
        }, 4, 5)
        assert.are.equal('next_image', nextImageAction)
        assert.are.equal(3, #dialogs)

        dialogs = {}
        dialogResults = { 'ok', 'unsure', 'not_an_animal' }
        local completedAction, dispositions = dialog.showForResponse(photo, {
            result = { results = {
                { predictions = predictions },
                { predictions = predictions },
                { predictions = predictions },
            } },
            detectedImages = {
                { bytes = 'first jpeg bytes' },
                { bytes = 'second jpeg bytes' },
                { bytes = 'third jpeg bytes' },
            },
        }, 5, 5)

        assert.are.equal('continue', completedAction)
        assert.are.equal('confirmed', dispositions[1].disposition)
        assert.are.equal(1, dispositions[1].selectedPredictionIndex)
        assert.are.equal(0.982, dispositions[1].selectedPrediction.confidence)
        assert.same(
            predictions[1].taxonomy,
            dispositions[1].selectedPrediction.taxonomy
        )
        assert.same(
            predictions[1].taxonomy_ranks,
            dispositions[1].selectedPrediction.taxonomyRanks
        )
        assert.same(
            predictions[1].taxonomy_common_names,
            dispositions[1].selectedPrediction.commonNameTaxonomy
        )
        assert.are.equal('unsure', dispositions[2].disposition)
        assert.are.equal('not_an_animal', dispositions[3].disposition)
    end)

    it('automatically dispositions high and low confidence detections', function()
        local dialogCount = 0
        local photo = { getFormattedMetadata = function() return 'bird.jpg' end }

        _G.import = function(name)
            local imports = {
                LrBinding = { makePropertyTable = function() return {} end },
                LrDialogs = {
                    presentModalDialog = function()
                        dialogCount = dialogCount + 1
                        return 'ok'
                    end,
                },
                LrFileUtils = {},
                LrFunctionContext = {},
                LrPathUtils = {},
                LrView = {},
            }
            return assert(imports[name])
        end

        local dialog = assert(loadfile(
            'crush-catalog.lrplugin/IdentificationDialog.lua'
        ))()
        local response = {
            result = { results = {
                { predictions = { { confidence = 0.9 } } },
                { predictions = { { confidence = 0.899 } } },
            } },
            detectedImages = { {}, {} },
        }
        local action, dispositions = dialog.showForResponse(
            photo,
            response,
            1,
            1,
            { mode = 'automatic', threshold = 90 }
        )

        assert.are.equal('continue', action)
        assert.are.equal('confirmed', dispositions[1].disposition)
        assert.are.equal('unsure', dispositions[2].disposition)
        assert.are.equal(0, dialogCount)
    end)

end)
