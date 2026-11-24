-- Build confirmation units from finalized results. No catalog writes here.
local Review = {}

local function corePath()
    if _PLUGIN and _PLUGIN.path then return _PLUGIN.path .. '/Core' end
    return debug.getinfo(1, 'S').source:match('^@(.+)/[^/]+$') or '.'
end

local Identification = assert(loadfile(corePath() .. '/IdentificationLogic.lua'))()
local Automatic = assert(loadfile(corePath() .. '/AutomaticModesLogic.lua'))()

local function finite(value)
    return type(value) == 'number' and value == value and math.abs(value) < math.huge
end

local function taxon(prediction)
    if type(prediction) ~= 'table' or type(prediction.canonical_namespace) ~= 'string'
        or prediction.canonical_namespace == '' or not finite(prediction.canonical_taxon_id)
        or prediction.canonical_taxon_id <= 0 or prediction.canonical_taxon_id % 1 ~= 0
        or type(prediction.taxonomy) ~= 'table' or #prediction.taxonomy == 0
        or type(prediction.taxonomy_rank_names) ~= 'table'
        or #prediction.taxonomy_rank_names ~= #prediction.taxonomy
        or not finite(prediction.confidence)
        or prediction.confidence < 0 or prediction.confidence > 1 then
        return nil
    end
    return prediction.canonical_namespace .. ':' .. tostring(prediction.canonical_taxon_id)
end

local function geometry(frame, object)
    local b = object.bounding_box
    return object.geometry_provenance == 'detected' and object.geometry_clipped == false
        and finite(frame.width) and finite(frame.height)
        and frame.width > 0 and frame.height > 0
        and type(frame.coordinate_space) == 'string' and frame.coordinate_space ~= ''
        and type(b) == 'table' and #b == 4
        and finite(b[1]) and finite(b[2]) and finite(b[3]) and finite(b[4])
        and b[1] >= 0 and b[2] >= 0 and b[3] <= frame.width and b[4] <= frame.height
        and b[1] < b[3] and b[2] < b[4]
end

local function safeTop(member)
    local object = member.object
    return member.frame.status == 'identified' and geometry(member.frame, object)
        and object.review_required == false
        and type(object.conflict_evidence_frame_ids) == 'table'
        and #object.conflict_evidence_frame_ids == 0
        and taxon((object.predictions or {})[1]) or nil
end

local function trackUnit(members)
    if #members < 2 then return nil end
    local id, direct, seen, anchors = nil, {}, {}, {}
    local previous
    for _, member in ipairs(members) do
        local object, frameId = member.object, member.frame.frame_id
        local key = safeTop(member)
        if not key or (id and key ~= id) or seen[frameId]
            or (previous and (member.frameIndex ~= previous.frameIndex + 1
                or member.frame.coordinate_space ~= previous.frame.coordinate_space)) then
            return nil
        end
        previous = member
        seen[frameId], id = true, key
        if object.identification_provenance == 'direct' then
            if type(object.evidence_frame_ids) ~= 'table'
                or #object.evidence_frame_ids ~= 1 or object.evidence_frame_ids[1] ~= frameId then
                return nil
            end
            direct[frameId] = member
            anchors[#anchors + 1] = member
        elseif object.identification_provenance == 'propagated' then
            -- The named evidence must be a preceding direct member of this
            -- exact track, not an unrelated detection in the same photograph.
            local evidence = object.evidence_frame_ids
            if type(evidence) ~= 'table' or #evidence ~= 1 or not direct[evidence[1]] then
                return nil
            end
        else
            return nil
        end
    end
    if #anchors == 0 then return nil end
    return { kind = 'track', members = members, evidence = anchors, taxon = id }
end

-- Revalidate the result/frame association independently of the transport.
function Review.units(manifest, results)
    assert(type(results) == 'table' and #results == #manifest.frames, 'Incomplete batch results')
    local members, tracks, frames, seen = {}, {}, {}, {}
    for index, spec in ipairs(manifest.frames) do
        local frame = results[index]
        assert(frame.frame_id == spec.frame_id and not seen[frame.frame_id],
            'Unexpected batch frame')
        seen[frame.frame_id] = true
        assert(type(frame.objects) == 'table', 'Missing batch objects')
        assert(frame.status == 'identified' or frame.status == 'uncertain'
            or frame.status == 'failed' or frame.status == 'no_detection', 'Invalid frame status')
        assert((frame.status == 'failed' or frame.status == 'no_detection')
            == (#frame.objects == 0), 'Inconsistent frame status')
        frames[index] = { frame = frame, dispositions = {} }
        for objectIndex, object in ipairs(frame.objects) do
            local member = {
                frame = frame, frameIndex = index, object = object, objectIndex = objectIndex,
            }
            members[#members + 1] = member
            local track = object.track_id
            if type(track) == 'string' and track ~= '' then
                tracks[track] = tracks[track] or {}
                tracks[track][#tracks[track] + 1] = member
            end
        end
    end
    local units, grouped, invalid = {}, {}, {}
    for _, track in pairs(tracks) do
        local unit = trackUnit(track)
        if unit then
            for _, member in ipairs(track) do grouped[member] = unit end
        elseif #track > 1 or track[1].object.identification_provenance == 'propagated' then
            for _, member in ipairs(track) do invalid[member] = true end
        end
    end
    local emitted = {}
    for _, member in ipairs(members) do
        local unit = grouped[member]
        if unit then
            if not emitted[unit] then
                emitted[unit] = true
                units[#units + 1] = unit
            end
        else
            units[#units + 1] = {
                kind = 'object', members = { member }, evidence = { member },
                automaticBlocked = invalid[member]
                    or member.object.identification_provenance ~= 'direct'
                    or not safeTop(member),
            }
        end
    end
    return units, frames
end

local function automatic(unit, threshold)
    if unit.automaticBlocked then return false end
    for _, member in ipairs(unit.members) do
        if not safeTop(member) or Automatic.automaticDisposition(member.object, threshold)
            .disposition ~= 'confirmed' then return false end
    end
    return true
end

local function selectedDisposition(decision, member, track)
    local object = member.object
    if decision.action == 'ok' then
        local index = track and 1 or decision.selectedPredictionIndex
        local prediction = type(index) == 'number' and (object.predictions or {})[index] or nil
        if prediction and taxon(prediction) and (not track or decision.selectedPredictionIndex == 1) then
            return Identification.disposition({ action = 'ok', selectedPredictionIndex = index }, object)
        end
    elseif not track and decision.action == 'manual' then
        local p = decision.selectedPrediction
        if type(p) == 'table' and type(p.taxonomy) == 'table' and #p.taxonomy > 0
            and type(p.taxonomyRanks) == 'table' and #p.taxonomyRanks == #p.taxonomy then
            return Identification.disposition(decision, object)
        end
    elseif not track and decision.action == 'not_an_animal' then
        return Identification.disposition(decision, object)
    end
    return Identification.disposition({ action = 'unsure' }, object)
end

-- review(unit) must show verified image evidence before returning a decision.
-- Track-wide approval is deliberately limited to the common canonical top taxon.
-- A different taxon, rejection, or exception requires individual review.
function Review.collect(manifest, results, options)
    assert(options.mode == 'manual' or options.mode == 'assisted' or options.mode == 'automatic',
        'Invalid identification mode')
    local units, frames = Review.units(manifest, results)
    local function canceled()
        return options.isCanceled and options.isCanceled()
    end
    local function current(member)
        return not options.isCurrent or options.isCurrent(member.frame.frame_id)
    end
    local function review(unit)
        if canceled() then return { action = 'stop' } end
        for _, member in ipairs(unit.members) do
            if not current(member) then return { action = 'unsure' } end
        end
        if options.mode ~= 'manual' and automatic(unit, options.threshold) then
            return { action = 'ok', selectedPredictionIndex = 1 }
        end
        if options.mode ~= 'automatic' and options.review then
            return options.review(unit) or { action = 'unsure' }
        end
        return { action = 'unsure' }
    end
    local function assign(unit, decision)
        for _, member in ipairs(unit.members) do
            local frame = frames[member.frameIndex]
            frame.dispositions[member.objectIndex] = selectedDisposition(
                decision, member, unit.kind == 'track')
        end
    end
    for _, unit in ipairs(units) do
        local decision = review(unit)
        if decision.action == 'stop' or canceled() then return nil, 'canceled' end
        if unit.kind == 'track' and decision.action == 'individual' then
            for _, member in ipairs(unit.members) do
                local single = { kind = 'object', members = { member }, evidence = { member },
                    automaticBlocked = true }
                local individual = review(single)
                if individual.action == 'stop' or canceled() then return nil, 'canceled' end
                assign(single, individual)
            end
        else
            assign(unit, decision)
        end
    end

    -- The existing writer replaces a photo's prior Crush Catalog keywords.
    -- Do not send a partially resolved frame (or a negative-only frame) to it.
    local changed = {}
    for _, unit in ipairs(units) do
        for _, member in ipairs(unit.members) do
            if not current(member) then
                for _, affected in ipairs(unit.members) do changed[affected.frameIndex] = true end
                break
            end
        end
    end
    local approved, skipped = {}, {}
    for index, entry in ipairs(frames) do
        local complete = #entry.frame.objects > 0 and not changed[index]
        local positive = false
        for _, disposition in ipairs(entry.dispositions) do
            if disposition.selectedPrediction then
                positive = true
            elseif disposition.disposition ~= 'not_an_animal' then
                complete = false
            end
        end
        if complete and positive and #entry.dispositions == #entry.frame.objects then
            approved[#approved + 1] = { frame_id = entry.frame.frame_id,
                dispositions = entry.dispositions }
        else
            skipped[#skipped + 1] = entry.frame.frame_id
        end
    end
    if canceled() then return nil, 'canceled' end
    return { approved = approved, skipped = skipped }
end

return Review
