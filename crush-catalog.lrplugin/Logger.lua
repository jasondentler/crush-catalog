local LrLogger = import 'LrLogger'
local myLogger = LrLogger( "com.jasondentler.crushcatalog" )
myLogger:enable( "logfile" )

local Logger = {}

local function getFullMessage(message, url)
    -- If url is nil or false, use "N/A"
    local urlString = url or "N/A"
    local fullMessage = string.format("%s\t%s", urlString, tostring(message))
    return fullMessage
end

function Logger.error(message, url)
    myLogger:error(getFullMessage(message, url))
end

function Logger.info(message, url)
    myLogger:info(getFullMessage(message, url))
end

function Logger.debug(message, url)
    myLogger:debug(getFullMessage(message, url))
end

return Logger
