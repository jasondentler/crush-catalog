local AutomaticModesLogic = {}

local function pluginPath()
    if _PLUGIN ~= nil and _PLUGIN.path ~= nil then
        return _PLUGIN.path .. '/Core'
    end

    local source = debug.getinfo(1, 'S').source
    return source:match('^@(.+)/[^/]+$') or '.'
end

local IdentificationLogic = assert(
    loadfile(pluginPath() .. '/IdentificationLogic.lua')
)()

function AutomaticModesLogic.threshold(value)
    local number = tonumber(value)

    if number == nil or number < 0 or number > 100 or number % 1 ~= 0 then
        return nil
    end

    return number
end

function AutomaticModesLogic.validOptions(options)
    if options == nil
        or (options.mode ~= 'automatic'
            and options.mode ~= 'assisted'
            and options.mode ~= 'manual')
        or (options.processingScope ~= 'new'
            and options.processingScope ~= 'new_and_unsure'
            and options.processingScope ~= 'all')
    then
        return false
    end

    return options.mode == 'manual'
        or AutomaticModesLogic.threshold(options.threshold) ~= nil
end

function AutomaticModesLogic.automaticDisposition(result, threshold)
    local prediction = (result.predictions or {})[1]
    local confidence = prediction ~= nil and tonumber(prediction.confidence) or nil
    local minimum = AutomaticModesLogic.threshold(threshold)

    if minimum ~= nil and confidence ~= nil and confidence * 100 >= minimum then
        return IdentificationLogic.disposition({
            action = 'ok',
            selectedPredictionIndex = 1,
        }, result)
    end

    return IdentificationLogic.disposition({ action = 'unsure' }, result)
end

function AutomaticModesLogic.shouldShowManual(result, options)
    if options.mode == 'manual' then
        return true
    end

    if options.mode == 'automatic' then
        return false
    end

    return AutomaticModesLogic.automaticDisposition(result, options.threshold)
        .disposition == 'unsure'
end

function AutomaticModesLogic.shouldProcess(detectionCount, unsureCount, processingScope)
    if processingScope == 'all' then
        return true
    end

    local isNew = detectionCount == nil or detectionCount == ''

    if processingScope == 'new_and_unsure' then
        return isNew or (tonumber(unsureCount) or 0) > 0
    end

    return processingScope == 'new' and isNew
end

return AutomaticModesLogic
