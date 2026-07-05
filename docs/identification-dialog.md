# Identification Dialog

The identification dialog lets the user review each detected animal in a Lightroom photo and choose how that detection should be recorded. It is used directly in manual mode, selectively in assisted mode, and not at all for detections that automatic mode can disposition without user input.

## Inputs

The dialog flow receives:

* The Lightroom photo being processed.
* The Wild Catalog response for that photo.
* The current image position within the batch.
* The selected processing options, including mode and confidence threshold.

The Wild Catalog response may provide detections as either `response.result.results` or `response.result`. Each detection contains zero or more predictions. When a manual dialog must be shown, the response must also include the matching detected image bytes in `response.detectedImages` at the same detection index.

## Prediction List

For each detection, the prediction dropdown is built from the detection's predictions.

Each prediction is shown as:

```text
<common name> (<scientific name>) <confidence percentage>
```

For example:

```text
Fox Squirrel (Sciurus niger) 98.2%
```

The common name is the last available common-name taxonomy value. If no common name is available, it displays `Unknown`.

The scientific name is built from the taxonomy starting at the genus rank when possible. If taxonomy ranks are unavailable, the logic falls back to the last taxonomy entries that look like scientific names. If no scientific name is available, it displays `Unknown`.

Confidence values are converted from model scores to percentages and displayed with one decimal place.

If a detection has no predictions, the dropdown contains a single `No predictions` item with value `0`.

## Manual Dialog Requirements

When a detection requires user review, Lightroom displays a modal dialog with:

* Title: `Image <image index> of <image count>: <photo filename> (Animal <detection index> of <detection count>)`
* A preview image of the detected animal.
* A prediction dropdown.
* A primary `Confirm` action.
* Accessory buttons: `Stop`, `Next Image`, `Not An Animal`, `Unsure`, and `Not Listed`.

The right side of the dialog shows `Unsure`, `Not Listed`, and `Confirm` in that order.

The preview image is written to a temporary file before the dialog opens and deleted when the dialog closes.

The first prediction item is selected by default. If there are no predictions, the `No predictions` item is selected.

The dialog is fixed-size and displays the preview at 640 by 480 pixels.

## User Actions

### Confirm

`Confirm` records the currently selected dropdown prediction as a confirmed identification.

The resulting detection disposition is:

```lua
{
    disposition = 'confirmed',
    predictionConfidences = { ... },
    selectedPredictionIndex = <selected dropdown value>,
    selectedPrediction = {
        confidence = <prediction confidence>,
        taxonomy = <prediction taxonomy>,
        taxonomyRanks = <prediction taxonomy ranks>,
        commonNameTaxonomy = <prediction common-name taxonomy>,
    },
}
```

If the selected dropdown value does not map to a real prediction, the disposition is still `confirmed`, but no selected prediction details are attached. This is the current behavior for confirming the `No predictions` item.

### Unsure

`Unsure` records the detection as unresolved.

The resulting detection disposition is:

```lua
{
    disposition = 'unsure',
    predictionConfidences = { ... },
}
```

### Not An Animal

`Not An Animal` records the detection as a false animal detection.

The resulting detection disposition is:

```lua
{
    disposition = 'not_an_animal',
    predictionConfidences = { ... },
}
```

### Not Listed

`Not Listed` allows the user to search for a species by common or scientific name. The user is presented with a child dialog containing an input box where they may type in a partial name.

As they type, a dropdown is populated with search results from the backend's `/search` endpoint. Each entry in the dropdown shows the bottom 3 levels of the taxonomic hierarchy.

For example, suppose `/search` returns this cormorant:

```json
    {
      "taxonomy": [
        "Animalia",
        "Chordata",
        "Vertebrata",
        "Aves",
        "Suliformes",
        "Phalacrocoracidae",
        "Nannopterum",
        "brasilianum"
      ],
      "taxonomy_rank_names": [
        "kingdom",
        "phylum",
        "subphylum",
        "class",
        "order",
        "family",
        "genus",
        "species"
      ],
      "taxonomy_common_names": [
        "Animals",
        "Chordates",
        "Vertebrates",
        "Birds",
        "Gannets, Cormorants, And Allies",
        "Cormorants And Shags",
        "American Cormorants",
        "Olivaceous Cormorant"
      ]
    }
```

The drop down item will show `Cormorants And Shags > American Cormorants > Olivaceous Cormorant`

When the current drop down item changes, either due to user selection or when new search results don't contain the current item, a label is updated to contain the full taxonomic hierarchy containing the common and scientific name, formatted as a tree as follows.

Example:

```text
Animals (Animalia)
└─► Chordates (Chordata)
   └─► Vertebrates (Vertebrata)
      └─► Birds (Aves)
         └─► Gannets, Cormorants, And Allies (Suliformes)
            └─► Cormorants And Shags (Phalacrocoracidae)
               └─► American Cormorants (Nannopterum)
                  └─► Olivaceous Cormorant (brasilianum)
```

The logic for sending `lat` & `lng` parameters to `/search` are the same as those used for including GPS coordinates with the `/identify` endpoint's request. 

The user can resolve the dialog with either the "Confirm" or "Unsure" buttons on this child dialog.

Confirm will resolve this detection using the manually selected drop down selection. The parent identification dialog for this detection resolves automatically.

The resulting detection disposition is:

```lua
{
    disposition = 'manual',
    predictionConfidences = { ... },
    selectedPrediction = {
        taxonomy = <selected taxonomy>,
        taxonomyRanks = <selected taxonomy ranks>,
        commonNameTaxonomy = <selected common-name taxonomy>,
    },
}
```

Manual detections are counted in the `manualCount` metadata field. They are not counted in `topSuggestionCount` or `otherSuggestionCount`.

Unsure will simply close the child dialog, leaving the user back at the identification dialog.

### Next Image

`Next Image` skips the rest of the detections for the current photo. No dispositions are returned for that photo, and the batch continues with the next selected image.

The dialog flow returns:

```lua
'next_image'
```

### Stop

`Stop` aborts the remaining batch after the current dialog closes.

The dialog flow returns:

```lua
'stop'
```

## Mode Logic

Mode and confidence-threshold behavior is documented in [Automatic Modes](automatic-modes.md).

## Processing Result

When all detections for the photo are processed, the dialog flow returns:

```lua
'continue', dispositions
```

`dispositions` contains one disposition per processed detection, in detection order.

Each disposition includes `predictionConfidences`, a list of every prediction confidence from the original detection. Confirmed detections also include the selected prediction index and selected prediction details when available. Manual detections include the selected taxonomy details from the search result.

If `Stop` or `Next Image` is selected, processing returns immediately and no later detections for that photo are reviewed.

## Error Cases

If a manual dialog is required but the Wild Catalog response does not include the matching detected image bytes, processing raises an error:

```text
Wild Catalog response is missing detected image <index>
```

If the temporary detected-image file cannot be created, processing raises an error:

```text
Unable to create temporary detected image: <error>
```
