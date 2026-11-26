-- Transport-independent client. No Lightroom writes or source paths in the manifest.
local Batch = {}

local function identifier(value)
    return type(value) == 'string' and #value <= 128
        and value:match('^[a-zA-Z0-9][a-zA-Z0-9_.%-]*$') ~= nil
end

local function requireCondition(condition, message)
    if not condition then
        error(message, 0)
    end
end

local function indexManifest(manifest)
    requireCondition(type(manifest.frames) == 'table'
        and #manifest.frames > 0 and #manifest.frames <= 256, 'Invalid batch size')
    local frames = {}
    for _, frame in ipairs(manifest.frames) do
        requireCondition(identifier(frame.frame_id) and not frames[frame.frame_id],
            'Invalid or duplicate frame identifier')
        local assets = {}
        for _, spec in ipairs(frame.representations or {}) do
            requireCondition(identifier(spec.representation_id)
                and not assets[spec.representation_id], 'Invalid representation identifier')
            requireCondition(spec.role == 'preview' or spec.role == 'full', 'Invalid asset role')
            assets[spec.representation_id] = spec.role
        end
        frames[frame.frame_id] = assets
    end
    return frames
end

local function headers(token, contentType)
    local values = {
        { field = 'Accept', value = 'application/json' },
        { field = 'Content-Type', value = contentType or 'application/json' },
    }
    if token then
        values[#values + 1] = { field = 'X-Batch-Token', value = token }
    end
    return values
end

local function decode(response, expected, json)
    requireCondition(type(response) == 'table' and response.status == expected,
        'Batch HTTP request failed (status ' .. tostring(
            type(response) == 'table' and tonumber(response.status) or 'unknown') .. ')')
    local ok, payload = pcall(json.decode, json, response.body)
    requireCondition(ok and type(payload) == 'table', 'Invalid batch JSON response')
    return payload
end

local function validateProgress(progress, batchId)
    requireCondition(progress.batch_id == batchId
        and (progress.status == 'need_input' or progress.status == 'completed')
        and type(progress.requested) == 'table' and type(progress.results) == 'table'
        and type(progress.provisional_frame_ids) == 'table', 'Invalid batch progress')
end

local function finalResults(progress, manifest, frames)
    requireCondition(#progress.requested == 0 and #progress.provisional_frame_ids == 0,
        'Batch completed with unresolved input or provisional results')
    local indexed = {}
    for _, result in ipairs(progress.results) do
        local id = result.frame_id
        requireCondition(frames[id] and not indexed[id], 'Unexpected or duplicate frame result')
        requireCondition(result.status == 'identified' or result.status == 'uncertain'
            or result.status == 'no_detection' or result.status == 'failed',
            'Invalid frame result status')
        requireCondition(type(result.objects) == 'table', 'Missing frame objects')
        requireCondition((result.status == 'failed' or result.status == 'no_detection')
            == (#result.objects == 0), 'Inconsistent frame result')
        indexed[id] = result
    end
    local ordered = {}
    for _, frame in ipairs(manifest.frames) do
        requireCondition(indexed[frame.frame_id], 'Missing finalized frame result')
        ordered[#ordered + 1] = indexed[frame.frame_id]
    end
    return ordered
end

-- transport.request(method, url, body, headers), transport.upload(url, path, headers)
-- resolveAsset(frameId, representationId, role) returns an authorized local path or nil.
-- protect must permit Lightroom task yields (LrTasks.pcall in the adapter).
function Batch.run(manifest, options)
    local frames = indexManifest(manifest)
    local transport, json = options.transport, options.json
    local protect = options.protect or pcall
    local base = options.baseUrl:gsub('/+$', ''):gsub('/identify$', '') .. '/v1/batches'
    local batchUrl, token
    local stage, status = 'create', nil
    local requestedFilename, sizeLimit
    local function observed(response, expected)
        status = type(response) == 'table' and tonumber(response.status) or nil
        if status == 413 then
            local ok, body = pcall(json.decode, json, response.body)
            if ok and type(body) == 'table' and type(body.error) == 'table'
                and body.error.code == 'payload_too_large'
                and type(body.error.message) == 'string' then
                local limit = body.error.message:match('configured size limit of ([%d,]+) bytes')
                if limit then sizeLimit = tonumber((limit:gsub(',', ''))) end
            end
        end
        return decode(response, expected, json)
    end

    local function checkCanceled()
        if options.isCanceled and options.isCanceled() then
            error('Batch canceled', 0)
        end
    end

    -- Evidence URLs cannot be supplied by the server or UI.
    local function fetchCrop(member, final)
        if not manifest.include_review_images or not transport.get then return nil end
        checkCanceled()
        local frame = final.results[member.frameIndex]
        local index = member.objectIndex
        if frame ~= member.frame or type(index) ~= 'number' or index < 1
            or index % 1 ~= 0 or frame.objects[index] ~= member.object then
            return nil
        end
        local url = batchUrl .. '/frames/' .. frame.frame_id .. '/objects/'
            .. tostring(index) .. '/review-image'
        local fetched, response = protect(transport.get, url, {
            { field = 'Accept', value = 'image/jpeg' },
            { field = 'X-Batch-Token', value = token },
        })
        checkCanceled()
        if not fetched or type(response) ~= 'table' or response.status ~= 200
            or type(response.body) ~= 'string' or #response.body > 512 * 1024 then
            return nil
        end
        local h = response.normalizedHeaders or {}
        if h['content-type'] ~= 'image/jpeg' or h['x-frame-id'] ~= frame.frame_id
            or tonumber(h['x-object-index']) ~= index
            or h['x-coordinate-space'] ~= frame.coordinate_space
            or type(h['x-bounding-box']) ~= 'string' then return nil end
        local decoded, box = pcall(json.decode, json, h['x-bounding-box'])
        if not decoded or type(box) ~= 'table' or #box ~= 4
            or type(member.object.bounding_box) ~= 'table' then return nil end
        for i = 1, 4 do
            if box[i] ~= member.object.bounding_box[i] then return nil end
        end
        return {
            frame_id = frame.frame_id, object_index = index,
            coordinate_space = frame.coordinate_space, bounding_box = box,
            bytes = response.body,
        }
    end

    local function releaseSession()
        if not batchUrl or not token then return true end
        local ok, response = protect(transport.request, 'DELETE', batchUrl, '', headers(token))
        if ok and type(response) == 'table' then
            if response.status == 204 then
                batchUrl, token = nil, nil
                return true
            end
            if response.status == 404 then
                local decoded, payload = pcall(json.decode, json, response.body)
                if decoded and type(payload) == 'table' and type(payload.error) == 'table'
                    and payload.error.code == 'batch_not_found' then
                    batchUrl, token = nil, nil
                    return true
                end
            end
        end
        return false
    end

    -- Materialize bounded review evidence before opening any modal dialog.
    -- A long review or server restart must not invalidate locally fetched crops.
    local function cacheReview(final)
        local crops, bytes, attempts, missing = {}, 0, 0, 0
        if manifest.include_review_images then
            for frameIndex, frame in ipairs(final.results) do
                for objectIndex, object in ipairs(frame.objects) do
                    local crop
                    if attempts < 2048 and bytes < 64 * 1024 * 1024 then
                        attempts = attempts + 1
                        crop = fetchCrop({
                            frameIndex = frameIndex, frame = frame,
                            objectIndex = objectIndex, object = object,
                        }, final)
                    end
                    if crop and bytes + #crop.bytes <= 64 * 1024 * 1024 then
                        crops[frameIndex .. ':' .. objectIndex] = crop
                        bytes = bytes + #crop.bytes
                    else
                        missing = missing + 1
                    end
                end
            end
        end
        final.missingReviewImages = missing
        return function(member)
            checkCanceled()
            local frame = final.results[member.frameIndex]
            local index = member.objectIndex
            if frame and frame == member.frame and type(index) == 'number'
                and frame.objects[index] == member.object then
                return crops[member.frameIndex .. ':' .. index]
            end
        end
    end

    local ok, result = protect(function()
        checkCanceled()
        local progress = observed(transport.request('POST', base, json:encode(manifest),
            headers()), 201)
        stage = 'validate create response'
        requireCondition(identifier(progress.batch_id)
            and type(progress.batch_token) == 'string' and #progress.batch_token <= 128
            and progress.batch_token:match('^[a-zA-Z0-9_%-]+$') ~= nil,
            'Invalid batch credentials')
        batchUrl, token = base .. '/' .. progress.batch_id, progress.batch_token
        local batchId = progress.batch_id
        local resolved = {}
        -- Each asset can be resolved once; an advance can open a new window
        -- or discover a full-quality fallback. Bound malformed-server loops.
        for _ = 1, #manifest.frames * 5 + 2 do
            checkCanceled()
            stage = 'validate progress'
            validateProgress(progress, batchId)
            if progress.status == 'completed' then
                stage = 'finalize results'
                local final = {
                    batchId = batchId,
                    results = finalResults(progress, manifest, frames),
                    operationCounts = progress.operation_counts,
                }
                if options.onCompleted then
                    stage = 'download review evidence'
                    local getCrop = cacheReview(final)
                    releaseSession()
                    stage = 'confirmation'
                    final.confirmations = options.onCompleted(final, getCrop)
                    checkCanceled()
                end
                return final
            end
            if options.onProgress then
                local done = progress.finalized_frame_count
                if done == nil then done = #progress.results - #progress.provisional_frame_ids end
                requireCondition(type(done) == 'number' and done >= 0
                    and done <= #manifest.frames and done % 1 == 0, 'Invalid progress count')
                options.onProgress(done, #manifest.frames)
            end
            if #progress.requested == 0 then
                stage, status = 'advance', nil
                progress = observed(transport.request('POST', batchUrl .. '/advance',
                    '', headers(token)), 200)
            else
                local request = progress.requested[1]
                local id, rep = request.frame_id, request.representation_id
                requireCondition(frames[id] and frames[id][rep] == request.role
                    and (request.role == 'preview' or request.role == 'full'),
                    'Server requested an undeclared asset')
                local key = id .. ':' .. rep
                requireCondition(not resolved[key], 'Server repeated a resolved request')
                resolved[key] = true
                local url = batchUrl .. '/frames/' .. id .. '/representations/' .. rep
                stage, status = 'resolve ' .. request.role, nil
                local path = options.resolveAsset(id, rep, request.role)
                checkCanceled()
                if path then
                    stage = 'upload ' .. request.role
                    requestedFilename = nil
                    for _, frame in ipairs(manifest.frames) do
                        if frame.frame_id == id then
                            for _, spec in ipairs(frame.representations) do
                                if spec.representation_id == rep then requestedFilename = spec.filename end
                            end
                        end
                    end
                    progress = observed(transport.upload(url, path,
                        headers(token, 'application/octet-stream')), 200)
                else
                    stage = 'declare unavailable ' .. request.role
                    progress = observed(transport.request('POST', url .. '/unavailable',
                        '', headers(token)), 200)
                end
            end
        end
        error('Batch exceeded progress limit', 0)
    end)

    -- Always attempt to release server assets, even after cancellation/error.
    local cleaned = releaseSession()
    if not ok then
        -- Do not expose backend response bodies, credentials, or paths in errors.
        if result == 'Batch canceled' then
            error(result, 0)
        end
        if status == 413 then
            local names = {}
            if stage == 'create' and sizeLimit then
                for _, frame in ipairs(manifest.frames) do
                    for _, spec in ipairs(frame.representations) do
                        if type(spec.byte_count) == 'number' and spec.byte_count > sizeLimit
                            and (manifest.execution_mode == 'burst' or spec.role == 'full') then
                            names[#names + 1] = spec.filename or frame.frame_id
                        end
                    end
                end
            elseif stage:match('^upload ') and requestedFilename then
                names[1] = requestedFilename
            end
            local message = 'Image or upload exceeds server size limit (HTTP 413)'
            if #names > 0 then message = 'Image too large for identification (HTTP 413): '
                .. table.concat(names, ', ') end
            error(message .. '; no results returned', 0)
        end
        if status == 507 then
            error('Insufficient disk space; saved analysis can be resumed.', 0)
        end
        if options.diagnostics then
            error('Batch identification failed at ' .. stage .. ' (HTTP '
                .. tostring(status or 'no response') .. '); no results returned', 0)
        end
        error('Batch identification failed; no results returned', 0)
    end
    result.cleanupPending = not cleaned
    return result
end

return Batch
