local SidecarLogic = {}

SidecarLogic.SCHEMA_VERSION = 1
SidecarLogic.SUFFIX = '.crush-catalog.json'

local NAME_FIELDS = {
    commonNames = true,
    scientificNames = true,
}

local NUMBER_FIELDS = {
    detectionCount = true,
    topSuggestionCount = true,
    otherSuggestionCount = true,
    unsureCount = true,
    detectionFalsePositivesCount = true,
    topSuggestionConfidence = true,
}

local function splitNames(value)
    local names = {}

    for name in tostring(value or ''):gmatch('[^,]+') do
        name = name:match('^%s*(.-)%s*$')

        if name ~= '' then
            names[#names + 1] = name
        end
    end

    return names
end

local function validateStringArray(field, value)
    if type(value) ~= 'table' then
        error('metadata.' .. field .. ' must be an array')
    end

    local result = {}

    for index, item in ipairs(value) do
        if type(item) ~= 'string' or item == '' then
            error('metadata.' .. field .. '[' .. tostring(index)
                .. '] must be a non-empty string')
        end

        result[#result + 1] = item
    end

    return table.concat(result, ', ')
end

function SidecarLogic.pathForPhoto(photoPath)
    if type(photoPath) ~= 'string' or photoPath == '' then
        error('Photo does not have a local file path')
    end

    return photoPath .. SidecarLogic.SUFFIX
end


function SidecarLogic.create(sourceFile, values)
    if type(sourceFile) ~= 'string' or sourceFile == '' then
        error('Source filename is required')
    end

    local metadata = {}

    for field in pairs(NAME_FIELDS) do
        metadata[field] = splitNames(values[field])
    end

    for field in pairs(NUMBER_FIELDS) do
        local value = values[field]

        if value ~= nil and value ~= '' then
            value = tonumber(value)

            if value == nil then
                error(field .. ' is not numeric')
            end

            metadata[field] = value
        end
    end

    return {
        schemaVersion = SidecarLogic.SCHEMA_VERSION,
        sourceFile = sourceFile,
        metadata = metadata,
    }
end


function SidecarLogic.metadataValues(sidecar, expectedSourceFile)
    if type(sidecar) ~= 'table' then
        error('Crush Catalog data file must contain an object')
    end

    if sidecar.schemaVersion ~= SidecarLogic.SCHEMA_VERSION then
        error('Unsupported Crush Catalog data version: '
            .. tostring(sidecar.schemaVersion))
    end

    if sidecar.sourceFile ~= expectedSourceFile then
        error('Crush Catalog data file does not match ' .. expectedSourceFile)
    end

    if type(sidecar.metadata) ~= 'table' then
        error('Crush Catalog metadata must be an object')
    end

    local values = {}

    for field in pairs(NAME_FIELDS) do
        values[field] = validateStringArray(field, sidecar.metadata[field])
    end

    for field in pairs(NUMBER_FIELDS) do
        local value = sidecar.metadata[field]

        if value ~= nil then
            if type(value) ~= 'number' or value ~= value
                or value == math.huge or value == -math.huge
            then
                error('metadata.' .. field .. ' must be a finite number')
            end

            values[field] = tostring(value)
        end
    end

    return values
end

return SidecarLogic
