-- Sony ARW full-resolution embedded JPEG, without demosaic or marker searches.
-- The caller owns the source file; this module only opens it read-only.
local Preview = {}
local MAX_BYTES = 32 * 1024 * 1024
local MAX_PIXELS = 11648 * 8742

local function uint(bytes, little)
    local value = 0
    for i = 1, #bytes do
        local index = little and (#bytes - i + 1) or i
        value = value * 256 + bytes:byte(index)
    end
    return value
end

local function tiffHeader(read)
    local header = read(0, 8)
    if not header then return nil end
    local order = header:sub(1, 2)
    if order ~= 'II' and order ~= 'MM' then return nil end
    local little = order == 'II'
    if uint(header:sub(3, 4), little) ~= 42 then return nil end
    return little, uint(header:sub(5, 8), little)
end

local function directory(read, little, offset)
    if offset < 8 then return nil end
    local countBytes = read(offset, 2)
    if not countBytes then return nil end
    local count = uint(countBytes, little)
    if count > 4096 then return nil end
    local entries = read(offset + 2, count * 12 + 4)
    if not entries then return nil end
    local tags = {}
    for i = 0, count - 1 do
        local entry = entries:sub(i * 12 + 1, i * 12 + 12)
        local tag = uint(entry:sub(1, 2), little)
        if tag == 0x0100 or tag == 0x0101 or tag == 0x0103
            or tag == 0x0112 or tag == 0x0201 or tag == 0x0202 then
            local kind = uint(entry:sub(3, 4), little)
            local items = uint(entry:sub(5, 8), little)
            if tags[tag] ~= nil or items ~= 1 or (kind ~= 3 and kind ~= 4) then
                return nil
            end
            tags[tag] = uint(entry:sub(9, kind == 3 and 10 or 12), little)
        end
    end
    if tags[0x0112] and (tags[0x0112] < 1 or tags[0x0112] > 8) then
        return nil
    end
    return tags, uint(entries:sub(-4), little)
end

local function stringReader(bytes)
    return function(offset, count)
        if offset < 0 or count < 0 or offset + count > #bytes then return nil end
        return bytes:sub(offset + 1, offset + count)
    end
end

local function jpegInfo(bytes)
    if bytes:sub(1, 2) ~= string.char(255, 216)
        or bytes:sub(-2) ~= string.char(255, 217) then
        return nil
    end
    local pos, width, height, orientation = 3, nil, nil, nil
    local segments = 0
    while pos + 3 <= #bytes and segments < 1024 do
        segments = segments + 1
        if bytes:byte(pos) ~= 255 then return nil end
        repeat pos = pos + 1 until bytes:byte(pos) ~= 255
        local marker = bytes:byte(pos)
        if not marker or marker == 0 or marker == 216 or marker == 217 then return nil end
        pos = pos + 1
        if pos + 1 > #bytes then return nil end
        local length = uint(bytes:sub(pos, pos + 1), false)
        if length < 2 or pos + length > #bytes - 1 then return nil end
        if marker == 0xE1 and bytes:sub(pos + 2, pos + 7) == 'Exif\0\0' then
            local read = stringReader(bytes:sub(pos + 8, pos + length - 1))
            local little, offset = tiffHeader(read)
            local tags = offset and directory(read, little, offset)
            if not tags then return nil end
            local value = tags[0x0112] or 1
            if orientation and orientation ~= value then return nil end
            orientation = value
        elseif marker == 0xC0 or marker == 0xC1 or marker == 0xC2 then
            if length < 8 or width then return nil end
            height = uint(bytes:sub(pos + 3, pos + 4), false)
            width = uint(bytes:sub(pos + 5, pos + 6), false)
        elseif marker == 0xDA then
            if not width or not height or width < 640 or height < 640
                or width * height > MAX_PIXELS then
                return nil
            end
            return { width = width, height = height, orientation = orientation }
        end
        pos = pos + length
    end
    return nil
end

local function orientationSegment(orientation)
    -- Minimal little-endian EXIF IFD with only the orientation tag.
    local exif = 'Exif\0\0II' .. string.char(
        42, 0, 8, 0, 0, 0, 1, 0,
        0x12, 0x01, 3, 0, 1, 0, 0, 0, orientation, 0, 0, 0,
        0, 0, 0, 0
    )
    return string.char(255, 225, 0, #exif + 2) .. exif
end

function Preview.inspect(read, size)
    if type(size) ~= 'number' or size < 8 then return nil, 'invalid_raw' end
    local function bounded(offset, count)
        if offset < 0 or count < 0 or offset + count > size then return nil end
        local bytes = read(offset, count)
        if type(bytes) == 'string' and #bytes == count then return bytes end
    end
    local little, offset = tiffHeader(bounded)
    if not offset then return nil, 'unsupported_tiff' end
    local seen, candidates, rootOrientation = {}, {}, nil
    -- Follow only the top-level IFD chain. The observed Sony full-size JPEG
    -- has compression 7, dimensions, and JPEGInterchangeFormat/Length.
    -- Compression 6 thumbnails and RAW SubIFDs are not equivalent.
    for index = 1, 16 do
        if offset == 0 then break end
        if seen[offset] then return nil, 'unsupported_tiff' end
        seen[offset] = true
        local tags, nextOffset = directory(bounded, little, offset)
        if not tags then return nil, 'unsupported_tiff' end
        if index == 1 then rootOrientation = tags[0x0112] end
        local w, h = tags[0x0100], tags[0x0101]
        if tags[0x0103] == 7 and w and h and w >= 640 and h >= 640
            and w * h <= MAX_PIXELS then
            candidates[#candidates + 1] = tags
        end
        offset = nextOffset
    end
    if offset ~= 0 then return nil, 'unsupported_tiff' end
    if #candidates ~= 1 then return nil, 'preview_unavailable' end
    local tags = candidates[1]
    local start, length = tags[0x0201], tags[0x0202]
    if not start or not length or start < 8 or length < 4 or length > MAX_BYTES
        or start + length > size then
        return nil, 'preview_unavailable'
    end
    local bytes = bounded(start, length)
    local info = bytes and jpegInfo(bytes)
    if not info or info.width ~= tags[0x0100] or info.height ~= tags[0x0101] then
        return nil, 'invalid_or_small_preview'
    end
    local orientation = tags[0x0112]
    if not orientation or (rootOrientation and rootOrientation ~= orientation)
        or (info.orientation and info.orientation ~= orientation) then
        return nil, 'orientation_unverified'
    end
    if not info.orientation and orientation ~= 1 then
        -- Inject only orientation metadata; leave compressed pixels untouched.
        bytes = bytes:sub(1, 2) .. orientationSegment(orientation) .. bytes:sub(3)
    end
    if #bytes > MAX_BYTES then return nil, 'preview_unavailable' end
    if orientation >= 5 then
        info.width, info.height = info.height, info.width
    end
    info.orientation = orientation
    info.byteCount = #bytes
    info.bytes = bytes
    return info
end

function Preview.extract(path)
    if type(path) ~= 'string' or not path:lower():match('%.arw$') then
        return nil, 'unsupported_raw'
    end
    local file = io.open(path, 'rb')
    if not file then return nil, 'source_unavailable' end
    local ok, result, reason = pcall(function()
        local size = file:seek('end')
        return Preview.inspect(function(offset, count)
            if not file:seek('set', offset) then return nil end
            return file:read(count)
        end, size)
    end)
    file:close()
    if not ok then return nil, 'preview_read_failed' end
    return result, reason
end

return Preview
