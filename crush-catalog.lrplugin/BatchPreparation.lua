-- Lightroom adapter for the read-only batch preparation layer.
local LrFileUtils = import 'LrFileUtils'
local LrPathUtils = import 'LrPathUtils'
local LrTasks = import 'LrTasks'
local LrUUID = import 'LrUUID'
local LrLocalization = import 'LrLocalization'

local function pluginPath()
    if _PLUGIN and _PLUGIN.path then return _PLUGIN.path end
    return debug.getinfo(1, 'S').source:match('^@(.+)/[^/]+$') or '.'
end

local Manifest = assert(loadfile(pluginPath() .. '/Core/BatchManifest.lua'))()
local Preview = assert(loadfile(pluginPath() .. '/Core/RawPreview.lua'))()
local LightroomRender = assert(loadfile(pluginPath() .. '/LightroomRender.lua'))()
local Preparation = {}

local function meaningful(value)
    return type(value) == 'string' and value:match('%S') ~= nil
        and value ~= '0' and value ~= 'Unknown' and value ~= '-'
end

local function snapshot(photo)
    local path = photo:getRawMetadata('path')
    local id = photo:getRawMetadata('uuid')
    local virtual = photo:getRawMetadata('isVirtualCopy')
    local master = virtual and photo:getRawMetadata('masterPhoto') or nil
    local source = master and master:getRawMetadata('uuid') or (not virtual and id or nil)
    local capture = photo:getRawMetadata('dateTimeOriginalISO8601')
    local serial = photo:getFormattedMetadata('cameraSerialNumber')
    local make = photo:getFormattedMetadata('cameraMake')
    local model = photo:getFormattedMetadata('cameraModel')
    local camera, sequence
    if meaningful(serial) and meaningful(make) and meaningful(model) then
        camera = make .. '\0' .. model .. '\0' .. serial
    end
    -- The import folder/date is a sequence partition, not a burst ID.
    -- Use the known camera model to partition it even without a body serial.
    -- Wild Catalog still verifies timing and visual continuity.
    local date = type(capture) == 'string' and capture:match('^%d%d%d%d%-%d%d%-%d%d')
    local folder = path and LrPathUtils.parent(path)
    if date and folder then
        sequence = folder .. '\0' .. date .. '\0'
            .. (meaningful(make) and make or '') .. '\0'
            .. (meaningful(model) and model or '')
    end
    local attrs = path and LrFileUtils.exists(path) == 'file'
        and LrFileUtils.fileAttributes(path) or {}
    return {
        photo = photo, photoId = id, sourceId = source, path = path,
        isVirtualCopy = virtual, isCropped = photo:getRawMetadata('isCropped'),
        isVideo = photo:getRawMetadata('isVideo'),
        capturedAt = capture, gps = photo:getRawMetadata('gps'),
        -- Missing Lightroom GPS does not prove absence from the source EXIF.
        cameraKey = camera, sessionKey = sequence,
        editCount = photo:getRawMetadata('editCount'),
        lastEditTime = photo:getRawMetadata('lastEditTime'),
        byteCount = attrs.fileSize, modifiedAt = attrs.fileModificationDate,
    }
end

function Preparation.isCurrent(item)
    local ok, current = LrTasks.pcall(snapshot, item.photo)
    return ok and Manifest.sameSnapshot(item, current)
end

-- Only generated files owned by this preparation are ever removed.
local function previewCallbacks()
    local owned = {}
    local function remove(path)
        if not owned[path] then return false end
        if LrFileUtils.exists(path) and not LrFileUtils.delete(path) then return false end
        owned[path] = nil
        return true
    end
    local function make(path)
        local info = Preview.extract(path)
        if not info then return nil end
        local name = 'crush-preview-' .. LrUUID.generateUUID() .. '.jpg'
        local target = LrPathUtils.child(LrPathUtils.getStandardFilePath('temp'), name)
        if LrFileUtils.exists(target) then return nil end
        local file = io.open(target, 'wb')
        if not file then return nil end
        owned[target] = true
        local ok = file:write(info.bytes)
        local closed = file:close()
        if not ok or not closed then
            if not remove(target) then error('Temporary preview cleanup failed', 0) end
            return nil
        end
        return target
    end
    return make, remove
end

function Preparation.prepare(photos, options)
    options = options or {}
    local items = {}
    for _, photo in ipairs(photos) do
        if options.isCanceled and options.isCanceled() then error('Batch canceled', 0) end
        local ok, item = LrTasks.pcall(snapshot, photo)
        items[#items + 1] = ok and item or { photo = photo }
    end
    local makePreview, removePreview = previewCallbacks()
    return Manifest.prepare(items, {
        language = options.language or LrLocalization.currentLanguage(),
        enableBurst = options.enableBurst,
        resumeFrames = options.resumeFrames,
        isCurrent = Preparation.isCurrent,
        makePreview = makePreview, removePreview = removePreview,
    })
end

-- Share one lazily initialized renderer across all batches in an identification run.
function Preparation.renderRun()
    local render, cleanup, finish
    return {
        render = function(photo)
            if not render then
                local ok
                ok, render, cleanup, finish = LrTasks.pcall(LightroomRender.create)
                if not ok then render, cleanup, finish = nil, nil, nil; return nil end
            end
            return render(photo)
        end,
        cleanup = function() return not cleanup or cleanup() end,
        finish = function() return not finish or finish() end,
    }
end

-- Call inside a Lightroom asynchronous task.
-- The caller retains plan.items to map final results to the original photos.
function Preparation.run(plan, identifyBatch, options)
    options = options or {}
    local run = options.renderRun or Preparation.renderRun()
    local function close()
        local removed = plan.close()
        local renderedRemoved = run.cleanup()
        return removed and renderedRemoved
    end
    local function resolveRendered(id)
        local entry = plan.items and plan.items[id]
        if not entry or not Preparation.isCurrent(entry.item) then return nil end
        local path = run.render(entry.item.photo)
        -- A temporary virtual copy must not invalidate the master's snapshot.
        if path and Preparation.isCurrent(entry.item) then return path end
        return nil
    end
    local ok, result = LrTasks.pcall(identifyBatch, plan.manifest, {
        baseUrl = options.baseUrl,
        forceUpload = options.forceUpload,
        isCanceled = options.isCanceled,
        isUploadCanceled = options.isUploadCanceled,
        onProgress = options.onProgress,
        onCompleted = options.onCompleted and function(final, getCrop)
            if not close() then error('Temporary image cleanup failed', 0) end
            return options.onCompleted(final, getCrop)
        end or nil,
        resolveAsset = plan.resolveAsset,
        resolveLocalSource = plan.resolveLocalSource,
        resolveRendered = resolveRendered,
    })
    local cleanupOk, removed = LrTasks.pcall(close)
    local finishOk, finished = true, true
    if not options.renderRun then finishOk, finished = LrTasks.pcall(run.finish) end
    if not finishOk or not finished then error('Temporary virtual copy cleanup failed', 0) end
    if not cleanupOk or not removed then
        error('Temporary preview cleanup failed', 0)
    end
    if not ok then error(result, 0) end
    return result
end

return Preparation
