# Crush Catalog keywording

Here's the implementation plan for keywording based on Crush Catalog.

## Keywords Setup

Implement a hierarchy of keywords as follows (using the Chapman's Zebra as an example):

```text
Crush Catalog
> All
  > Chapman's Zebra
> Common Names
  > Animals
    > Chordates
      > Vertebrates
        > Mammals
          > Therians
            > Placental Mammals
              > Ungulates, Carnivorans, and Allies
                > Odd-toed Ungulates
                  > Equids
                    > Horses, Asses, and Zebras
                      > Plains Zebra
                        > Chapman's Zebra
> Scientific Names
  > Animalia
    > Chordata
      > Vertebrata
        > Mammalia
          > Theria
            > Placentalia
              > Laurasiatheria
                > Perissodactyla
                  > Equidae
                    > Equus
                      > quagga
                        > chapmani
```

Crush Catalog is the root keyword of all the keywords created by this plugin.
Crush Catalog has exactly 3 children: All, Common Names, Scientific Names.
All contains a flat list of common name strings of Genus + species (determined by the taxonomy_rank array, not a hard-coded index).
Common Names contains a full hierarchy of the common name strings.
Scientific Names contains a full hierarchy of the scientific name strings.

Each level of the Scientific Names hierarchy is a synonym for it's corresponding level in the Common Names hierarchy. For example: Animalia is a synonym for Animals and vice versa, chapmani is a synonym for Chapman's Zebra and vice versa, and so on.

The species-level keyword (determined by the taxonomy_rank array, not a hard-coded index)under Scientific Names should have Genus + species as a synonym, so "quagga" will have the synonym "Equus quagga".

The subspecies level keyword (determined by the taxonomy_rank array, not a hard-coded index)under Scientific Names should have Genus + species + subspecies as a synonym, so "chapmani" will have the synonym "Equus quagga chapmani" as a synonym.

## Photo Setup

A photo will be associated with the following keywords:

* The common name entry for the detected animal under the All keyword.
* Each keyword in the hierarchy under Common Names associated with the animal detected
* Each keyword in the hierarchy under Scientific Names associated with the animal detected

### Implementation

Processing is triggered inside `PhotoMetadata.record`

Logic for maintaining the keywords and associating the photo with keywords should be contained in a new file PhotoKeywording.lua

Keywords should be created if they don't exist, including the root Crush Catalog.



