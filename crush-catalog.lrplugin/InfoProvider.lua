local LrView = import("LrView")
local LrPrefs = import("LrPrefs")

local prefs = LrPrefs.prefsForPlugin()
local DEFAULT_BACKEND_URL = "http://localhost:8000/identify"

local function trim(s)
	if s == nil then
		return ""
	end
	return (tostring(s):match("^%s*(.-)%s*$") or "")
end

local function savePreferences(propertyTable)
	prefs.backendUrl = trim(propertyTable.backendUrl)
end

return {
	sectionsForTopOfDialog = function(f, propertyTable)
		propertyTable.testStatus = "<unknown>"
		return {
			{
				title = LOC("$$$/CrushCatalog/InfoProvider/SettingsTitle=Crush Catalog Settings"),

				f:static_text({
					title = LOC(
						"$$$/CrushCatalog/InfoProvider/BackendUrl/Instructions="
							.. "Enter the backend URL for animal identification. Always use HTTPS for remote backends "
							.. "to protect your privacy."
					),
					width = 520,
					height = 42,
				}),

				f:row({
					spacing = f:control_spacing(),
					bind_to_object = propertyTable,
					f:static_text({
						title = LOC("$$$/CrushCatalog/InfoProvider/BackendUrl/Label=Backend URL:"),
					}),
					f:edit_field({
						value = LrView.bind("backendUrl"),
						width_in_chars = 50,
						immediate = true,
						tooltip = LOC(
							"$$$/CrushCatalog/InfoProvider/BackendUrl/Tooltip="
								.. "Enter the HTTP or HTTPS endpoint for the Wild Catalog identification backend."
						),
					}),
				}),
			},
		}
	end,

	startDialog = function(propertyTable)
		propertyTable.backendUrl = tostring(prefs.backendUrl or DEFAULT_BACKEND_URL)

		propertyTable:addObserver("backendUrl", function()
			savePreferences(propertyTable)
		end)
	end,

	endDialog = function(propertyTable)
		savePreferences(propertyTable)
	end,
}
