local SearchLogic = assert(loadfile(
    'crush-catalog.lrplugin/Core/IdentificationSearchLogic.lua'
))()

describe('IdentificationSearchLogic', function()
    it('formats result items from the bottom three taxonomy levels', function()
        local result = {
            taxonomy = {
                'Animalia',
                'Chordata',
                'Vertebrata',
                'Aves',
                'Suliformes',
                'Phalacrocoracidae',
                'Nannopterum',
                'brasilianum',
            },
            commonNameTaxonomy = {
                'Animals',
                'Chordates',
                'Vertebrates',
                'Birds',
                'Gannets, Cormorants, And Allies',
                'Cormorants And Shags',
                'American Cormorants',
                'Olivaceous Cormorant',
            },
        }

        assert.are.equal(
            'Cormorants And Shags > American Cormorants > Olivaceous Cormorant',
            SearchLogic.resultTitle(result)
        )
        assert.are.equal(table.concat({
            'Animals (Animalia)',
            '   └─► Chordates (Chordata)',
            '      └─► Vertebrates (Vertebrata)',
            '         └─► Birds (Aves)',
            '            └─► Gannets, Cormorants, And Allies (Suliformes)',
            '               └─► Cormorants And Shags (Phalacrocoracidae)',
            '                  └─► American Cormorants (Nannopterum)',
            '                     └─► Olivaceous Cormorant (brasilianum)',
        }, '\n'), SearchLogic.taxonomyTree(result))
    end)
end)
