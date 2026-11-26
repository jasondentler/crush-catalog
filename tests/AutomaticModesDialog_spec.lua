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

    local function run(onPresent)
        local properties, presented, observers = {}, {}, {}
        function properties.addObserver(_, key, callback)
            observers[key] = callback
        end
        local function change(key, value)
            properties[key] = value
            if observers[key] then observers[key]() end
        end
        local function control(_, value) return value end
        _G.import = function(name)
            local imports = {
                LrBinding = { makePropertyTable = function() return properties end },
                LrDialogs = {
                    presentModalDialog = function(arguments)
                        presented[#presented + 1] = arguments
                        return onPresent(arguments, properties, change, #presented)
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
                            view = function(_, value)
                                value.layout = 'view'
                                return value
                            end,
                            control_spacing = function() return 4 end,
                            edit_field = control,
                            group_box = control,
                            radio_button = control,
                            tab_view = control,
                            tab_view_item = control,
                            row = function(_, value)
                                value.layout = 'row'
                                return value
                            end,
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
        return options, presented, properties
    end

    it('defaults to automatic identification of new images on the General tab', function()
        local options, presented, properties = run(function() return 'ok' end)
        assert.are.equal('automatic', options.mode)
        assert.are.equal(70, options.threshold)
        assert.are.equal('new', options.processingScope)
        assert.are.equal('batch', options.engine)
        assert.are.equal(0, options.detectorThreshold)
        assert.are.equal(5, options.cropDetailThreshold)
        assert.is_true(properties.valid)
        assert.are.equal('general', properties.selectedTab)
        assert.are.equal(1, #presented)
        local dialog = presented[1]
        assert.are.equal('selectedTab', dialog.contents.value.key)
        assert.are.equal(2, #dialog.contents)
        assert.is_nil(dialog.otherVerb)
        assert.are.equal('Okay', dialog.actionVerb)
        assert.are.equal('valid', dialog.actionBinding.enabled.key)
        local general = dialog.contents[1]
        assert.are.equal('General', general.title)
        assert.are.equal('general', general.identifier)
        assert.are.equal('Images to Process', general[1][1][1].title)
        assert.are.equal('Mode:', general[1][2][1].title)
        assert.are.equal('row', general[1].layout)
        assert.are.equal(1, general[1].fill_horizontal)
        for index, group in ipairs(general[1]) do
            assert.are.equal('view', group[2].layout)
            assert.are.equal('vertical', group[2].place)
            assert.are.equal(4, group[2].margin)
            assert.are.equal(3, #group[2])
            for _, radio in ipairs(group[2]) do
                assert.are.equal(index == 1 and 'processingScope' or 'mode', radio.value.key)
                assert.is_nil(radio.size)
                assert.is_nil(radio.font)
            end
        end
    end)

    it('builds all three advanced controls before presenting the dialog', function()
        local options, presented = run(function(_, _, change)
            change('processingScope', 'all')
            change('mode', 'manual')
            change('selectedTab', 'advanced')
            change('threshold', '85')
            change('cropDetailThreshold', '0')
            change('selectedTab', 'general')
            return 'ok'
        end)
        assert.are.equal(1, #presented)
        local advanced = presented[1].contents[2]
        assert.are.equal('Advanced', advanced.title)
        assert.are.equal('advanced', advanced.identifier)
        local controls = advanced[1]
        assert.are.equal(4, #controls)
        assert.are.equal('Species confidence', controls[1][1].title)
        assert.are.equal('threshold', controls[1][2].value.key)
        assert.matches('auto%-accept', controls[1][4].title)
        assert.are.equal('detectorThreshold', controls[2][2].value.key)
        assert.matches('weak detections', controls[2][4].title)
        assert.are.equal('cropDetailThreshold', controls[3][2].value.key)
        assert.matches('low%-detail crops', controls[3][4].title)
        for index = 1, 3 do
            local row = controls[index]
            assert.are.equal('row', row.layout)
            assert.are.equal(140, row[1].width)
            assert.are.equal(3, row[2].width_in_digits)
            assert.are.equal(36, row[3].width)
        end
        assert.matches('may miss real subjects', controls[4].title)
        assert.are.equal('all', options.processingScope)
        assert.are.equal('manual', options.mode)
        assert.are.equal('batch', options.engine)
        assert.are.equal(85, options.threshold)
        assert.are.equal(0, options.cropDetailThreshold)
    end)

    it('rejects invalid thresholds on either tab', function()
        local options = run(function(_, properties, change)
            change('selectedTab', 'advanced')
            change('cropDetailThreshold', '101')
            assert.is_false(properties.valid)
            change('selectedTab', 'general')
            assert.is_false(properties.valid)
            change('cropDetailThreshold', '5')
            assert.is_true(properties.valid)
            change('detectorThreshold', '-1')
            assert.is_false(properties.valid)
            change('detectorThreshold', '0')
            assert.is_true(properties.valid)
            change('threshold', '101')
            assert.is_false(properties.valid)
            change('threshold', '70')
            assert.is_true(properties.valid)
            return 'ok'
        end)
        assert.are.equal('batch', options.engine)
    end)

    it('cancels without identification options from either tab', function()
        assert.is_nil(run(function() return 'cancel' end))
        local options = run(function(_, _, change)
            change('selectedTab', 'advanced')
            return 'cancel'
        end)
        assert.is_nil(options)
    end)
end)
