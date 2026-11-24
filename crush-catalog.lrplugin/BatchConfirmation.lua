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
    return Review.collect(plan.manifest, result.results, {
        mode = options.mode,
        threshold = options.threshold,
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
            })
        end,
    })
end

-- Request crops only for modes that may show a review dialog. The batch
-- transport retains its session through the callback and deletes it afterward.
function Confirmation.run(plan, identifyBatch, options)
    plan.manifest.include_review_images = options.mode ~= 'automatic'
    return Preparation.run(plan, identifyBatch, {
        baseUrl = options.baseUrl,
        isCanceled = options.isCanceled,
        onProgress = options.onProgress,
        onCompleted = function(final, getCrop)
            local decisions = Confirmation.collect(plan, final, {
                mode = options.mode, threshold = options.threshold,
                isCanceled = options.isCanceled, language = options.language,
                getCrop = getCrop, searchFunction = options.searchFunction,
            })
            if not decisions then error('Batch canceled', 0) end
            return decisions
        end,
    })
end

return Confirmation
