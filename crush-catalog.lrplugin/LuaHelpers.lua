local LuaHelpers = {}

function LuaHelpers.build_identify_payload(photo_path, ebird_token, location_fallback)
    -- Return the components separately for multipart form-data construction
    -- The caller will need to construct the multipart request
    return {
        photo_path = photo_path,
        ebird_token = ebird_token,
        location_fallback = location_fallback,
    }
end

function LuaHelpers.format_alternative_list(alternatives)
    local lines = {}
    for index, alt in ipairs(alternatives) do
        local confidence = (alt.confidence or 0) * 100
        table.insert(lines, string.format("%d. %s (%.1f%%)", index, alt.species or "Unknown", confidence))
    end
    return table.concat(lines, "\n")
end

return LuaHelpers
