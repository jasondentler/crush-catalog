-- Prepare a bounded original-file batch; local paths never enter the manifest.
local Manifest = {}
local MAX_FRAMES = 256

local function identifier(value)
    return type(value) == 'string' and #value <= 120
        and value:match('^[a-zA-Z0-9][a-zA-Z0-9_.%-]*$') ~= nil
end

local function number(value)
    return type(value) == 'number' and value == value and math.abs(value) < math.huge
end

local function timestamp(value)
    if type(value) ~= 'string' then return nil end
    local y, m, d, h, minute, sec, suffix = value:match(
        '^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)(.*)$')
    if not y then return nil end
    y, m, d = tonumber(y), tonumber(m), tonumber(d)
    local days = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
    if y % 4 == 0 and (y % 100 ~= 0 or y % 400 == 0) then days[2] = 29 end
    if y == 0 or not days[m] or d < 1 or d > days[m]
        or tonumber(h) > 23 or tonumber(minute) > 59 or tonumber(sec) > 59 then
        return nil
    end
    local fraction = suffix:match('^%.(%d+)')
    if fraction then suffix = suffix:sub(#fraction + 2) end
    local digits = fraction and #fraction or 0
    if digits > 6 then return nil end
    if suffix ~= '' and suffix ~= 'Z' then
        local zh, zm = suffix:match('^[+%-](%d%d):(%d%d)$')
        if not zh or tonumber(zh) > 23 or tonumber(zm) > 59 then return nil end
    end
    return value, digits
end

local function gps(value)
    if type(value) == 'table' and number(value.latitude) and number(value.longitude)
        and math.abs(value.latitude) <= 90 and math.abs(value.longitude) <= 180 then
        return { latitude = value.latitude, longitude = value.longitude }
    end
end

local function basename(path)
    return type(path) == 'string' and path:match('([^/\\]+)$') or nil
end

local function nonempty(value)
    return type(value) == 'string' and value:match('%S') ~= nil
end

local function safeName(name)
    return nonempty(name) and #name <= 255 and name ~= '.' and name ~= '..'
        and not name:find('[/\\%z]')
end

local function eligible(item)
    if not identifier(item.photoId) or not identifier(item.sourceId) then
        return 'identity_unavailable'
    end
    if item.isVideo then return 'unsupported_video' end
    -- Original pixels cannot represent a virtual copy or a cropped develop view.
    -- Return these to the caller for an explicit alternate workflow.
    if item.isVirtualCopy ~= false or item.isCropped ~= false then
        return 'develop_view_unverified'
    end
    if not number(item.modifiedAt) or not number(item.editCount)
        or not number(item.lastEditTime) then
        return 'snapshot_unavailable'
    end
    if not nonempty(item.path) or not safeName(basename(item.path))
        or not number(item.byteCount) or item.byteCount <= 0
        or item.byteCount % 1 ~= 0 then
        return 'original_unavailable'
    end
end

local function opaqueId(index, key, prefix)
    if not nonempty(key) then return nil end
    if not index.ids[key] then
        index.count = index.count + 1
        index.ids[key] = prefix .. tostring(index.count)
    end
    return index.ids[key]
end

local function build(items, options)
    local frames, assets, cameras, sessions = {}, {}, { count = 0, ids = {} },
        { count = 0, ids = {} }
    local mode = 'independent'
    for _, item in ipairs(items) do
        local capture, precision = timestamp(item.capturedAt)
        local coordinates = gps(item.gps)
        local absent = item.gpsAbsent == true and item.gps == nil
        local camera = opaqueId(cameras, item.cameraKey, 'camera-')
        local session = opaqueId(sessions, item.sessionKey, 'sequence-')
        local full = {
            representation_id = 'full', role = 'full',
            filename = basename(item.path), byte_count = item.byteCount,
        }
        local frame = {
            frame_id = item.photoId, source_id = item.sourceId,
            captured_at = capture, fractional_digits = precision,
            gps = coordinates, gps_absent = absent,
            common_name_language = options.language,
            camera_id = camera, session_id = session,
            representations = { full },
        }
        local blockers = {}
        if options.enableBurst == false then blockers[#blockers + 1] = 'Burst disabled' end
        if not session then blockers[#blockers + 1] = 'Sequence identity unavailable' end
        if not capture or precision == 0 then blockers[#blockers + 1] = 'Subsecond time unavailable' end
        if not coordinates and not absent then blockers[#blockers + 1] = 'GPS context unknown' end
        if not item.path:lower():match('%.arw$') then
            blockers[#blockers + 1] = 'Not Sony ARW'
        end
        local preview = #blockers == 0
        if preview then
            frame.representations[2] = {
                representation_id = 'preview', role = 'preview', filename = 'preview.jpg',
            }
            mode = 'burst'
        end
        frames[#frames + 1] = frame
        assets[frame.frame_id] = { item = item, preview = preview, previewBlockers = blockers }
    end
    local plan = {
        manifest = { schema_version = 1, execution_mode = mode, frames = frames },
        items = assets,
    }
    local temporary, closed = nil, false
    local function release()
        if temporary then
            if not options.removePreview(temporary) then return false end
            temporary = nil
        end
        return true
    end
    function plan.resolveAsset(frameId, representationId, role)
        if closed then return nil end
        -- Batch.run uploads synchronously. At the next request, the prior
        -- preview has already been consumed; keep at most one temporary file.
        if not release() then error('Temporary preview cleanup failed', 0) end
        local entry = assets[frameId]
        if not entry or not options.isCurrent(entry.item) then return nil end
        if representationId == 'full' and role == 'full' then return entry.item.path end
        if representationId ~= 'preview' or role ~= 'preview' or not entry.preview then
            return nil
        end
        temporary = options.makePreview(entry.item.path)
        return temporary
    end
    function plan.close()
        closed = true
        return release()
    end
    return plan
end

-- Preserve selection order, split at exclusions and the API limit. No hidden
-- reordering or truncation; excluded items remain explicit for the caller.
function Manifest.prepare(items, options)
    assert(type(items) == 'table' and type(options) == 'table', 'Invalid batch input')
    assert(type(options.language) == 'string' and #options.language > 0
        and #options.language <= 64, 'Invalid common name language')
    assert(type(options.isCurrent) == 'function' and type(options.makePreview) == 'function'
        and type(options.removePreview) == 'function', 'Missing asset callbacks')
    local plans, excluded, pending, seen, paths, resumed = {}, {}, {}, {}, {}, {}
    local function resumeMatch(item)
        local saved = options.resumeFrames and options.resumeFrames[item.photoId]
        if not saved then return false end
        local frame = saved.frame
        local full = frame and frame.representations and frame.representations[1]
        local a, b = gps(item.gps), frame and frame.gps
        local sameGps = (a == nil and b == nil) or (a and b
            and math.abs(a.latitude - b.latitude) <= 1e-9
            and math.abs(a.longitude - b.longitude) <= 1e-9)
        return frame and full and full.role == 'full'
            and frame.frame_id == item.photoId and frame.source_id == item.sourceId
            and frame.captured_at == timestamp(item.capturedAt) and sameGps
            and frame.common_name_language == options.language
            and full.filename == basename(item.path) and full.byte_count == item.byteCount
    end
    local function flush()
        if #pending > 0 then
            plans[#plans + 1] = build(pending, options)
            pending = {}
        end
    end
    for _, item in ipairs(items) do
        local reason = eligible(item)
        if not reason and seen[item.photoId] then reason = 'duplicate_photo' end
        if not reason and paths[item.path] then reason = 'repeated_source_path' end
        if reason then
            flush()
            excluded[#excluded + 1] = { item = item, reason = reason }
        elseif resumeMatch(item) then
            flush()
            seen[item.photoId] = true
            paths[item.path] = true
            resumed[#resumed + 1] = {
                frame_id = item.photoId, batch_id = options.resumeFrames[item.photoId].batch_id,
            }
        else
            seen[item.photoId] = true
            paths[item.path] = true
            pending[#pending + 1] = item
            if #pending == MAX_FRAMES then flush() end
        end
    end
    flush()
    return plans, excluded, resumed
end

-- Protect against changes to source or catalog edit state before later writes.
-- This is a snapshot guard, not a cryptographic develop digest.
function Manifest.sameSnapshot(first, second)
    local a, b = gps(first.gps), gps(second.gps)
    local sameGps = (a == nil and b == nil) or (a and b
        and a.latitude == b.latitude and a.longitude == b.longitude)
    return sameGps and first.capturedAt == second.capturedAt
        and first.cameraKey == second.cameraKey and first.sessionKey == second.sessionKey
        and first.gpsAbsent == second.gpsAbsent
        and first.photoId == second.photoId and first.sourceId == second.sourceId
        and first.path == second.path and first.byteCount == second.byteCount
        and number(first.modifiedAt) and first.modifiedAt == second.modifiedAt
        and number(first.editCount) and first.editCount == second.editCount
        and number(first.lastEditTime) and first.lastEditTime == second.lastEditTime
        and first.isVirtualCopy == second.isVirtualCopy
        and first.isCropped == second.isCropped
end

return Manifest
