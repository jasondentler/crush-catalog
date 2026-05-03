local LrView = import("LrView")
local LrPrefs = import("LrPrefs")
local LrTasks = import("LrTasks")
local LrDialogs = import("LrDialogs")

local EBirdService = require("EBirdService")

local prefs = LrPrefs.prefsForPlugin()

local function trim(s)
	if s == nil then
		return ""
	end
	return (tostring(s):match("^%s*(.-)%s*$") or "")
end

return {
	sectionsForTopOfDialog = function(f, propertyTable)
		propertyTable.testStatus = "<unknown>"
		return {
			{
				title = LOC("$$$/CrushCatalog/InfoProvider/SettingsTitle=Crush Catalog Settings"),

				f:column({
					bind_to_object = propertyTable,
					spacing = f:control_spacing(),

					f:static_text({
						title = LOC(
							"$$$/CrushCatalog/InfoProvider/eBirdKey/Instructions=Enter your eBird API key. It is stored in Lightroom plug-in preferences on this computer."
						),
						width_in_chars = 72,
					}),

					f:row({
						spacing = f:control_spacing(),
						f:static_text({
							title = LOC("$$$/CrushCatalog/InfoProvider/eBirdKey/Label=API key:"),
						}),
						f:edit_field({
							value = LrView.bind("ebirdApiKey"),
							width_in_chars = 50,
							immediate = true,
							tooltip = LOC(
								"$$$/CrushCatalog/InfoProvider/eBirdKey/Placeholder=Paste your eBird API key here."
							),
						}),
					}),

					f:row({
						f:push_button({
							title = LOC("$$$/CrushCatalog/InfoProvider/eBirdTestButton/Title=Check Key"),
							action = function(button)
								local ebirdApiKey = propertyTable.ebirdApiKey
								local statusInitializing =
									LOC("$$$/CrushCatalog/InfoProvider/eBirdTestStatus/Initializing=Initializing...")
								local statusConnecting =
									LOC("$$$/CrushCatalog/InfoProvider/eBirdTestStatus/Connecting=Connecting...")
								local statusSuccess =
									LOC("$$$/CrushCatalog/InfoProvider/eBirdTestStatus/Success=Success!")

								propertyTable.testStatus = statusInitializing
								LrTasks.startAsyncTask(function()
									propertyTable.testStatus = statusConnecting
									local success, message, json, info = EBirdService.testConnection(ebirdApiKey)

									if success then
										propertyTable.testStatus = statusSuccess
										if json then
											LrDialogs.showError("result", json)
										end
									elseif info and info.status == 403 then
										local errorTestStatus = LOC(
											"$$$/CrushCatalog/InfoProvider/eBirdTestStatus/Forbidden=API key test failed"
										)
										propertyTable.testStatus = errorTestStatus

										local dialogTitle = LOC(
											"$$$/CrushCatalog/InfoProvider/eBirdTestErrorDialog/Title=eBird rejected your API key"
										)
										local dialogText = LOC(
											"$$$/CrushCatalog/InfoProvider/eBirdTestErrorDialog/Text=We received a 403 Forbidden response from eBird."
										)
										LrDialogs.message(dialogTitle, dialogText)
									else
										local errorTestStatus = LOC(
											"$$$/CrushCatalog/InfoProvider/eBirdTestStatus/Error=Error: ^1",
											message
										)
										propertyTable.testStatus = errorTestStatus
									end
								end)
							end,
						}),
						f:static_text({
							title = LrView.bind("testStatus"),
							width = 300,
						}),
					}),
				}),

				f:static_text({
					title = LOC(
						"$$$/CrushCatalog/InfoProvider/BackendUrl/Instructions=Enter the backend URL for bird identification. Use HTTPS for remote backends because the eBird token is sensitive."
					),
					width_in_chars = 72,
				}),

				f:row({
					spacing = f:control_spacing(),
					f:static_text({
						title = LOC("$$$/CrushCatalog/InfoProvider/BackendUrl/Label=Backend URL:"),
					}),
					f:edit_field({
						value = LrView.bind("backendUrl"),
						width_in_chars = 50,
						immediate = true,
						tooltip = LOC(
							"$$$/CrushCatalog/InfoProvider/BackendUrl/Tooltip=Enter the HTTP or HTTPS endpoint for the bird identification backend."
						),
					}),
				}),
			},
		}
	end,

	startDialog = function(propertyTable)
		propertyTable.ebirdApiKey = tostring(prefs.ebirdApiKey or "")
		propertyTable.backendUrl = tostring(prefs.backendUrl or "http://127.0.0.1:8000/identify")
	end,

	endDialog = function(propertyTable)
		prefs.ebirdApiKey = trim(propertyTable.ebirdApiKey)
		prefs.backendUrl = trim(propertyTable.backendUrl)
	end,
}
