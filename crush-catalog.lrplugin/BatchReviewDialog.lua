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
            choices[index] = { title = label(member, options) .. ' — Detection '
                .. member.objectIndex .. ' — ' .. member.object.identification_provenance,
                value = index }
        end
        props.selectedEvidence = 1
        props.imagePath = paths[1]
        props:addObserver('selectedEvidence', function()
            props.imagePath = paths[props.selectedEvidence]
        end)
        local first = (unit.members[1].object.predictions or {})[1]
        local title = unit.taxon and first
            and (Names.commonName(first) .. ' (' .. Names.scientificName(first) .. ')')
            or 'Tracked subject — species requires manual identification'
        local lines = {}
        for _, member in ipairs(unit.members) do
            lines[#lines + 1] = label(member, options) .. ' — '
                .. member.object.identification_provenance
        end
        local frameCount = unit.frameCount or #unit.members
        local dialogTitle = unit.candidateRegions
            and string.format('Review %d detections in %d photographs', #unit.members, frameCount)
            or string.format('Confirm tracked subject in %d photographs', frameCount)
        local details = #lines <= 8 and table.concat(lines, '\n')
            or lines[1] .. '\n…\n' .. lines[#lines]
        local action = LrDialogs.presentModalDialog {
            title = dialogTitle,
            contents = factory:column {
                bind_to_object = props,
                spacing = factory:control_spacing(),
                factory:static_text {
                    title = title,
                },
                factory:popup_menu {
                    items = choices, value = LrView.bind('selectedEvidence'), width = 520,
                },
                factory:picture {
                    value = LrView.bind('imagePath'), width = 640, height = 480, frame_width = 1,
                },
                factory:static_text {
                    title = unit.candidateRegions
                        and 'Inspect related regions before applying a decision to every detection.'
                        or 'Inspect track members before confirming.',
                    width = 640, height_in_lines = 2,
                },
                factory:static_text {
                    title = details, width = 640, height_in_lines = #lines <= 8 and #lines or 3,
                },
            },
            accessoryView = factory:row {
                factory:push_button {
                    title = 'Stop',
                    action = function(button) LrDialogs.stopModalWithResult(button, 'other') end,
                },
                factory:spacer { fill_horizontal = 1 },
                factory:push_button {
                    title = 'Not an animal',
                    action = function(button)
                        LrDialogs.stopModalWithResult(button, 'reject')
                    end,
                },
                factory:push_button {
                    title = 'Choose species',
                    action = function(button)
                        LrDialogs.stopModalWithResult(button, 'choose')
                    end,
                },
                factory:push_button {
                    title = 'Review individually',
                    action = function(button)
                        LrDialogs.stopModalWithResult(button, 'individual')
                    end,
                },
            },
            actionVerb = unit.taxon and 'Confirm track' or 'Identify track',
            cancelVerb = 'Skip track',
            resizable = false,
        }
        if action == 'choose' or (action == 'ok' and not unit.taxon) then
            return { action = 'choose', evidenceIndex = props.selectedEvidence }
        end
        if action == 'ok' then return { action = 'ok', selectedPredictionIndex = 1 } end
        if action == 'other' then return { action = 'stop' } end
        if action == 'individual' then return { action = 'individual' } end
        if action == 'reject' then return { action = 'not_an_animal' } end
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
    local member, crop = unit.members[1], crops[1]
    local selectingTrack = unit.kind == 'track'
    if selectingTrack then
        if options.onDialog then options.onDialog() end
        local action = showTrack(unit, crops, options)
        if action.action ~= 'choose' then return action end
        member = unit.evidence[action.evidenceIndex]
        crop = crops[action.evidenceIndex]
    end
    local entry = options.items[member.frame.frame_id].item
    local object = member.object
    local summary = 'Identification: ' .. tostring(object.identification_provenance)
        .. '\nReview required: ' .. tostring(object.review_required)
    if type(object.reason) == 'string' then summary = summary .. '\n' .. object.reason end
    if #(object.conflict_evidence_frame_ids or {}) > 0 then
        summary = summary .. '\nConflicting direct evidence: species predictions disagree.'
    end
    if selectingTrack then
        summary = string.format('Your choice applies to all %d detections in this group.\n',
            #unit.members) .. summary
    end
    if options.onDialog then options.onDialog() end
    local decision = Individual.showBatchObject(entry.photo, member,
        { bytes = crop.bytes, filename = 'crush-batch-evidence.jpg' }, {
            imageCount = options.imageCount,
            commonNameLanguage = options.language,
            gpsCoordinates = entry.gps,
            searchFunction = options.searchFunction,
            batchReviewSummary = summary,
        })
    if not selectingTrack then return decision end
    if decision.action == 'ok' then
        local prediction = (object.predictions or {})[decision.selectedPredictionIndex]
        if prediction and type(prediction.canonical_taxon_id) == 'number' then
            decision = { action = 'manual', selectedPrediction = {
                taxonomy = prediction.taxonomy,
                taxonomyRanks = prediction.taxonomy_rank_names,
                commonNameTaxonomy = prediction.common_names,
            } }
        else
            return { action = 'individual' }
        end
    end
    if decision.action == 'manual' or decision.action == 'stop'
        or decision.action == 'not_an_animal' then return decision end
    return { action = 'unsure' }
end

Dialog.matchingCrop = matchingCrop

return Dialog
