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

Lightroom supplies capture time, GPS, and optional camera identity in the
manifest alongside each original-file and preview declaration. Burst eligibility
requires a folder/date sequence partition, explicit fractional seconds in the
capture timestamp, known GPS context and a compatible ARW source. The partition
also incorporates the camera make and model when available; it is not a burst
identifier. A body serial is optional. The server performs temporal, appearance
and detection checks. Missing Lightroom GPS remains unknown and is not inferred
from the source file by the batch backend.

Embedded JPEGs are extracted only when requested. The original remains
available for fallback. One temporary preview per running plan is retained
until the next synchronous asset request or cleanup.

## Confirmation

Automatic confirmation requires the configured confidence threshold, canonical
taxonomy, detected geometry and no outstanding review flags. A classification
track must contain consecutive, distinct frames with a consistent canonical
taxon and coordinate space. Propagated predictions must point to an earlier
direct member of the same track.

The server may also supply a geometry-verified review track independently of
taxonomic confidence. In manual or assisted mode, the photographer can inspect
all member crops and choose one species or reject the tracked detection as not
an animal. Conflicting or unresolved predictions require an explicit decision,
not automatic acceptance. Manual choices apply only to members of that track;
other detections in the same photographs remain separate. Missing or invalid
geometry, discontinuities and representation changes prevent track grouping.
Individual review remains available for exceptions.

Candidate review groups (review_group_id) can span server processing windows
and include weak or nested detections, including multiple detections in one
photograph. The dialog identifies these as related regions and provides every
member crop in its selector. The photographer can reject the group or choose
one species explicitly; automatic acceptance is not authorized by the region
group. Only existing qualifying classification tracks may be auto-confirmed.
The dialog distinguishes detection counts from unique photograph counts.
Compatible preview and full-quality representations can share candidate
groups, but their individual crop geometry is preserved. Longer manual
encounters can extend beyond the inference window and time span.

The batch options expose optional detector confidence and minimum crop
detail floors, both disabled by default. The detail field is the normalized
score multiplied by 100 (5 means 0.05), not a probability. Suppressed preview
detections trigger full-quality reanalysis before final filtering. The
summary reports final filtered detections by reason and the number of review
dialogs. Diagnostic logs contain the actual review plan and grouping boundary
reasons. Filtered-only photographs remain untouched; a filter is not proof
that no animal is present.

Manual and assisted batches opt in to review images. The server captures small
JPEG crops from the actual analyzed representation, retaining them only within
the bounded session. Before review, the client fetches and caches crops
(up to 2048 requests and 64 MiB), checking frame ID, object index, coordinate
space and bounding box. Missing or mismatched evidence cannot authorize a
manual confirmation and unavailable evidence is reported in the batch summary.
The server session is released before the modal review begins; unsuccessful
cleanup is retried at exit. A session already absent is not a cleanup failure.
The local evidence cache is scoped to the batch review.

A frame is approved only when all detections have explicit dispositions and
at least one species is confirmed. Failed, negative-only, unresolved and changed
frames remain untouched. This is intentional because the existing reprocessing
writer can replace previously assigned Crush Catalog keywords.

## Identify Species integration

The multi-photo mode dialog provides three processing engines:

- Individual (existing): the original workflow and default.
- Batch (review only; no writes): performs preparation, inference and review
  without modifying the catalog.
- Batch (apply confirmed keywords): performs the same processing, then writes
  only completely approved frames.

The single-photo command remains unchanged. Batch exclusions, withheld
frames, failed batches and cleanup problems are reported rather than silently
falling through to the legacy writer. Diagnostic logs include preview
candidate counts and the server's available operation counts.

Each prepared plan's approved keyword assignments and plugin metadata are
written together in one public catalog write gate. Successful frame snapshots
are revalidated inside the gate before mutation, including evidence frames
withheld from writing. Lightroom documents rollback on callback errors.
The shared keyword cache prevents duplicate creation within the transaction.
Synonym refresh occurs in a separate gate because new keyword handles cannot
be read reliably before commit; synonym failures are reported without claiming
the committed photo assignments failed.

Cancellation discards a pending plan before its write gate. Earlier committed
plans remain committed; an in-progress write gate finishes or rolls back on
error. Review-only mode never invokes the writer.

## Remaining validation

Live Lightroom SDK metadata, subsecond capture precision, remote transport,
and actual catalog undo/rollback behavior must be verified before making batch
processing the default. Cropped photographs and virtual copies remain excluded
from the batch path; the existing individual engine remains available. No
Develop rendering is performed. Use review-only mode first.
