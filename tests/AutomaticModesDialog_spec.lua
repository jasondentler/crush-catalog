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

    it('uses assisted mode, 90 percent, and no reprocessing by default', function()
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
                            checkbox = control,
                            column = control,
                            control_spacing = function() return 4 end,
                            edit_field = control,
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
        assert.is_false(options.reprocess)
        assert.is_true(properties.valid)
        assert.are.equal('Okay', presented.actionVerb)
        assert.are.equal('valid', presented.actionBinding.enabled.key)
    end)
end)
