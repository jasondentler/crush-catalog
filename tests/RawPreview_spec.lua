local Preview = assert(loadfile('crush-catalog.lrplugin/Core/RawPreview.lua'))()

local function pack(value, count, little)
    local bytes = {}
    for i = 1, count do
        bytes[little and i or count - i + 1] = string.char(value % 256)
        value = math.floor(value / 256)
    end
    return table.concat(bytes)
end

local function tiff(tags, little, nextOffset)
    local function word(value) return pack(value, 2, little) end
    local function long(value) return pack(value, 4, little) end
    local entries = {}
    for _, tag in ipairs(tags) do
        local value = tag[2]
        local kind = tag[1] == 0x0112 and 3 or 4
        entries[#entries + 1] = word(tag[1]) .. word(kind) .. long(1)
            .. (kind == 3 and word(value) .. word(0) or long(value))
    end
    return (little and 'II' or 'MM') .. word(42) .. long(8)
        .. word(#tags) .. table.concat(entries) .. long(nextOffset or 0)
end

local function segment(marker, body)
    return string.char(255, marker) .. pack(#body + 2, 2, false) .. body
end

-- Structural fixtures only: the backend must still decode real JPEG pixels.
local function jpeg(width, height, orientation)
    local exif = ''
    if orientation then
        exif = segment(0xE1, 'Exif\0\0' .. tiff({ { 0x0112, orientation } }, true))
    end
    local sof = string.char(8) .. pack(height, 2, false) .. pack(width, 2, false)
        .. string.char(1, 1, 0x11, 0)
    local sos = string.char(1, 1, 0, 0, 63, 0)
    return string.char(255, 216) .. exif .. segment(0xC0, sof)
        .. segment(0xDA, sos) .. 'data' .. string.char(255, 217)
end

local function raw(preview, little, orientation, offset, length)
    return tiff({
        { 0x0100, 1600 }, { 0x0101, 1200 }, { 0x0103, 7 },
        { 0x0112, orientation or 1 },
        { 0x0201, offset or 86 },
        { 0x0202, length or #preview },
    }, little) .. preview
end

local function inspect(bytes)
    local reads = {}
    local result, reason = Preview.inspect(function(offset, count)
        assert.is_true(offset >= 0 and offset + count <= #bytes)
        reads[#reads + 1] = count
        return bytes:sub(offset + 1, offset + count)
    end, #bytes)
    return result, reason, reads
end

describe('RawPreview', function()
    it('preserves native JPEG bytes and reads only the declared range', function()
        local preview = jpeg(1600, 1200)
        local result, reason, reads = inspect(raw(preview, true))
        assert.is_nil(reason)
        assert.are.equal(preview, result.bytes)
        assert.are.equal(#preview, result.byteCount)
        assert.are.equal(1600, result.width)
        assert.are.equal(1200, result.height)
        assert.same({ 8, 2, 76, #preview }, reads)
    end)

    it('supports big-endian TIFF and matching rotated EXIF orientation', function()
        local result = inspect(raw(jpeg(1600, 1200, 6), false, 6))
        assert.are.equal(1200, result.width)
        assert.are.equal(1600, result.height)
        assert.are.equal(6, result.orientation)
    end)

    it('declines conflicting native JPEG and TIFF orientation', function()
        local result, reason = inspect(raw(jpeg(1600, 1200, 8), true, 6))
        assert.is_nil(result)
        assert.are.equal('orientation_unverified', reason)
    end)

    it('adds minimal EXIF orientation without altering compressed bytes', function()
        local preview = jpeg(1600, 1200)
        local result = inspect(raw(preview, true, 8))
        assert.are.equal(1200, result.width)
        assert.are.equal(1600, result.height)
        assert.are.equal(8, result.orientation)
        assert.are.equal(#preview + 36, result.byteCount)
        assert.are.equal(preview, result.bytes:sub(1, 2) .. result.bytes:sub(39))
        assert.are.equal(jpeg(1600, 1200, 8), result.bytes)
    end)

    it('selects the compression 7 preview from a later top-level directory', function()
        local small = jpeg(1616, 1080)
        local full = jpeg(1600, 1200)
        local first = tiff({
            { 0x0103, 6 }, { 0x0112, 1 },
            { 0x0201, 140 }, { 0x0202, #small },
        }, true, 62)
        local second = tiff({
            { 0x0100, 1600 }, { 0x0101, 1200 }, { 0x0103, 7 },
            { 0x0112, 1 }, { 0x0201, 140 + #small }, { 0x0202, #full },
        }, true):sub(9)
        local result = inspect(first .. second .. small .. full)
        assert.are.equal(full, result.bytes)
    end)

    it('rejects cyclic TIFF directories', function()
        local result, reason = inspect(tiff({}, true, 8))
        assert.is_nil(result)
        assert.are.equal('unsupported_tiff', reason)
    end)

    it('does not scan for unreferenced JPEG data', function()
        local result, reason = inspect(tiff({}, true) .. jpeg(1600, 1200))
        assert.is_nil(result)
        assert.are.equal('preview_unavailable', reason)
    end)

    it('rejects out-of-bounds and oversized preview ranges', function()
        local preview = jpeg(1600, 1200)
        local result, reason = inspect(raw(preview, true, 1, 999999))
        assert.is_nil(result)
        assert.are.equal('preview_unavailable', reason)
        result, reason = inspect(raw(preview, true, 1, 86, 33 * 1024 * 1024))
        assert.is_nil(result)
        assert.are.equal('preview_unavailable', reason)
    end)

    it('rejects truncated JPEGs and small thumbnails', function()
        local result, reason = inspect(raw(jpeg(1600, 1200):sub(1, -2), true))
        assert.is_nil(result)
        assert.are.equal('invalid_or_small_preview', reason)
        result, reason = inspect(raw(jpeg(320, 240), true))
        assert.is_nil(result)
        assert.are.equal('invalid_or_small_preview', reason)
    end)

    it('reads a source ARW without modifying it', function()
        local filename = os.tmpname() .. '.ARW'
        local bytes = raw(jpeg(1600, 1200), true)
        local file = assert(io.open(filename, 'wb'))
        file:write(bytes)
        file:close()
        local result = Preview.extract(filename)
        local original = assert(io.open(filename, 'rb'))
        local reread = original:read('*a')
        original:close()
        os.remove(filename)
        assert.are.equal(bytes, reread)
        assert.are.equal(jpeg(1600, 1200), result.bytes)
    end)

    it('declines unsupported extensions and missing files', function()
        local result, reason = Preview.extract('source.CR3')
        assert.is_nil(result)
        assert.are.equal('unsupported_raw', reason)
        result, reason = Preview.extract('no-such-preview-source.ARW')
        assert.is_nil(result)
        assert.are.equal('source_unavailable', reason)
    end)
end)
