describe('MetadataProvider', function()
    it('defines a valid Lightroom custom metadata schema', function()
        local schema = assert(loadfile('crush-catalog.lrplugin/MetadataProvider.lua'))()
        local supportedDataTypes = {
            enum = true,
            string = true,
            url = true,
        }
        local fieldIds = {}

        assert.are.equal(2, schema.schemaVersion)

        for _, field in ipairs(schema.metadataFieldsForPhotos) do
            assert.is_nil(fieldIds[field.id], 'Duplicate metadata field: ' .. field.id)
            assert.is_true(
                supportedDataTypes[field.dataType],
                'Unsupported metadata type for ' .. field.id .. ': ' .. tostring(field.dataType)
            )
            fieldIds[field.id] = true
        end
    end)
end)
