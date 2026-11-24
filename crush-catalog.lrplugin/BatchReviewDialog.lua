-- Review finalized objects only. Evidence must be cropped from the exact
-- analyzed representation; a Lightroom thumbnail is not interchangeable.
local LrBinding = import 'LrBinding'
local LrDialogs = import 'LrDialogs'
local LrFileUtils = import 'LrFileUtils'
local LrFunctionContext = import 'LrFunctionContext'
local LrPathUtils = import 'LrPathUtils'
local LrView = import 'LrView'

local Dialog = {}

local function pluginPath()
    if _PLUGIN and _PLUGIN.path then return _PLUGIN.path end
    return debug.getinfo(1, 'S').source:match('^@(.+)/[^/]+$') or '.'
end

local Names = assert(loadfile(pluginPath() .. '/Core/TaxonomyNames.lua'))()
local Individual = require 'IdentificationDialog'

local function matchingCrop(member, crop)
    if type(crop) ~= 'table' or crop.frame_id ~= member.frame.frame_id
        or crop.object_index ~= member.objectIndex
        or crop.coordinate_space ~= member.frame.coordinate_space
        or type(crop.bounding_box) ~= 'table' or #crop.bounding_box ~= 4
        or type(member.object.bounding_box) ~= 'table'
        or #member.object.bounding_box ~= 4
        or type(crop.bytes) ~= 'string' or #crop.bytes < 4 or #crop.bytes > 4 * 1024 * 1024
        or crop.bytes:sub(1, 2) ~= string.char(255, 216)
        or crop.bytes:sub(-2) ~= string.char(255, 217) then
        return false
    end
    for index = 1, 4 do
        if crop.bounding_box[index] ~= member.object.bounding_box[index] then return false end
    end
    return true
end

local function label(member, options)
    local item = options.items[member.frame.frame_id].item
    return item.photo:getFormattedMetadata('fileName') or member.frame.frame_id
end

local function writeCrop(context, crop)
    local path = LrFileUtils.chooseUniqueFileName(LrPathUtils.child(
        LrPathUtils.getStandardFilePath('temp'), 'crush-track-evidence.jpg'))
    context:addCleanupHandler(function() LrFileUtils.delete(path) end)
    local file = assert(io.open(path, 'wb'))
    local written = file:write(crop.bytes)
    local closed = file:close()
    if not written or not closed then error('Unable to write review evidence', 0) end
    return path
end

local function showTrack(unit, crops, options)
    return LrFunctionContext.callWithContext('batchTrackReview', function(context)
        local factory = LrView.osFactory()
        local props = LrBinding.makePropertyTable(context)
        local choices, paths = {}, {}
        for index, member in ipairs(unit.evidence) do
            paths[index] = writeCrop(context, crops[index])
            choices[index] = { title = label(member, options), value = index }
        end
        props.selectedEvidence = 1
        props.imagePath = paths[1]
        props:addObserver('selectedEvidence', function()
            props.imagePath = paths[props.selectedEvidence]
        end)
        local first = unit.members[1].object.predictions[1]
        local lines = {}
        for _, member in ipairs(unit.members) do
            lines[#lines + 1] = label(member, options) .. ' — '
                .. member.object.identification_provenance
        end
        local action = LrDialogs.presentModalDialog {
            title = string.format('Confirm tracked subject in %d photographs', #unit.members),
            contents = factory:column {
                bind_to_object = props,
                spacing = factory:control_spacing(),
                factory:static_text {
                    title = Names.commonName(first) .. ' (' .. Names.scientificName(first) .. ')',
                },
                factory:popup_menu {
                    items = choices, value = LrView.bind('selectedEvidence'), width = 520,
                },
                factory:picture {
                    value = LrView.bind('imagePath'), width = 640, height = 480, frame_width = 1,
                },
                factory:static_text {
                    title = table.concat(lines, '\n'), width = 640, height_in_lines = #lines,
                },
            },
            accessoryView = factory:row {
                factory:push_button {
                    title = 'Stop',
                    action = function(button) LrDialogs.stopModalWithResult(button, 'other') end,
                },
                factory:spacer { fill_horizontal = 1 },
                factory:push_button {
                    title = 'Review individually',
                    action = function(button)
                        LrDialogs.stopModalWithResult(button, 'individual')
                    end,
                },
            },
            actionVerb = 'Confirm track',
            cancelVerb = 'Skip track',
            resizable = false,
        }
        if action == 'ok' then return { action = 'ok', selectedPredictionIndex = 1 } end
        if action == 'other' then return { action = 'stop' } end
        if action == 'individual' then return { action = 'individual' } end
        return { action = 'unsure' }
    end)
end

function Dialog.review(unit, options)
    local crops = {}
    for index, member in ipairs(unit.evidence) do
        local crop = options.getCrop and options.getCrop(member)
        if not matchingCrop(member, crop) then
            -- Never confirm a subject from a thumbnail, mismatched box or
            -- missing image. A track can instead be reviewed individually.
            return { action = unit.kind == 'track' and 'individual' or 'unsure' }
        end
        crops[index] = crop
    end
    if unit.kind == 'track' then return showTrack(unit, crops, options) end
    local member = unit.members[1]
    local entry = options.items[member.frame.frame_id].item
    local object = member.object
    local summary = 'Identification: ' .. tostring(object.identification_provenance)
        .. '\nReview required: ' .. tostring(object.review_required)
    if type(object.reason) == 'string' then summary = summary .. '\n' .. object.reason end
    if #(object.conflict_evidence_frame_ids or {}) > 0 then
        summary = summary .. '\nConflicting direct evidence; review independently.'
    end
    return Individual.showBatchObject(entry.photo, member,
        { bytes = crops[1].bytes, filename = 'crush-batch-evidence.jpg' }, {
            imageCount = options.imageCount,
            commonNameLanguage = options.language,
            gpsCoordinates = entry.gps,
            searchFunction = options.searchFunction,
            batchReviewSummary = summary,
        })
end

Dialog.matchingCrop = matchingCrop

return Dialog
