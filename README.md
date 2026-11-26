![Crush Catalog: Identified. Tagged. Ticked](logo.png)

# Crush Catalog

Crush Catalog is a Lightroom Classic plugin backed by the local Wild Catalog animal-identification service. It processes selected original photo files, asks the backend to detect and identify animals, lets you confirm each detection, and writes Lightroom keywords for confirmed species.

## How It Works

- Select one or more photos in Lightroom Classic.
- Run `Library > Plug-in Extras > Identify Species`.
- The plugin automatically chooses how to send photos and available Lightroom metadata to the backend. Originals and their Develop history are preserved.
- The backend uses Wild Catalog detection and classification data to suggest animal species.
- Lightroom shows a confirmation dialog for each detection, including cropped previews when available.
- Confirmed species are written as Lightroom keywords under `Crush Catalog > Animals`, with birds grouped under `Birds`.

## License

Copyright 2026 Jason Dentler

Source code in this repository is licensed under the Apache License, Version 2.0. Sample images and other photographic assets are not licensed under Apache 2.0.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

   http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

## Credits and Third-Party Software

This project incorporates the following third-party library:

- **[JSON.lua](http://regex.info)** by Jeffrey Friedl.
  - **License:** [Creative Commons Attribution 3.0 (CC-BY 3.0)](http://creativecommons.org)
  - **Compliance:** The original copyright notice, web-page links, and `AUTHOR_NOTE` string are maintained within the source file located at `crush-catalog.lrplugin/JSON.lua`.

---
*This plugin is not affiliated with or endorsed by Adobe or iNaturalist.*


### Automatic file transport

No setup is required. When Crush Catalog and Wild Catalog run on the same
computer under the same user account, the plugin automatically attempts
verified direct file access. Originals may reside on the computer, external
drives, or mounted network shares (including NAS volumes). No storage-root
mappings, tokens, or NAS credentials are required. Read-only photo folders
are supported; the verification files live in a private local temporary directory.

When local verification is unavailable, including older servers, different
machines or users, the plugin automatically uploads the requested image.
Eligible Sony ARW previews can be extracted directly from the original by
Wild Catalog. Single-image requests continue using HTTP.

### Lightroom decode fallback

The negotiated `lightroom_render_fallback` protocol supports a separate JPEG
rendition if the original cannot be decoded. The adapter uses Lightroom
Classic's virtual-copy creation and selection-based removal APIs (as in
Photo Workflow MCP, which targets Lightroom Classic 15.1+). It creates a
temporary virtual copy, resets its develop settings using Lightroom, exports
it at full resolution in sRGB at maximum JPEG quality. Copies are queued
in the reserved top-level collection `Crush Catalog - Temporary Virtual Copies`,
created or reused on the first render request. JPEGs are removed after use;
virtual copies remain queued across batches. At run completion (including
cancellation or errors), select only the verified temporary virtual copies in
Library Grid, remove them from the catalog, verify removal by UUID, and delete
the empty collection. Unexpected virtual copies require individual confirmation
before catalog removal; Keep Copy (the default) and Cancel preserve them in
the catalog and remove them only from the temporary collection. Master photos
are removed only from the collection, never from the catalog. If cleanup cannot
be verified, retain the collection for recovery on a subsequent render run. Restore the user's active sources, selection, and module after
each render and final cleanup. Never export or reset the master photo.
Rendered coordinates remain separate from original coordinates. Older servers
continue using the original protocol.
