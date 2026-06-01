import json
import os
import tempfile
from datetime import datetime
from http.server import BaseHTTPRequestHandler, HTTPServer

from crush_catalog_vision.api.config import DEFAULT_HOST, DEFAULT_PORT
from crush_catalog_vision.api.http import parse_multipart_form


def log_backend(message):
    """Write an immediately flushed backend log line for terminal and tee logs."""
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{timestamp}] {message}", flush=True)


def summarize_identification_result(result):
    """Return concise log lines describing an identify response."""
    detections = result.get("detections") or []
    lines = [
        (
            "Identify result "
            f"detections={len(detections)} "
            f"location_source={result.get('location_source')} "
            f"error={result.get('error') or 'none'}"
        )
    ]

    for index, detection in enumerate(detections, start=1):
        top_prediction = detection.get("top_prediction") or {}
        best_match = detection.get("best_match") or {}
        non_avian_prediction = detection.get("non_avian_prediction") or {}
        top_name = top_prediction.get("comName") or top_prediction.get("species") or "none"
        top_confidence = top_prediction.get("confidence")
        best_name = best_match.get("comName") or best_match.get("species") or "none"
        best_confidence = best_match.get("confidence")
        non_avian_name = non_avian_prediction.get("species") or non_avian_prediction.get("name") or "none"
        non_avian_confidence = non_avian_prediction.get("confidence")
        non_avian_aggregate_confidence = non_avian_prediction.get("aggregate_confidence")

        lines.append(
            (
                "Detection "
                f"index={index} "
                f"id={detection.get('detection_id')} "
                f"review_suggestion={detection.get('review_suggestion') or 'none'} "
                f"top={top_name} "
                f"top_confidence={format_confidence(top_confidence)} "
                f"best={best_name} "
                f"best_confidence={format_confidence(best_confidence)} "
                f"non_avian={non_avian_name} "
                f"non_avian_confidence={format_confidence(non_avian_confidence)} "
                f"non_avian_aggregate_confidence={format_confidence(non_avian_aggregate_confidence)}"
            )
        )

    return lines


def format_confidence(value):
    """Format a model confidence for backend log output."""
    if value is None:
        return "none"

    try:
        return f"{float(value):.3f}"
    except (TypeError, ValueError):
        return str(value)


def build_request_handler(dependencies):
    """Create a request handler class bound to backend dependencies."""
    class BirdIDRequestHandler(BaseHTTPRequestHandler):
        server_version = "BirdIDServer/0.1"

        def _send_json(self, payload, status=200):
            """Write a JSON response with the provided HTTP status."""
            body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            """Reject GET requests because the backend exposes POST endpoints only."""
            self._send_json({"error": "Method not allowed. Use POST to /identify."}, status=405)

        def do_POST(self):
            """Dispatch supported POST endpoints and validate request bodies."""
            if self.path == "/location":
                self._handle_location_lookup()
                return

            if self.path != "/identify":
                self._send_json({"error": "Endpoint not found."}, status=404)
                return

            content_type = self.headers.get("Content-Type", "")
            content_length = int(self.headers.get("Content-Length", 0))
            body_bytes = self.rfile.read(content_length)

            if not content_type.startswith("multipart/form-data"):
                self._send_json({"error": "Content-Type must be multipart/form-data"}, status=400)
                return

            boundary_str = content_type.split("boundary=")[1].encode()
            image_data, ebird_token, location_fallback, filename = self._parse_multipart(body_bytes, boundary_str)
            log_backend(
                "Identify request "
                f"filename={filename or 'unknown'} "
                f"bytes={len(image_data or b'')} "
                f"location_fallback={location_fallback or 'none'}"
            )

            if not image_data:
                log_backend("Identify request rejected: missing image_data")
                self._send_json({"error": "Missing required field: image_data."}, status=400)
                return
            if not ebird_token:
                log_backend("Identify request rejected: missing ebird_token")
                self._send_json({"error": "Missing required field: ebird_token."}, status=400)
                return

            try:
                suffix = os.path.splitext(filename or ".jpg")[1] or ".jpg"
                with tempfile.NamedTemporaryFile(delete=False, suffix=suffix) as tmp_file:
                    tmp_file.write(image_data)
                    actual_file_path = tmp_file.name
            except Exception as e:
                self._send_json({"error": f"Failed to save image: {str(e)}"}, status=400)
                return

            try:
                result = dependencies.identify_photo(
                    actual_file_path,
                    ebird_token,
                    model_name=None,
                    device=None,
                    location_fallback=location_fallback,
                )
                result["file_path"] = "uploaded_image.jpg"
                for line in summarize_identification_result(result):
                    log_backend(line)
                self._send_json(result)
            except Exception as e:
                log_backend(f"Identify request failed: {e}")
                self._send_json({"error": f"Unable to identify image: {str(e)}"})
            finally:
                try:
                    os.unlink(actual_file_path)
                except OSError:
                    pass

        def _handle_location_lookup(self):
            """Handle POST /location JSON requests."""
            content_type = self.headers.get("Content-Type", "")
            content_length = int(self.headers.get("Content-Length", 0))
            body_bytes = self.rfile.read(content_length)

            if not content_type.startswith("application/json"):
                self._send_json({"error": "Content-Type must be application/json"}, status=400)
                return

            try:
                payload = json.loads(body_bytes.decode("utf-8"))
                latitude = payload.get("latitude")
                longitude = payload.get("longitude")
                ebird_token = payload.get("ebird_token")
                location_fallback = payload.get("location_fallback")

                if not ebird_token:
                    self._send_json({"error": "Missing required field: ebird_token."}, status=400)
                    return

                latitude = float(latitude) if latitude is not None else None
                longitude = float(longitude) if longitude is not None else None
                result = dependencies.lookup_location(latitude, longitude, ebird_token, location_fallback=location_fallback)
                status = 400 if result.get("error") else 200
                self._send_json(result, status=status)
            except Exception as e:
                self._send_json({"error": f"Unable to look up location: {str(e)}"})

        def _parse_multipart(self, body, boundary):
            """Parse multipart form fields used by POST /identify."""
            return parse_multipart_form(body, boundary)

        def log_message(self, format, *args):
            """Silence the default HTTP request logging."""
            return

    return BirdIDRequestHandler


def run_server(handler_class, load_env_file, prime_ebird_cache, host: str = DEFAULT_HOST, port: int = DEFAULT_PORT):
    """Load configuration, warm caches, and run the HTTP server forever."""
    load_env_file()
    prime_ebird_cache()
    server_address = (host, port)
    httpd = HTTPServer(server_address, handler_class)
    log_backend(f"Bird ID backend listening on http://{host}:{port}")
    httpd.serve_forever()
