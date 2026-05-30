import json
import re
import tempfile
import os
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

from bird_identifier import BirdIdentifier
from ebird_client import EBirdClient
from cr3_handler import display_image_from_file, get_cr3_metadata, extract_coordinates_and_time
from identification import load_env_file, match_prediction_and_location_data
from terminal_image import TerminalImage

DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 8000
DEFAULT_MODEL_ENV = "BIRDER_MODEL"
DEFAULT_DEVICE_ENV = "COMPUTE_DEVICE"
DEFAULT_EBIRD_TOKEN_ENV = "EBIRD_TOKEN"
DEFAULT_EBIRD_REGION_ENV = "DEFAULT_EBIRD_REGION"

_IDENTIFIER_CACHE = {}

SCIENTIFIC_NAME_ALIASES = {
    "phalacrocorax auritus": "nannopterum auritum",
    "phalacrocorax brasilianus": "nannopterum brasilianum",
}


def get_identifier(model_name: str | None = None, device: str | None = None):
    resolved_model_name = model_name or os.getenv(DEFAULT_MODEL_ENV)
    resolved_device = device or os.getenv(DEFAULT_DEVICE_ENV, "cpu")
    cache_key = (resolved_model_name, resolved_device)

    if cache_key not in _IDENTIFIER_CACHE:
        _IDENTIFIER_CACHE[cache_key] = BirdIdentifier(
            model_name=resolved_model_name,
            device=resolved_device,
        )

    return _IDENTIFIER_CACHE[cache_key]


def _find_taxonomy_match(species, species_by_scientific_name):
    if not species:
        return None

    key = species.lower()
    taxonomy_match = species_by_scientific_name.get(key)
    if taxonomy_match:
        return taxonomy_match

    alias = SCIENTIFIC_NAME_ALIASES.get(key)
    if alias:
        return species_by_scientific_name.get(alias)

    return None


def flatten_predictions(detections):
    predictions = []
    for detection in detections:
        top_prediction = detection.get("top_prediction") or {}
        for pred in detection.get("predictions", []):
            predictions.append({
                **pred,
                "detection_id": detection.get("detection_id"),
                "detection_top_familySciName": top_prediction.get("familySciName"),
                "detection_top_familyComName": top_prediction.get("familyComName"),
                "detection_top_order": top_prediction.get("order"),
                "box": detection.get("box"),
            })
    return predictions


def enrich_predictions_with_taxonomy(detections, species_by_scientific_name):
    taxonomy_fields = (
        "comName",
        "sciName",
        "speciesCode",
        "familyComName",
        "familySciName",
        "order",
    )
    for detection in detections:
        for pred in detection.get("predictions", []):
            species = pred.get("species")
            taxonomy_match = _find_taxonomy_match(species, species_by_scientific_name)
            if taxonomy_match:
                for field in taxonomy_fields:
                    pred[field] = taxonomy_match.get(field)


def filter_predictions_to_taxonomy(detections):
    for detection in detections:
        detection["predictions"] = [
            pred
            for pred in detection.get("predictions", [])
            if pred.get("comName") and pred.get("sciName")
        ]
        detection["top_prediction"] = detection["predictions"][0] if detection["predictions"] else None


def parse_location_fallback(location_fallback: str) -> str | None:
    if not location_fallback:
        return None
    fallback = location_fallback.strip()
    if fallback == "":
        return None
    return fallback


def resolve_location_fallback(location_fallback: str | None) -> str | None:
    return parse_location_fallback(location_fallback) or parse_location_fallback(os.getenv(DEFAULT_EBIRD_REGION_ENV))


def build_local_species(sightings):
    if not sightings or not sightings.get("sightings"):
        return []

    local_species = []
    seen_species_codes = set()
    for sighting in sightings.get("sightings", []):
        species_code = sighting.get("speciesCode")
        if species_code in seen_species_codes:
            continue

        common_name = sighting.get("comName")
        scientific_name = sighting.get("sciName")
        if not common_name and not scientific_name:
            continue

        seen_species_codes.add(species_code)
        local_species.append({
            "comName": common_name,
            "sciName": scientific_name,
            "speciesCode": species_code,
        })

    return sorted(local_species, key=lambda item: (item.get("comName") or item.get("sciName") or "").lower())


def build_response(file_path: str, detections, matches, location_source: str, local_species=None, location_info=None):
    # Group matches by detection_id
    matches_by_detection = {}
    for match in matches:
        detection_id = match.get("detection_id")
        if detection_id is not None:
            if detection_id not in matches_by_detection:
                matches_by_detection[detection_id] = []
            matches_by_detection[detection_id].append(match)

    # Remove non-serializable image objects from detections and add per-detection matches
    serializable_detections = []
    detection_number = 0
    for detection in detections:
        detection_number = detection_number + 1
        TerminalImage.display(detection['image'])
        detection_copy = detection.copy()
        detection_copy.pop("image", None)  # Remove PIL Image object

        detection_id = detection.get("detection_id")
        detection_matches = matches_by_detection.get(detection_id, [])

        if detection_matches:
            best_match = detection_matches[0]
            common_name = best_match.get("comName")
            sci_name = best_match.get("sciName")
            confidence = best_match.get("confidence")
            print(f"🪶 Bird #{detection_number} is probably {common_name} ({sci_name}) - {confidence:.1%}")
            detection_copy["best_match"] = detection_matches[0]
            detection_copy["alternatives"] = detection_matches[1:] if len(detection_matches) > 1 else []
        else:
            print(f"🛑 No match for detected bird #{detection_number}")
            detection_copy["best_match"] = None
            detection_copy["alternatives"] = []

        serializable_detections.append(detection_copy)

    response = {
        "file_path": file_path,
        "location_source": location_source,
        "location": {
            "source": location_source,
            "region_code": location_info.get("region_code") if location_info else None,
            "hotspot_id": location_info.get("hotspot_id") if location_info else None,
            "hotspot_name": location_info.get("hotspot_name") if location_info else None,
        },
        "local_species": local_species or [],
        "detections": serializable_detections,
    }

    if not matches:
        response["error"] = "No matching species were found for this photo."

    return response

def identify_photo(file_path: str, ebird_token: str, model_name: str | None = None, device: str | None = None, location_fallback: str | None = None):
    if not Path(file_path).is_file():
        return {"error": f"File path does not exist: {file_path}"}

    display_image_from_file(file_path)

    identifier = get_identifier(model_name=model_name, device=device)
    ebird = EBirdClient(ebird_token or os.getenv(DEFAULT_EBIRD_TOKEN_ENV))

    detections = identifier.predict_from_file(file_path, top_k=20)
    metadata = get_cr3_metadata(file_path)
    latitude, longitude, timestamp = extract_coordinates_and_time(metadata)
    location_source = "gps"

    if latitude is None or longitude is None:
        location_source = "fallback"
        location_fallback = resolve_location_fallback(location_fallback)
        if not location_fallback:
            return {"error": "Missing GPS coordinates and no location fallback was provided."}

    sightings = ebird.get_sightings_for_time_of_year(latitude, longitude, timestamp, location_fallback=location_fallback)
    location_info = ebird.get_location_info(latitude, longitude, location_fallback=location_fallback) if hasattr(ebird, "get_location_info") else {}

    enrich_predictions_with_taxonomy(detections, ebird.get_species_by_scientific_name())
    filter_predictions_to_taxonomy(detections)
    predictions = flatten_predictions(detections)
    matches = match_prediction_and_location_data(predictions, sightings)
    local_species = build_local_species(sightings)

    return build_response(file_path, detections, matches, location_source, local_species, location_info)


class BirdIDRequestHandler(BaseHTTPRequestHandler):
    server_version = "BirdIDServer/0.1"

    def _send_json(self, payload, status=200):
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        # All GET requests are not allowed
        self._send_json({"error": "Method not allowed. Use POST to /identify."}, status=405)

    def do_POST(self):
        if self.path != "/identify":
            self._send_json({"error": "Endpoint not found."}, status=404)
            return

        # Parse multipart/form-data
        content_type = self.headers.get("Content-Type", "")
        content_length = int(self.headers.get("Content-Length", 0))
        body_bytes = self.rfile.read(content_length)

        # Check if this is multipart/form-data
        if content_type.startswith("multipart/form-data"):
            # Extract boundary
            boundary_str = content_type.split("boundary=")[1].encode()
            image_data, ebird_token, location_fallback, filename = self._parse_multipart(body_bytes, boundary_str)

            if not image_data:
                self._send_json({"error": "Missing required field: image_data."}, status=400)
                return
            if not ebird_token:
                self._send_json({"error": "Missing required field: ebird_token."}, status=400)
                return
        else:
            self._send_json({"error": "Content-Type must be multipart/form-data"}, status=400)
            return

        # Save image to temporary file using the uploaded filename extension
        try:
            suffix = os.path.splitext(filename or ".jpg")[1] or ".jpg"
            with tempfile.NamedTemporaryFile(delete=False, suffix=suffix) as tmp_file:
                tmp_file.write(image_data)
                actual_file_path = tmp_file.name
        except Exception as e:
            self._send_json({"error": f"Failed to save image: {str(e)}"}, status=400)
            return

        try:
            result = identify_photo(actual_file_path, ebird_token, model_name=None, device=None, location_fallback=location_fallback)
            result['file_path'] = "uploaded_image.jpg"
            self._send_json(result)
        except Exception as e:
            self._send_json({"error": f"Unable to identify image: {str(e)}"})
        finally:
            # Clean up temporary file
            try:
                os.unlink(actual_file_path)
            except:
                pass

    def _parse_multipart(self, body, boundary):
        """Parse multipart/form-data and extract fields."""
        image_data = None
        ebird_token = None
        location_fallback = None
        filename = None

        # Split by boundary
        parts = body.split(b"--" + boundary)

        for part in parts:
            if not part or part == b"--" or part == b"--\r\n":
                continue

            # Split headers from content
            if b"\r\n\r\n" in part:
                headers_section, content = part.split(b"\r\n\r\n", 1)
            else:
                continue

            # Remove trailing boundary marker and whitespace
            content = content.rstrip(b"\r\n")

            # Parse headers to find field name
            headers_text = headers_section.decode('utf-8', errors='ignore')

            if 'name="image_data"' in headers_text:
                image_data = content
                match = re.search(r'filename="([^"]+)"', headers_text)
                if match:
                    filename = match.group(1)
            elif 'name="ebird_token"' in headers_text:
                ebird_token = content.decode('utf-8').strip()
            elif 'name="location_fallback"' in headers_text:
                location_fallback = content.decode('utf-8').strip()

        return image_data, ebird_token, location_fallback, filename

    def log_message(self, format, *args):
        return


def run_server(host: str = DEFAULT_HOST, port: int = DEFAULT_PORT):
    load_env_file()
    server_address = (host, port)
    httpd = HTTPServer(server_address, BirdIDRequestHandler)
    print(f"Bird ID backend listening on http://{host}:{port}")
    httpd.serve_forever()


if __name__ == "__main__":
    host = os.getenv("BIRD_ID_HOST", DEFAULT_HOST)
    port = int(os.getenv("BIRD_ID_PORT", DEFAULT_PORT))
    run_server(host, port)
