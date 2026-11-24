# Batch identification

## Preparation

The batch path operates on selected original files and preserves the order of
the Lightroom selection. Each manifest has at most 256 frames; exclusions and
the frame limit split the selection into separate plans. Paths, camera serials,
directory names, and catalog edit snapshots stay local. Camera and sequence
identifiers are scoped to a batch.

The original-file representation does not include Lightroom Develop edits.
Cropped photographs and virtual copies are explicitly excluded from this path
pending develop-aware handling. Before resolving assets and collecting review
decisions, the client compares file size, modification time, catalog edit
metadata, capture metadata and source identity against the local snapshot.
This is not a cryptographic develop digest.

Burst eligibility requires camera make/model/serial, a folder/date sequence
partition, explicit fractional seconds in the capture timestamp, known GPS
context and a compatible ARW source. The folder/date partition is not a burst
identifier: the server performs temporal, appearance and detection checks.
Missing Lightroom GPS does not prove absence from the original EXIF.

Embedded JPEGs are extracted only when requested. The original remains
available for fallback. One temporary preview per running plan is retained
until the next synchronous asset request or cleanup.

## Confirmation

Automatic confirmation requires the configured confidence threshold, canonical
taxonomy, detected geometry and no outstanding review flags. Assisted and manual
review can confirm an eligible track's common top taxon once. A track must
contain consecutive, distinct frames with a consistent canonical taxon and
coordinate space. Propagated predictions must point to an earlier direct member
of the same track. Conflicting, uncertain or incomplete evidence is not eligible
for a track-wide decision.

The review dialog shows actual image crops, direct evidence frame names and
the members of a track. A different species or other exception can be handled
individually. The existing individual confirmation dialog displays provenance
and uncertainty for batch objects.

Manual and assisted batches opt in to review images. The server captures small
JPEG crops from the actual analyzed representation, retaining them only within
the bounded session. The client fetches crops on demand after finalization and
checks frame ID, object index, coordinate space and bounding box. Missing or
mismatched evidence cannot authorize a manual confirmation. The session is
released after the review callback, including cancellation and errors.

A frame is approved only when all detections have explicit dispositions and
at least one species is confirmed. Failed, negative-only, unresolved and changed
frames remain untouched. This is intentional because the existing reprocessing
writer can replace previously assigned Crush Catalog keywords.

## Integration boundary

Preparation and confirmation return results and approved dispositions; they
do not write keywords, change Develop settings or modify originals. The existing
Identify Species command is not yet wired to this workflow. Live SDK metadata,
remote transport, keyword transaction/rollback behavior and edited/virtual-copy
handling require integration validation.
