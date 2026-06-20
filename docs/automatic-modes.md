# Automatic Modes

When more than one image is selected, display the following dialog to control how the processing proceeds. When only a single image is selected, process it in manual mode, even if it has been processed previously.


Confidence Threshold: X %
☑️ Reprocess Images

Mode:
🔘 Automatic Mode
🔘 Assisted Mode
🔘 Manual Mode

    [Cancel] [ Okay ]

## Confidence Threshold:

A textbox that accepts an integer between 0 and 100, inclusive. Used in the automatic and assisted modes logic. The default is 90%.

## Reprocess Images checkbox:

When checked, process all selected images. When unchecked, only process images new images (images without our custom metadata) and images with "Unsure" counts > 0 in their metadata. The default is unchecked.

## Mode radio button set

Only one mode can be selected at a time. The default is assisted mode.

### Automatic Mode

When the top prediction is greater than or equal to the confidence threshold, use it. Disposition as if the user had chosen the top prediction from the drop down and clicked Confirm on the manual dialog. When the top prediction is below the confidence threshold, disposition as if the user had clicked "Unsure"


### Assisted Mode

For each detection on an image:
    When the top prediction is greater than or equal to the confidence threshold, use it. Disposition as if the user had chosen the top prediction from the drop down and clicked Confirm on the manual dialog. When the top prediction is below the confidence threshold, display the manual dialog box for that detection only.

### Manual Mode

Prompt the user to disposition each and every detection on an image.

## Cancel Button

If the user cancels this dialog, abort all processing.

## Okay Button

In order to click Okay:
* if automatic or assisted mode is selected, the threshold must be valid.
* Exactly one mode must be selected.

When okay is clicked, proceed with detection.
