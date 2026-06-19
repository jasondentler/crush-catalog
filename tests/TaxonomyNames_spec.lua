local TaxonomyNames = assert(loadfile('crush-catalog.lrplugin/Core/TaxonomyNames.lua'))()

describe('TaxonomyNames', function()
    it('does not duplicate a genus already included in a species name', function()
        local prediction = {
            taxonomy = {
                'Animalia', 'Chordata', 'Aves', 'Passeriformes',
                'Corvidae', 'Aphelocoma', 'Aphelocoma californica',
            },
            taxonomy_ranks = {
                'kingdom', 'phylum', 'class', 'order', 'family', 'genus', 'species',
            },
        }

        assert.are.equal('Aphelocoma californica', TaxonomyNames.scientificName(prediction))
    end)

    it('combines genus, species, and subspecies ranks', function()
        local ranks = {
            'kingdom', 'phylum', 'class', 'order', 'family',
            'genus', 'species', 'subspecies',
        }
        local epithetPrediction = {
            taxonomy = {
                'Animalia', 'Chordata', 'Aves', 'Passeriformes',
                'Corvidae', 'Aphelocoma', 'californica', 'woodhouseii',
            },
            taxonomy_ranks = ranks,
        }
        local qualifiedPrediction = {
            taxonomy = {
                'Animalia', 'Chordata', 'Aves', 'Passeriformes',
                'Corvidae', 'Aphelocoma', 'Aphelocoma californica',
                'Aphelocoma californica woodhouseii',
            },
            taxonomy_ranks = ranks,
        }

        assert.are.equal(
            'Aphelocoma californica woodhouseii',
            TaxonomyNames.scientificName(epithetPrediction)
        )
        assert.are.equal(
            'Aphelocoma californica woodhouseii',
            TaxonomyNames.scientificName(qualifiedPrediction)
        )
    end)

    it('finds the genus by name when taxonomy ranks are absent', function()
        local prediction = {
            taxonomy = {
                'Animalia', 'Chordata', 'Aves', 'Passeriformes',
                'Corvidae', 'Corvus', 'corax',
            },
            taxonomy_common_names = {
                'Animals', '', 'Birds', '', 'Crows', 'Ravens', 'Common Raven',
            },
        }

        assert.are.equal('Common Raven', TaxonomyNames.commonName(prediction))
        assert.are.equal('Corvus corax', TaxonomyNames.scientificName(prediction))
    end)
end)
