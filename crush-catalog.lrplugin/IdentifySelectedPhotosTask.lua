local LrApplication = import 'LrApplication'
local LrDate = import 'LrDate'
local LrDialogs = import 'LrDialogs'
local LrFunctionContext = import 'LrFunctionContext'
local LrLocalization = import 'LrLocalization'
local LrProgressScope = import 'LrProgressScope'
local LrTasks = import 'LrTasks'

local AutomaticModesDialog = require 'AutomaticModesDialog'
local IdentificationDialog = require 'IdentificationDialog'
local PhotoMetadata = require 'PhotoMetadata'
local WildCatalogApi = require 'WildCatalogApi'

local function pluginPath()
    if _PLUGIN ~= nil and _PLUGIN.path ~= nil then
        return _PLUGIN.path
    end

    local source = debug.getinfo(1, 'S').source
    return source:match('^@(.+)/[^/]+$') or '.'
end

local AutomaticModesLogic = assert(
    loadfile(pluginPath() .. '/Core/AutomaticModesLogic.lua')
)()

local function trace(message)
    if type(PhotoMetadata.trace) == 'function' then
        PhotoMetadata.trace(message)
    end
end

local function firstAvailableMetadata(photo, accessor, keys)
    for _, key in ipairs(keys) do
        local value = photo[accessor](photo, key)

        if value ~= nil and value ~= '' then
            return value
        end
    end

    return nil
end

local function metadataForPhoto(photo)
    local gps = photo:getRawMetadata('gps')
    local exifOverride = {}
    local captureDateTime = photo:getRawMetadata('dateTimeOriginalISO8601')

    if captureDateTime ~= nil then
        exifOverride.captured_at = captureDateTime
    end

    if gps ~= nil and gps.latitude ~= nil and gps.longitude ~= nil then
        exifOverride.gps_coordinates = {
            latitude = gps.latitude,
            longitude = gps.longitude,
        }
    end

    return {
        path = photo:getRawMetadata('path'),
        originalFilename = firstAvailableMetadata(
            photo,
            'getFormattedMetadata',
            { 'preservedFileName', 'fileName' }
        ),
        exifOverride = exifOverride,
    }
end

local function hasCrushCatalogMetadata(photo)
    local detectionCount = photo:getPropertyForPlugin(_PLUGIN, 'detectionCount')
    return detectionCount ~= nil and detectionCount ~= ''
end

local function appendFailure(failures, metadata, failure)
    local reason = tostring(failure)
    if reason == 'payload_too_large' then
        reason = 'Image too large for identification (server size limit)'
    end
    local message = (metadata.originalFilename or metadata.path or '<unknown>')
        .. ': ' .. reason
    failures[#failures + 1] = message
    trace('Identification failure: ' .. message)
end

local function traceJson(label, value)
    if type(PhotoMetadata.trace) ~= 'function' then
        return
    end

    local encoded, json = pcall(
        WildCatalogApi.JSON.encode,
        WildCatalogApi.JSON,
        value
    )

    if encoded then
        PhotoMetadata.trace(label .. ': ' .. json)
    else
        PhotoMetadata.trace(label .. ' could not be encoded: ' .. tostring(json))
    end
end

local function showFailures(failures)
    if #failures > 0 then
        LrDialogs.message(
            LOC '$$$/CrushCatalog/IdentifyErrorsTitle=Some images could not be identified',
            table.concat(failures, '\n'),
            'warning'
        )
    end
end

local function createProgress()
    local progress = LrProgressScope {
        title = LOC '$$$/CrushCatalog/IdentifyProgress=Identifying selected images',
    }

    progress:setCancelable(true)
    progress:setPausable(true)

    return progress
end

local function formatRemaining(seconds)
    local totalMinutes = math.max(1, math.ceil(seconds / 60))
    local hours = math.floor(totalMinutes / 60)
    local minutes = totalMinutes % 60

    if hours == 0 then
        return string.format(
            LOC '$$$/CrushCatalog/MinutesRemaining=%dm remaining',
            minutes
        )
    end

    if minutes == 0 then
        return string.format(
            LOC '$$$/CrushCatalog/HoursRemaining=%dh remaining',
            hours
        )
    end

    return string.format(
        LOC '$$$/CrushCatalog/HoursMinutesRemaining=%dh %dm remaining',
        hours,
        minutes
    )
end

local function estimateRemaining(durations, remaining)
    if #durations == 0 then
        return nil
    end

    local total = 0
    local first = math.max(1, #durations - 9)

    for index = first, #durations do
        total = total + durations[index]
    end

    return total / (#durations - first + 1) * remaining
end

local function appendDuration(durations, duration)
    durations[#durations + 1] = duration

    if #durations > 10 then
        table.remove(durations, 1)
    end
end

local function copyOptions(options)
    local copy = {}

    for key, value in pairs(options or {}) do
        copy[key] = value
    end

    return copy
end

local function waitWhilePaused(progress)
    local reportedPaused = false
    local pauseStarted

    while progress:isPaused() and not progress:isCanceled() do
        if not reportedPaused then
            progress:setCaption(LOC '$$$/CrushCatalog/IdentifyPaused=Identification paused')
            trace('Identification paused')
            reportedPaused = true
            pauseStarted = LrDate.currentTime()
        end

        LrTasks.sleep(0.2)
    end

    if reportedPaused and not progress:isCanceled() then
        trace('Identification resumed')
    end
    return pauseStarted and math.max(0, LrDate.currentTime() - pauseStarted) or 0
end

local function identifyBatchPhotos(photos, options, progress, failures)
    local Preparation = require 'BatchPreparation'
    local Confirmation = require 'BatchConfirmation'
    local Execution = assert(loadfile(pluginPath() .. '/Core/BatchExecution.lua'))()
    local language = LrLocalization.currentLanguage()
    local pausedSeconds = 0
    local function canceled()
        pausedSeconds = pausedSeconds + waitWhilePaused(progress)
        return progress:isCanceled()
    end
    progress:setCaption('Preparing selected images')
    local plans, excluded = Preparation.prepare(photos, {
        language = language, isCanceled = canceled,
    })
    local finished = #excluded
    local lastDone, lastTime = finished, LrDate.currentTime() - pausedSeconds
    local recentDurations = {}
    local function updateProgress(done)
        done = math.min(#photos, math.max(lastDone, done))
        local remaining = #photos - done
        if done > lastDone then
            local now = LrDate.currentTime() - pausedSeconds
            if now > lastTime then
                appendDuration(recentDurations, (now - lastTime) / (done - lastDone))
            end
            lastDone, lastTime = done, now
        end
        local caption = string.format('%d of %d - %d remaining', done, #photos, remaining)
        local estimate = estimateRemaining(recentDurations, remaining)
        if remaining > 0 then
            caption = caption .. (estimate and (' - ' .. formatRemaining(estimate))
                or ' - estimating time')
        end
        progress:setCaption(caption)
        progress:setPortionComplete(done, #photos)
    end
    updateProgress(finished)
    local previewCount, previewBlockers = 0, {}
    for _, plan in ipairs(plans) do
        for _, frame in ipairs(plan.manifest.frames) do
            if #frame.representations == 2 then previewCount = previewCount + 1 end
            for _, reason in ipairs(plan.items[frame.frame_id].previewBlockers or {}) do
                previewBlockers[reason] = (previewBlockers[reason] or 0) + 1
            end
        end
    end
    trace('Batch preparation: plans=' .. #plans .. ', preview candidates=' .. previewCount
        .. ', excluded=' .. #excluded)
    traceJson('Preview eligibility blockers', previewBlockers)
    local renderRun = Preparation.renderRun()
    local executed, report = LrTasks.pcall(Execution.run, plans, excluded, {
        protect = LrTasks.pcall,
        isCanceled = canceled,
        isWriteCanceled = function() return progress:isCanceled() end,
        isCurrent = Preparation.isCurrent,
        isReprocessing = hasCrushCatalogMetadata,
        record = PhotoMetadata.recordBatch,
        report = function(item, reason)
            local metadata = { originalFilename = 'Batch' }
            if item and item.photo then
                metadata.originalFilename = firstAvailableMetadata(item.photo,
                    'getFormattedMetadata', { 'preservedFileName', 'fileName' }) or '<unknown photo>'
            end
            appendFailure(failures, metadata, reason)
        end,
        confirm = function(plan)
            updateProgress(finished)
            if plan.manifest.execution_mode == 'burst' then
                plan.manifest.burst_min_detection_confidence = (options.detectorThreshold or 0) / 100
                plan.manifest.burst_min_crop_detail = (options.cropDetailThreshold or 0) / 100
            end
            return Confirmation.run(plan, WildCatalogApi.identifyBatch, {
                mode = options.mode, threshold = options.threshold, language = language,
                renderRun = renderRun,
                isCanceled = canceled,
                onReviewPlan = function(planSummary) traceJson('Batch review plan', planSummary) end,
                onProgress = function(done)
                    updateProgress(finished + math.max(0, done))
                end,
            })
        end,
        onPlanFinished = function(plan)
            finished = finished + #plan.manifest.frames
            updateProgress(finished)
        end,
    })
    local cleaned, cleanupResult = LrTasks.pcall(renderRun.finish)
    if not cleaned or not cleanupResult then
        error('Temporary virtual copy cleanup failed; cleanup collection retained', 0)
    end
    if not executed then error(report, 0) end
    if report.canceled then progress:cancel() end
    traceJson('Batch execution report', report)
    local summary = string.format(
        'Selected: %d\nPreview candidates: %d\nApproved: %d\nWritten: %d\n'
            .. 'Withheld: %d\nExcluded: %d\nFailed: %d',
        #photos, previewCount, report.approved, report.written,
        report.skipped, report.excluded, report.failed)
    local reasons = {}
    for reason, count in pairs(previewBlockers) do
        reasons[#reasons + 1] = reason .. ': ' .. count
    end
    table.sort(reasons)
    if #reasons > 0 then summary = summary .. '\n\nPreview blockers:\n' .. table.concat(reasons, '\n') end
    if #failures > 0 then
        summary = summary .. '\n\nIssues:\n' .. table.concat(failures, '\n')
    end
    if report.canceled then
        summary = summary .. '\nCanceled; earlier completed writes remain.'
    end
    if #report.warnings > 0 then
        summary = summary .. '\n\nWarnings:\n' .. table.concat(report.warnings, '\n')
    end
    if #report.operations > 0 then
        local totals = {}
        for _, counts in ipairs(report.operations) do
            for key, value in pairs(counts) do
                if type(value) == 'number' then totals[key] = (totals[key] or 0) + value end
            end
        end
        summary = summary .. string.format(
            '\n\nData received: %.1f MB\nFull-quality decodes: %d\n'
                .. 'Classifier inputs: %d\nReused classifications: %d',
            (totals.received_bytes or 0) / 1000000, totals.full_decode_attempts or 0,
            totals.classifier_inputs or 0, totals.reused_classifier_inputs or 0)
    end
    summary = summary .. string.format(
        '\nReview prompts: %d\nFiltered detections: %d (confidence: %d, detail: %d)',
        report.reviewPrompts or 0, report.suppressedDetections or 0,
        report.suppressedLowConfidence or 0, report.suppressedLowDetail or 0)
    LrDialogs.message('Image identification', summary, #failures > 0 and 'warning' or 'info')
end

local function identifySelectedPhotos()
    local photos = LrApplication.activeCatalog():getTargetPhotos()
    local options = { mode = 'manual', threshold = 90, processingScope = 'all' }
    trace('Beginning identification; selected photos=' .. tostring(#photos))

    if #photos > 1 then
        options = AutomaticModesDialog.show()

        if options == nil then
            trace('Identification canceled in automatic modes dialog')
            return
        end

        trace('Automatic modes options: mode=' .. tostring(options.mode)
            .. ', threshold=' .. tostring(options.threshold)
            .. ', processingScope=' .. tostring(options.processingScope))

        local eligible = {}

        for _, photo in ipairs(photos) do
            local label = firstAvailableMetadata(
                photo,
                'getFormattedMetadata',
                { 'preservedFileName', 'fileName' }
            ) or tostring(photo)
            local detectionCount = photo:getPropertyForPlugin(_PLUGIN, 'detectionCount')
            local unsureCount = photo:getPropertyForPlugin(_PLUGIN, 'unsureCount')

            local shouldProcess = AutomaticModesLogic.shouldProcess(
                detectionCount,
                unsureCount,
                options.processingScope
            )

            trace('Photo eligibility: photo=' .. label
                .. ', detectionCount=' .. tostring(detectionCount)
                .. ', unsureCount=' .. tostring(unsureCount)
                .. ', process=' .. tostring(shouldProcess))

            if shouldProcess then
                eligible[#eligible + 1] = photo
            end
        end

        photos = eligible
    else
        trace('Using manual mode for single-photo selection')
    end

    trace('Photos eligible for identification=' .. tostring(#photos))

    local progress = createProgress()
    local failures = {}
    local recentDurations = {}

    if options.engine == 'batch' then
        local succeeded, failure = LrTasks.pcall(identifyBatchPhotos, photos, options, progress, failures)
        if not succeeded and failure ~= 'Batch canceled' then
            appendFailure(failures, { originalFilename = 'Batch' }, failure)
        end
        progress:done()
        -- A completed run already includes every issue in its summary.
        if not succeeded then showFailures(failures) end
        return
    end

    for index, photo in ipairs(photos) do
        waitWhilePaused(progress)

        if progress:isCanceled() then
            trace('Identification canceled from progress scope')
            break
        end

        local metadata = metadataForPhoto(photo)
        local commonNameLanguage = LrLocalization.currentLanguage()
        local dialogOptions = copyOptions(options)
        local stop = false
        local caption = string.format(
            LOC '$$$/CrushCatalog/IdentifyProgressCaption=Identifying %s (%d of %d)',
            metadata.originalFilename or metadata.path or '',
            index,
            #photos
        )

        if options.mode == 'automatic' then
            local remaining = #photos - index + 1
            local estimate = estimateRemaining(recentDurations, remaining)

            if estimate ~= nil and estimate > 0 then
                caption = caption .. ' - ' .. formatRemaining(estimate)
            end
        end

        progress:setCaption(caption)
        progress:setPortionComplete(index - 1, #photos)
        local imageStartedAt = options.mode == 'automatic'
            and LrDate.currentTime() or nil

        dialogOptions.gpsCoordinates = metadata.exifOverride.gps_coordinates
        dialogOptions.commonNameLanguage = commonNameLanguage

        local succeeded, response = LrTasks.pcall(WildCatalogApi.identify, metadata.path, {
            originalFilename = metadata.originalFilename,
            exifOverride = metadata.exifOverride,
            return_detected_images = options.mode ~= 'automatic',
            common_name_language = commonNameLanguage,
        })

        if succeeded then
            traceJson(
                'Backend API response JSON for '
                    .. (metadata.originalFilename or metadata.path or '<unknown>'),
                response.result
            )
            local processed, action, dispositions = LrTasks.pcall(
                IdentificationDialog.showForResponse,
                photo,
                response,
                index,
                #photos,
                dialogOptions
            )

            if processed then
                traceJson(
                    'Dialog result JSON for '
                        .. (metadata.originalFilename or metadata.path or '<unknown>'),
                    {
                        action = action,
                        dispositions = dispositions or {},
                    }
                )
                stop = action == 'stop'

                if action == 'continue' then
                    local recorded, recordError = LrTasks.pcall(
                        PhotoMetadata.record,
                        photo,
                        dispositions,
                        hasCrushCatalogMetadata(photo)
                    )

                    if not recorded then
                        appendFailure(failures, metadata, recordError)
                    end
                end
            else
                appendFailure(failures, metadata, action)
            end
        else
            appendFailure(failures, metadata, response)
        end

        if imageStartedAt ~= nil then
            local duration = LrDate.currentTime() - imageStartedAt

            if duration > 0 then
                appendDuration(recentDurations, duration)
            end
        end

        progress:setPortionComplete(index, #photos)

        if stop then
            progress:cancel()
            break
        end
    end

    progress:done()
    showFailures(failures)
    trace('Finished identification; failures=' .. tostring(#failures))
end

LrFunctionContext.postAsyncTaskWithContext('identifySelectedPhotos', identifySelectedPhotos)

return {
    estimateRemaining = estimateRemaining,
    formatRemaining = formatRemaining,
    identifySelectedPhotos = identifySelectedPhotos,
    metadataForPhoto = metadataForPhoto,
    waitWhilePaused = waitWhilePaused,
}
