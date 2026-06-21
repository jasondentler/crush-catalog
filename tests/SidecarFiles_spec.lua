describe('SidecarFiles', function()
    local originalImport
    local originalRemove
    local originalRename

    before_each(function()
        originalImport = _G.import
        originalRemove = os.remove
        originalRename = os.rename
    end)

    after_each(function()
        _G.import = originalImport
        rawset(os, 'remove', originalRemove)
        rawset(os, 'rename', originalRename)
    end)

    it('round trips and overwrites without standard os file functions', function()
        local photoPath = os.tmpname()
        local sidecarPath = photoPath .. '.crush-catalog.json'

        originalRemove(photoPath)
        _G.import = function(name)
            assert.are.equal('LrFileUtils', name)
            return {
                exists = function(path)
                    local file = io.open(path, 'rb')

                    if file == nil then return false end

                    file:close()
                    return 'file'
                end,
                delete = function(path)
                    local removed, message = originalRemove(path)
                    return removed ~= nil, message
                end,
                move = function(source, destination)
                    local moved, message = originalRename(source, destination)
                    return moved ~= nil, message
                end,
            }
        end

        rawset(os, 'remove', nil)
        rawset(os, 'rename', nil)
        local files = assert(loadfile(
            'crush-catalog.lrplugin/SidecarFiles.lua'
        ))()

        files.export(photoPath, 'bird.CR3', {
            commonNames = 'American Robin',
            detectionCount = '1',
        })
        files.export(photoPath, 'bird.CR3', {
            commonNames = 'Fox Squirrel',
            detectionCount = '2',
        })

        local values = files.import(photoPath, 'bird.CR3')
        assert.are.equal('Fox Squirrel', values.commonNames)
        assert.are.equal('2', values.detectionCount)
        originalRemove(sidecarPath)
    end)
end)
