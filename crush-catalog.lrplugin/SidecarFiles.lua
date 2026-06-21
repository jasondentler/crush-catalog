local SidecarFiles = {}
local LrFileUtils = import 'LrFileUtils'

local function pluginPath()
    if _PLUGIN ~= nil and _PLUGIN.path ~= nil then
        return _PLUGIN.path
    end

    local source = debug.getinfo(1, 'S').source
    return source:match('^@(.+)/[^/]+$') or '.'
end

local JSON = assert(loadfile(pluginPath() .. '/JSON.lua'))()
local SidecarLogic = assert(
    loadfile(pluginPath() .. '/Core/SidecarLogic.lua')
)()

local function readAll(path)
    local file, message = io.open(path, 'rb')

    if file == nil then
        error('Could not open Crush Catalog data file: ' .. tostring(message))
    end

    local contents = file:read('*a')
    file:close()
    return contents
end

local function writeAtomically(path, contents)
    local temporaryPath = path .. '.tmp'
    local file, message = io.open(temporaryPath, 'wb')

    if file == nil then
        error('Could not create Crush Catalog data file: ' .. tostring(message))
    end

    local written, writeError = file:write(contents)
    local closed, closeError = file:close()

    if written == nil or not closed then
        LrFileUtils.delete(temporaryPath)
        error('Could not write Crush Catalog data file: '
            .. tostring(writeError or closeError))
    end

    if LrFileUtils.exists(path) then
        local deleted, deleteError = LrFileUtils.delete(path)

        if not deleted then
            LrFileUtils.delete(temporaryPath)
            error('Could not replace Crush Catalog data file: '
                .. tostring(deleteError))
        end
    end

    local renamed, renameError = LrFileUtils.move(temporaryPath, path)

    if not renamed then
        LrFileUtils.delete(temporaryPath)
        error('Could not replace Crush Catalog data file: '
            .. tostring(renameError))
    end
end

function SidecarFiles.export(path, sourceFile, values)
    local sidecar = SidecarLogic.create(sourceFile, values)
    local encoded = JSON:encode_pretty(sidecar)
    writeAtomically(SidecarLogic.pathForPhoto(path), encoded .. '\n')
end

function SidecarFiles.import(path, sourceFile)
    local contents = readAll(SidecarLogic.pathForPhoto(path))
    local decoded = JSON:decode(contents, nil, { strictParsing = true })
    return SidecarLogic.metadataValues(decoded, sourceFile)
end

SidecarFiles.logic = SidecarLogic

return SidecarFiles
