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

    local function checkCanceled()
        if options.isCanceled and options.isCanceled() then
            error('Batch canceled', 0)
        end
    end

    local ok, result = protect(function()
        checkCanceled()
        local progress = decode(transport.request('POST', base, json:encode(manifest),
            headers()), 201, json)
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
            validateProgress(progress, batchId)
            if progress.status == 'completed' then
                return {
                    results = finalResults(progress, manifest, frames),
                    operationCounts = progress.operation_counts,
                }
            end
            if options.onProgress then
                options.onProgress(#progress.results - #progress.provisional_frame_ids, #manifest.frames)
            end
            if #progress.requested == 0 then
                progress = decode(transport.request('POST', batchUrl .. '/advance',
                    '', headers(token)), 200, json)
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
                local path = options.resolveAsset(id, rep, request.role)
                checkCanceled()
                if path then
                    progress = decode(transport.upload(url, path,
                        headers(token, 'application/octet-stream')), 200, json)
                else
                    progress = decode(transport.request('POST', url .. '/unavailable',
                        '', headers(token)), 200, json)
                end
            end
        end
        error('Batch exceeded progress limit', 0)
    end)

    -- Always attempt to release server assets, even after cancellation/error.
    local cleaned = true
    if batchUrl and token then
        local cleanupOk, response = protect(transport.request, 'DELETE', batchUrl, '', headers(token))
        cleaned = cleanupOk and type(response) == 'table' and response.status == 204
    end
    if not ok then
        -- Do not expose backend response bodies, credentials, or paths in errors.
        if result == 'Batch canceled' then
            error(result, 0)
        end
        error('Batch identification failed; no results returned', 0)
    end
    result.cleanupPending = not cleaned
    return result
end

return Batch
