local Execution = assert(loadfile('crush-catalog.lrplugin/Core/BatchExecution.lua'))()

local function fixture()
    local a, b, c = {}, {}, {}
    local plan = {
        manifest = { frames = { { frame_id = 'a' }, { frame_id = 'b' }, { frame_id = 'c' } } },
        items = {
            a = { item = { photo = a } },
            b = { item = { photo = b } },
            c = { item = { photo = c } },
        },
    }
    local disposition = { disposition = 'confirmed' }
    local final = {
        results = {
            { frame_id = 'a', status = 'identified' },
            { frame_id = 'b', status = 'uncertain' },
            { frame_id = 'c', status = 'failed' },
        },
        confirmations = { approved = { { frame_id = 'a', dispositions = { disposition } } } },
        operationCounts = { detector_inputs = 3 },
    }
    local state = { recorded = {}, reports = {}, current = true, canceled = false }
    local options = {
        protect = pcall,
        confirm = function() return final end,
        isCanceled = function() return state.canceled end,
        isCurrent = function() return state.current end,
        isReprocessing = function(photo) return photo == a end,
        record = function(entries, validate)
            assert(validate(), 'Changed source')
            state.recorded[#state.recorded + 1] = entries
            return 'executed'
        end,
        report = function(item, reason)
            state.reports[#state.reports + 1] = { item = item, reason = reason }
        end,
    }
    return plan, final, options, state
end

describe('BatchExecution', function()
    it('passes only approved entries to the writer and accounts for exclusions', function()
        local plan, _, options, state = fixture()
        local excluded = { { item = {}, reason = 'develop_view_unverified' } }
        local report = Execution.run({ plan }, excluded, options)
        assert.are.equal(1, report.written)
        assert.are.equal(1, report.skipped)
        assert.are.equal(1, report.failed)
        assert.are.equal(plan.items.c.item, state.reports[2].item)
        assert.are.equal(1, report.excluded)
        assert.are.equal(1, #state.recorded)
        assert.are.equal(1, #state.recorded[1])
        assert.are.equal(plan.items.a.item.photo, state.recorded[1][1].photo)
        assert.is_true(state.recorded[1][1].reprocessing)
        assert.are.equal('develop_view_unverified', state.reports[1].reason)
        assert.are.equal(3, report.operations[1].detector_inputs)
    end)

    it('reports an oversized image as failed, not withheld, and writes other approvals', function()
        local plan, final, options, state = fixture()
        final.results[3].error_code = 'payload_too_large'
        local report = Execution.run({ plan }, {}, options)
        assert.are.equal(1, report.failed)
        assert.are.equal(1, report.skipped)
        assert.are.equal(1, report.written)
        assert.same({ item = plan.items.c.item, reason = 'payload_too_large' }, state.reports[1])
    end)

    it('does not invoke the writer in review-only mode', function()
        local plan, _, options, state = fixture()
        options.dryRun = true
        local report = Execution.run({ plan }, {}, options)
        assert.are.equal(1, report.approved)
        assert.are.equal(0, report.written)
        assert.same({}, state.recorded)
    end)

    it('archives analysis without reviewing, approving, or writing any frame', function()
        local plan, final, options, state = fixture()
        options.analysisOnly = true
        final.confirmations = nil
        final.results[3].error_code = 'representation_unavailable'
        local report = Execution.run({ plan }, {}, options)
        assert.are.equal(3, report.analyzed)
        assert.are.equal(2, report.unreviewed)
        assert.are.equal(1, report.failed)
        assert.are.equal(0, report.approved)
        assert.are.equal(0, report.reviewPrompts)
        assert.are.equal(0, report.written)
        assert.same({}, state.recorded)
        assert.are.equal('representation_unavailable', state.reports[1].reason)
    end)

    it('rejects changed sources and stops further plans after a write failure', function()
        local plan, _, options, state = fixture()
        state.current = false
        local report = Execution.run({ plan, plan }, {}, options)
        assert.are.equal(0, report.written)
        assert.are.equal(2, report.failed)
        assert.same({}, state.recorded)
        assert.are.equal(2, #state.reports)
    end)

    it('discards pending decisions when cancellation follows confirmation', function()
        local plan, final, options, state = fixture()
        options.confirm = function()
            state.canceled = true
            return final
        end
        local report = Execution.run({ plan }, {}, options)
        assert.is_true(report.canceled)
        assert.are.equal(0, report.written)
        assert.same({}, state.recorded)
    end)

    it('stops on inference error without invoking the writer', function()
        local plan, _, options, state = fixture()
        options.confirm = function() error('Backend unavailable') end
        local report = Execution.run({ plan, plan }, {}, options)
        assert.are.equal(3, report.failed)
        assert.same({}, state.recorded)
        assert.are.equal(1, #state.reports)
    end)

    it('reports synonym failure separately from committed photo assignments', function()
        local plan, final, options = fixture()
        final.cleanupPending = true
        options.record = function() return 'executed', 'Synonyms failed' end
        local report = Execution.run({ plan }, {}, options)
        assert.are.equal(1, report.written)
        assert.same({ 'Server session cleanup pending', 'Synonyms failed' }, report.warnings)
    end)

    it('refuses unknown or duplicate approvals before writing', function()
        local plan, final, options, state = fixture()
        final.confirmations.approved[2] = { frame_id = 'a', dispositions = {} }
        assert.has_error(function() Execution.run({ plan }, {}, options) end)
        final.confirmations.approved[2].frame_id = 'unknown'
        assert.has_error(function() Execution.run({ plan }, {}, options) end)
        assert.same({}, state.recorded)
    end)
end)
