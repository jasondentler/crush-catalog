-- Collect decisions against a prepared manifest, never mutate the catalog.
local Preparation = require 'BatchPreparation'
local Dialog = require 'BatchReviewDialog'

local function pluginPath()
    if _PLUGIN and _PLUGIN.path then return _PLUGIN.path end
    return debug.getinfo(1, 'S').source:match('^@(.+)/[^/]+$') or '.'
end

local Review = assert(loadfile(pluginPath() .. '/Core/BatchReview.lua'))()
local Confirmation = {}

function Confirmation.collect(plan, result, options)
    if options.onReviewPlan then
        local units = Review.units(plan.manifest, result.results, options.mode ~= 'automatic')
        local summary = { frames = {}, units = {} }
        for _, frame in ipairs(result.results) do
            local entry = plan.items[frame.frame_id]
            local row = {
                file = entry.item.photo:getFormattedMetadata('fileName'),
                capturedAt = entry.item.capturedAt,
                status = frame.status, boundary = frame.review_group_boundary,
                fallback = frame.fallback_reason, space = frame.coordinate_space,
                suppressed = frame.suppressed_detections,
                lowConfidence = frame.suppressed_low_confidence,
                lowDetail = frame.suppressed_low_detail, objects = {},
            }
            for _, object in ipairs(frame.objects) do
                row.objects[#row.objects + 1] = {
                    track = object.track_id, group = object.review_group_id,
                    confidence = object.detection_confidence, box = object.bounding_box,
                    reason = object.reason,
                }
            end
            summary.frames[#summary.frames + 1] = row
        end
        for _, unit in ipairs(units) do
            local members = {}
            for _, member in ipairs(unit.members) do
                members[#members + 1] = { member.frameIndex, member.objectIndex }
            end
            summary.units[#summary.units + 1] = { kind = unit.kind, members = members }
        end
        options.onReviewPlan(summary)
    end
    local dialogCount = 0
    local archive = options.onArchive
    local decisions, reason = Review.collect(plan.manifest, result.results, {
        mode = options.mode,
        threshold = options.threshold,
        onDisposition = archive and function(disposition)
            archive(result.batchId, { kind = 'disposition', result = disposition })
        end or nil,
        isCanceled = options.isCanceled,
        isCurrent = function(id)
            local entry = plan.items[id]
            return entry ~= nil and Preparation.isCurrent(entry.item)
        end,
        review = function(unit)
            return Dialog.review(unit, {
                items = plan.items,
                imageCount = #plan.manifest.frames,
                language = options.language,
                getCrop = options.getCrop,
                searchFunction = options.searchFunction,
                onDialog = function() dialogCount = dialogCount + 1 end,
            })
        end,
    })
    if decisions then decisions.reviewPrompts = dialogCount end
    if archive then
        archive(result.batchId, { kind = 'review_completed', decisions = decisions,
            reason = reason, reviewPrompts = dialogCount })
    end
    return decisions, reason
end

-- Request crops only for modes that may show a review dialog. The batch
-- transport caches verified evidence and releases the session before review.
function Confirmation.run(plan, identifyBatch, options)
    plan.manifest.include_review_images = not options.analysisOnly and options.mode ~= 'automatic'
    if options.analysisOnly then plan.manifest.include_review_groups = true end
    plan.manifest.archive_evidence = options.analysisOnly == true or options.onArchive ~= nil
    plan.manifest.compact_progress = true
    return Preparation.run(plan, identifyBatch, {
        baseUrl = options.baseUrl,
        isCanceled = options.isCanceled,
        isUploadCanceled = options.isUploadCanceled,
        onProgress = options.onProgress,
        onCompleted = function(final, getCrop)
            if options.analysisOnly then
                if options.onArchive then
                    options.onArchive(final.batchId, {
                        kind = 'analysis_completed', manifest = plan.manifest,
                        operationCounts = final.operationCounts,
                    })
                end
                return nil
            end
            if options.onArchive then
                options.onArchive(final.batchId, {
                    kind = 'review_started', mode = options.mode, threshold = options.threshold,
                    manifest = plan.manifest, operationCounts = final.operationCounts,
                })
            end
            local decisions = Confirmation.collect(plan, final, {
                mode = options.mode, threshold = options.threshold,
                isCanceled = options.isCanceled, language = options.language,
                getCrop = getCrop, searchFunction = options.searchFunction,
                onReviewPlan = options.onReviewPlan,
                onArchive = options.onArchive,
            })
            if not decisions then error('Batch canceled', 0) end
            return decisions
        end,
    })
end

return Confirmation
