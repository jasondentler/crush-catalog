describe('SidecarLogic', function()
    local logic = assert(loadfile(
        'crush-catalog.lrplugin/Core/SidecarLogic.lua'
    ))()

    it('creates a portable sidecar and restores Lightroom values', function()
        local sidecar = logic.create('bird.CR3', {
            commonNames = 'American Robin, Fox Squirrel',
            scientificNames = 'Sciurus niger, Turdus migratorius',
            detectionCount = '2',
            topSuggestionCount = '1',
            otherSuggestionCount = '0',
            manualCount = '1',
            unsureCount = '1',
            detectionFalsePositivesCount = '0',
            topSuggestionConfidence = '98.2',
        })

        assert.are.equal(1, sidecar.schemaVersion)
        assert.are.equal('bird.CR3', sidecar.sourceFile)
        assert.same({ 'American Robin', 'Fox Squirrel' }, sidecar.metadata.commonNames)
        assert.are.equal(98.2, sidecar.metadata.topSuggestionConfidence)
        assert.same({
            commonNames = 'American Robin, Fox Squirrel',
            scientificNames = 'Sciurus niger, Turdus migratorius',
            detectionCount = '2',
            topSuggestionCount = '1',
            otherSuggestionCount = '0',
            manualCount = '1',
            unsureCount = '1',
            detectionFalsePositivesCount = '0',
            topSuggestionConfidence = '98.2',
        }, logic.metadataValues(sidecar, 'bird.CR3'))
        assert.are.equal(
            '/photos/bird.CR3.crush-catalog.json',
            logic.pathForPhoto('/photos/bird.CR3')
        )
    end)

    it('rejects mismatched files and unsupported schemas', function()
        local sidecar = logic.create('first.jpg', {})

        assert.has_error(function()
            logic.metadataValues(sidecar, 'second.jpg')
        end, 'Crush Catalog data file does not match second.jpg')

        sidecar.schemaVersion = 2
        assert.has_error(function()
            logic.metadataValues(sidecar, 'first.jpg')
        end, 'Unsupported Crush Catalog data version: 2')
    end)

    it('rejects malformed metadata values', function()
        local sidecar = logic.create('bird.jpg', {})
        sidecar.metadata.commonNames = 'Robin'

        assert.has_error(function()
            logic.metadataValues(sidecar, 'bird.jpg')
        end, 'metadata.commonNames must be an array')
    end)
end)
