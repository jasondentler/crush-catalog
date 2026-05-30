![Crush Catalog: Identified. Tagged. Ticked](logo.png)

# Crush Catalog

Crush Catalog is a Lightroom Classic plugin backed by a local Python bird-identification service. It exports selected photos as temporary JPEGs, asks the local backend to detect and identify birds, lets you confirm each detection, and writes Lightroom keywords for confirmed species.

## How It Works

- Select one or more photos in Lightroom Classic.
- Run `Library > Plug-in Extras > Identify Bird`.
- The plugin exports temporary JPEG renditions and sends them to the local backend.
- The backend uses YOLO, Birder, and eBird sightings/taxonomy data to suggest species.
- Lightroom shows a confirmation dialog for each detection, including cropped bird previews when available.
- Confirmed birds are written as Lightroom keywords under `Crush Catalog > Animals > Birds`.

## Components

- `crush-catalog.lrplugin/` - Lightroom Classic plugin written in Lua.
- `crush-catalog-vision/` - local Python backend for detection, classification, and eBird matching.

See [crush-catalog-vision/README.md](crush-catalog-vision/README.md) for backend setup, environment variables, server usage, and tests.

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

Sample images and photographic assets are not included in the Apache 2.0 license. See NOTICE.txt for terms.

This project incorporates the following third-party library:

- **[JSON.lua](http://regex.info)** by Jeffrey Friedl.
  - **License:** [Creative Commons Attribution 3.0 (CC-BY 3.0)](http://creativecommons.org)
  - **Compliance:** The original copyright notice, web-page links, and `AUTHOR_NOTE` string are maintained within the source file located at `crush-catalog.lrplugin/JSON.lua`.

---
*This plugin is not affiliated with or endorsed by Adobe, Cornell University, eBird, or iNaturalist.*
