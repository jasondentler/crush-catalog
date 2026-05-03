local LuaHelpers = require "LuaHelpers"

local payload = LuaHelpers.build_identify_payload("/tmp/photo.cr3", "ABC123", "US-CA")
assert(payload.file_path == "/tmp/photo.cr3")
assert(payload.ebird_token == "ABC123")
assert(payload.location_fallback == "US-CA")

local alternatives = {
    { species = "House Sparrow", confidence = 0.93 },
    { species = "American Robin", confidence = 0.07 },
}
local formatted = LuaHelpers.format_alternative_list(alternatives)
assert(formatted:match("1%. House Sparrow") ~= nil)
assert(formatted:match("2%. American Robin") ~= nil)

print("LuaHelpers tests passed")
