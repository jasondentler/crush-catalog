# Crush Catalog Vision

A helper project for bird identification using JPEG and CR3 image data, Birder classification, and eBird sighting data. The Lightroom plugin sends temporary JPEG renditions to this backend; the backend and CLI can also process CR3 files directly.

## Features

- Load Canon CR3 raw images and JPEG files
- Detect birds with YOLO and classify species using Birder
- Extract GPS and timestamp metadata via ExifTool
- Query eBird for historic sightings by location and date
- Enrich model predictions with eBird taxonomy data, including common and scientific names
- Match model predictions with eBird location data
- Run as a local CLI workflow or a lightweight HTTP backend

## Requirements

- Python 3.11 or newer
- `exiftool` installed and on `PATH`
- Optional GPU support via `COMPUTE_DEVICE` (e.g. `cuda`)

## Install

From the `crush-catalog-vision` folder:

```bash
cd /Users/jasondentler/projects/crush-catalog/crush-catalog-vision
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -e '.[tests]'
```

The project dependencies are defined in `pyproject.toml`. The `tests` extra installs pytest for local test runs.

## Environment Variables

Create a `.env` file in `crush-catalog-vision/` or export these variables in your shell.

```env
EBIRD_TOKEN=your_ebird_api_token
BIRDER_MODEL=hieradet_d_small_dino-v2-inat21
COMPUTE_DEVICE=mps
DEFAULT_EBIRD_REGION=US-TX-167
BIRD_ID_HOST=127.0.0.1
BIRD_ID_PORT=8000
```

- `EBIRD_TOKEN` - required for eBird API access
- `BIRDER_MODEL` - model name used by `birder.load_pretrained_model`
- `COMPUTE_DEVICE` - `cpu` or GPU device string
- `DEFAULT_EBIRD_REGION` - optional fallback region code when GPS and location fallback are unavailable
- `BIRD_ID_HOST` / `BIRD_ID_PORT` - override server binding host and port

The project loads `.env` automatically using `load_env_file()`.

### How to obtain and choose values

- `EBIRD_TOKEN`
  - Sign in or create an account at https://ebird.org.
  - Request an API key from the eBird API page: https://ebird.org/api/keygen.
  - Copy the generated key into `EBIRD_TOKEN`.

- `BIRDER_MODEL`
  - Use a valid model name supported by the `birder` package installed in your environment.
  - `hieradet_d_small_dino-v2-inat21` was used in testing. It worked well at the time.
  - Recommended approach: start with Birder's default pretrained bird classifier, or a general bird species model provided by your Birder version.
  - If you are unsure, leave this blank and let `birder.load_pretrained_model()` use its default model.

- `COMPUTE_DEVICE`
  - `cpu` - use the CPU only.
  - `cuda` - use the default NVIDIA CUDA GPU.
  - `cuda:0`, `cuda:1`, etc. - select a specific NVIDIA GPU.
  - `mps` - use Apple Silicon GPU support on macOS.

- `DEFAULT_EBIRD_REGION`
  - Use an eBird region code such as `US-TX-167` (Galveston county, Texas). You may also use entire states or provinces, though this really causes the eBird API service to struggle. Be kind to them.
  - Find valid region codes from the eBird API documentation or by looking up your state/province region on eBird like from this page: [https://ebird.org/region/US-TX-187](https://ebird.org/region/US-TX-187).
  - This value is only used when GPS metadata is missing and `location_fallback` is not provided.
  - If left blank and no location can be derived, the app cannot determine a region for eBird sightings and will fail to fetch location-based data.

- `BIRD_ID_HOST` / `BIRD_ID_PORT`
  - Local-only example: `BIRD_ID_HOST=127.0.0.1`, `BIRD_ID_PORT=8000`
  - Bind all interfaces example: `BIRD_ID_HOST=0.0.0.0`, `BIRD_ID_PORT=8080`
  - If `BIRD_ID_PORT` is blank, the default port `8000` is used.

## CLI Usage

### Run the sample workflow

```bash
python src/main.py
```

This CLI does the following:

- Loads environment variables
- Initializes `BirdIdentifier` and `EBirdClient`
- Tests eBird connectivity with sample requests
- Scans a hard-coded folder for `.CR3` files
- Identifies birds and matches predictions with eBird sightings

### Customize the scan path

`src/main.py` currently scans a local path such as:

```python
folder_path = Path("~/Pictures/2026/2026-04/2026-04-19").expanduser()
```

Update that path to point at your own photo folder.

## HTTP Backend

Start the backend server with:

```bash
python src/server.py
```

By default, the server listens on `http://127.0.0.1:8000`.

### Server behavior

- Accepts `POST /identify`
- Requires `Content-Type: multipart/form-data`
- Accepts fields:
  - `image_data` - binary image payload
  - `ebird_token` - eBird API token
  - `location_fallback` - optional fallback region code when GPS is unavailable
- Filters classification predictions through eBird taxonomy and returns common/scientific names when available

### Example request

```bash
curl -X POST http://127.0.0.1:8000/identify \
  -F 'image_data=@samples/20260419-DA8A0090.jpg' \
  -F 'ebird_token=YOUR_EBIRD_TOKEN' \
  -F 'location_fallback=US-TX-167'
```

### Example response

The server returns JSON containing:

- `file_path`
- `location_source` (`gps` or `fallback`)
- `detections`, where each detection can include:
  - `detection_id`
  - `box`
  - `image_width`
  - `image_height`
  - `predictions`
  - `best_match`
  - `alternatives`
- `error` when applicable

Example shape:

```json
{
  "file_path": "uploaded_image.jpg",
  "location_source": "fallback",
  "detections": [
    {
      "detection_id": 1,
      "box": [0.0, 0.0, 2048.0, 1365.0],
      "image_width": 2048,
      "image_height": 1365,
      "best_match": {
        "comName": "Western Barn Owl",
        "sciName": "Tyto alba",
        "speciesCode": "brnowl",
        "confidence": 0.93
      },
      "alternatives": []
    }
  ]
}
```

## Project Structure

- `src/server.py` - lightweight HTTP server and `/identify` endpoint
- `src/main.py` - sample CLI workflow for batch processing
- `src/bird_identifier.py` - loads YOLO detector and Birder classification model
- `src/ebird_client.py` - wrapper for eBird API calls and caching
- `src/cr3_handler.py` - reads CR3 metadata with ExifTool and rawpy
- `src/identification.py` - matching logic and CLI reporting

## Sample Images

This repository includes example photos in the `samples/` folder:

- `samples/20260419-DA8A0090.jpg`
- `samples/20260419-DA8A5083.jpg`
- `samples/20260419-DA8A5151.jpg`
- `samples/20260419-DA8A5506.jpg`
- `samples/20260419-DA8A7718.jpg`

You can use these files directly with the backend test `curl` command above.

## CR3 and metadata details

- `BirdIdentifier` supports CR3 raw files by extracting thumbnails or postprocessing raw data with `rawpy`
- The Lightroom plugin exports temporary JPEG renditions and sends those JPEGs to the backend
- `cr3_handler.py` uses `exiftool` to extract GPS coordinates and timestamps
- If GPS is missing, the server and CLI can use `location_fallback` or `DEFAULT_EBIRD_REGION`
- Predictions are enriched with eBird taxonomy data before matching, so responses can include both common names (`comName`) and scientific names (`sciName`)

## Testing

Run the test suite from `crush-catalog-vision`:

```bash
python -m pytest tests
```

## Notes

- The backend stores an eBird response cache in `ebird_cache.sqlite` using `requests-cache`
- `yolo11n.pt` will be downloaded on first use.
- `BirdIdentifier` uses a YOLO detector to crop bird regions before classification
