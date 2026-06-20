# Automatic Modes

When more than one image is selected, display the following dialog to control how the processing proceeds. When only a single image is selected, process it in manual mode, even if it has been processed previously.


Images to Process:
◉ Only New images
○ New + Unsure
○ Reprocess All Images

Mode:
○ Automatic Mode
◉ Assisted Mode
○ Manual Mode

Confidence Threshold: X %

    [Cancel] [ Okay ]

## Images to Process radio button set

Only one option can be selected at a time. This set is displayed in its own labeled group so that it is visually distinct from the Mode radio button set. The default is **Only New images**.

### Only New images

Process only images whose detection count metadata is empty or null. An image with a detection count of zero is not new and is skipped.

### New + Unsure

Process all new images, plus any image whose Unsure count metadata is greater than zero.

### Reprocess All Images

Process every selected image regardless of its metadata.

## Mode radio button set

Only one mode can be selected at a time. The default is assisted mode.

### Automatic Mode

When the top prediction is greater than or equal to the confidence threshold, use it. Disposition as if the user had chosen the top prediction from the drop down and clicked Confirm on the manual dialog. When the top prediction is below the confidence threshold, disposition as if the user had clicked "Unsure"


### Assisted Mode

For each detection on an image:
    When the top prediction is greater than or equal to the confidence threshold, use it. Disposition as if the user had chosen the top prediction from the drop down and clicked Confirm on the manual dialog. When the top prediction is below the confidence threshold, display the manual dialog box for that detection only.

### Manual Mode

Prompt the user to disposition each and every detection on an image.

## Confidence Threshold

This is the last input on the dialog. It is a textbox that accepts an integer between 0 and 100, inclusive and is used by the automatic and assisted mode logic. The default is 90%.

## Cancel Button

If the user cancels this dialog, abort all processing.

## Okay Button

In order to click Okay:
* if automatic or assisted mode is selected, the threshold must be valid.
* Exactly one image processing option must be selected.
* Exactly one mode must be selected.

When okay is clicked, proceed with detection.
