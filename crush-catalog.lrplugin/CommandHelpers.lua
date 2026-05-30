local LrTasks = import 'LrTasks'
local LrFileUtils = import 'LrFileUtils'
local LrPathUtils = import 'LrPathUtils'
local LrUUID = import 'LrUUID'

local CommandHelpers = {}

function CommandHelpers.executeWithCapture(command)
    -- 1. Create a unique temp file path
    local tempFile = LrPathUtils.child(LrPathUtils.getStandardFilePath('temp'), LrUUID.generateUUID() .. ".txt")

    -- 2. Redirect stdout and stderr to the temp file
    local fullCommand = command .. ' > "' .. tempFile .. '" 2>&1'

    -- 3. Execute the task
    local exitCode = LrTasks.execute(fullCommand)

    -- 4. Read the captured output
    local output = ""
    if LrFileUtils.exists(tempFile) then
        output = LrFileUtils.readFile(tempFile)
        -- 5. Clean up the temp file
        LrFileUtils.delete(tempFile)
    end

    return exitCode, output
end


return CommandHelpers