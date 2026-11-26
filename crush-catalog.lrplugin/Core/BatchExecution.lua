-- Coordinates one prepared batch at a time. The writer is invoked only with
-- finalized, completely approved frames, never with partial server responses.
local Execution = {}

function Execution.run(plans, excluded, options)
    local report = { approved = 0, written = 0, skipped = 0, excluded = #excluded,
        failed = 0, warnings = {}, canceled = false, operations = {},
        analyzed = 0, unreviewed = 0,
        reviewPrompts = 0, suppressedDetections = 0,
        suppressedLowConfidence = 0, suppressedLowDetail = 0 }
    local function canceled()
        return options.isCanceled and options.isCanceled()
    end
    for _, entry in ipairs(excluded) do
        options.report(entry.item, entry.reason)
    end
    for _, plan in ipairs(plans) do
        if canceled() then report.canceled = true; break end
        local ok, final = options.protect(options.confirm, plan)
        if not ok then
            if final == 'Batch canceled' or canceled() then
                report.canceled = true
                break
            end
            report.failed = report.failed + #plan.manifest.frames
            options.report(nil, 'Batch failed; no results applied: ' .. tostring(final))
            -- Do not silently retry a failed batch through the legacy writer.
            break
        end
        if final.cleanupPending then
            report.warnings[#report.warnings + 1] = 'Server session cleanup pending'
        end
        if (final.missingReviewImages or 0) > 0 then
            report.warnings[#report.warnings + 1] = string.format(
                '%d review images unavailable; missing evidence cannot be manually confirmed',
                final.missingReviewImages)
        end
        if final.operationCounts then
            report.operations[#report.operations + 1] = final.operationCounts
        end
        if canceled() then report.canceled = true; break end
        report.analyzed = report.analyzed + #final.results
        local failedFrames = {}
        local failedCount = 0
        for _, frame in ipairs(final.results) do
            if frame.status == 'failed' then
                failedFrames[frame.frame_id] = true
                failedCount = failedCount + 1
                report.failed = report.failed + 1
                options.report(plan.items[frame.frame_id].item, frame.error_code or 'analysis_failed')
            end
            report.suppressedDetections = report.suppressedDetections + (frame.suppressed_detections or 0)
            report.suppressedLowConfidence = report.suppressedLowConfidence
                + (frame.suppressed_low_confidence or 0)
            report.suppressedLowDetail = report.suppressedLowDetail + (frame.suppressed_low_detail or 0)
        end
        if options.analysisOnly then
            report.unreviewed = report.unreviewed + #final.results - failedCount
        else
            local decisions = final.confirmations
            assert(type(decisions) == 'table' and type(decisions.approved) == 'table',
                'Missing finalized confirmation decisions')
            report.reviewPrompts = report.reviewPrompts + (decisions.reviewPrompts or 0)
            local entries, seen = {}, {}
            for _, approval in ipairs(decisions.approved) do
                local id = approval.frame_id
                local entry = plan.items[id]
                assert(entry and not seen[id] and not failedFrames[id], 'Unexpected approved frame')
                seen[id] = true
                entries[#entries + 1] = {
                    photo = entry.item.photo, dispositions = approval.dispositions,
                    reprocessing = options.isReprocessing(entry.item.photo),
                }
            end
            report.approved = report.approved + #entries
            report.skipped = report.skipped + #plan.manifest.frames - #entries - failedCount

            -- Recheck all successful members, including evidence frames which may
            -- themselves have been withheld due to another unresolved detection.
            local function validate()
                if options.isWriteCanceled and options.isWriteCanceled() then return false end
                if not options.isWriteCanceled and canceled() then return false end
                for _, frame in ipairs(final.results) do
                    local entry = plan.items[frame.frame_id]
                    if frame.status ~= 'failed' and (not entry or not options.isCurrent(entry.item)) then
                        return false
                    end
                end
                return true
            end
            if #entries > 0 and not options.dryRun then
                local written, status, warning = options.protect(options.record, entries, validate)
                if not written or status ~= 'executed' then
                    report.failed = report.failed + #entries
                    options.report(nil, 'Batch write failed; stopping further batches')
                    if canceled() then report.canceled = true end
                    break
                end
                report.written = report.written + #entries
                if warning then report.warnings[#report.warnings + 1] = warning end
            end
        end
        if options.onPlanFinished then options.onPlanFinished(plan, report) end
    end
    return report
end

return Execution
