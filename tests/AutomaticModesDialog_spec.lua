describe('AutomaticModesDialog', function()
    local originalImport
    local originalLoc

    before_each(function()
        originalImport = _G.import
        originalLoc = _G.LOC
        _G.LOC = function(value) return value:match('=(.*)$') or value end
    end)

    after_each(function()
        _G.import = originalImport
        _G.LOC = originalLoc
    end)

    it('uses assisted mode, 90 percent, and only new images by default', function()
        local presented
        local properties = {}

        function properties.addObserver(_, _, callback)
            callback()
        end

        local function control(_, value) return value end
        _G.import = function(name)
            local imports = {
                LrBinding = { makePropertyTable = function() return properties end },
                LrDialogs = {
                    presentModalDialog = function(arguments)
                        presented = arguments
                        return 'ok'
                    end,
                },
                LrFunctionContext = {
                    callWithContext = function(_, callback) return callback({}) end,
                },
                LrView = {
                    bind = function(key) return { key = key } end,
                    osFactory = function()
                        return {
                            column = control,
                            control_spacing = function() return 4 end,
                            edit_field = control,
                            group_box = control,
                            radio_button = control,
                            row = control,
                            static_text = control,
                        }
                    end,
                },
            }
            return assert(imports[name])
        end

        local dialog = assert(loadfile(
            'crush-catalog.lrplugin/AutomaticModesDialog.lua'
        ))()
        local options = dialog.show()

        assert.are.equal('assisted', options.mode)
        assert.are.equal(90, options.threshold)
        assert.are.equal('new', options.processingScope)
        assert.is_true(properties.valid)
        assert.are.equal('Okay', presented.actionVerb)
        assert.are.equal('valid', presented.actionBinding.enabled.key)
        assert.are.equal('Images to Process', presented.contents[1].title)
        assert.are.equal('Mode:', presented.contents[2].title)
        assert.are.equal('<system>', presented.contents[1][1][1].font)
        assert.are.equal('<system>', presented.contents[2][1][1].font)
        assert.are.equal(
            'Confidence Threshold:',
            presented.contents[3][1].title
        )
        assert.are.equal('<system>', presented.contents[3][1].font)
        assert.are.equal('threshold', presented.contents[3][2].value.key)
    end)
end)
