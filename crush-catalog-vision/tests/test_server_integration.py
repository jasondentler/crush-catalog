import os
import sys
import time
import requests
import pytest
import threading
from http.server import HTTPServer

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "src")))

from server import BirdIDRequestHandler, DEFAULT_HOST


class TestServerIntegration:
    """Integration tests for the Bird ID server."""

    @pytest.fixture(scope="class")
    def server_url(self):
        """Start the server in a background thread for testing."""

        server = HTTPServer((DEFAULT_HOST, 0), BirdIDRequestHandler)
        host, port = server.server_address

        server_thread = threading.Thread(target=server.serve_forever)
        server_thread.daemon = True
        server_thread.start()

        # Wait for server to start
        time.sleep(2)

        yield f"http://{host}:{port}"

        server.shutdown()
        server.server_close()
        server_thread.join(timeout=2)

    def test_server_starts_and_responds(self, server_url):
        """Test that the server starts and responds to requests."""
        response = requests.get(f"{server_url}/")
        # Server should return 404 for non-POST requests or unknown endpoints
        assert response.status_code == 405  # Method not allowed

    def test_identify_endpoint_requires_post(self, server_url):
        """Test that /identify requires POST method."""
        response = requests.get(f"{server_url}/identify")
        assert response.status_code == 405

    def test_identify_endpoint_wrong_content_type(self, server_url):
        """Test that /identify rejects JSON."""
        payload = {"ebird_token": "test"}
        response = requests.post(
            f"{server_url}/identify",
            json=payload
        )
        assert response.status_code == 400
        data = response.json()
        assert "error" in data
        assert "multipart/form-data" in data["error"]

    def test_identify_endpoint_missing_image_data(self, server_url):
        """Test that /identify requires image_data."""
        files = {
            "ebird_token": (None, "test_token")
        }
        response = requests.post(
            f"{server_url}/identify",
            files=files
        )
        assert response.status_code == 400
        data = response.json()
        assert "error" in data
        assert "image_data" in data["error"]

    def test_identify_endpoint_missing_ebird_token(self, server_url):
        """Test that /identify requires ebird_token."""
        files = {
            "image_data": ("photo.jpg", b"fake jpeg data")
        }
        response = requests.post(
            f"{server_url}/identify",
            files=files
        )
        assert response.status_code == 400
        data = response.json()
        assert "error" in data
        assert "ebird_token" in data["error"]

    def test_identify_endpoint_with_image_data(self, server_url):
        """Test that /identify accepts image_data in multipart form."""
        sample_image_path = os.path.abspath(
            os.path.join(os.path.dirname(__file__), "..", "..", "samples", "20260419-DA8A0090.jpg")
        )
        with open(sample_image_path, "rb") as image_file:
            files = {
                "image_data": ("photo.jpg", image_file, "image/jpeg"),
                "ebird_token": (None, "test_token")
            }
            response = requests.post(
                f"{server_url}/identify",
                files=files
            )

        # Should return 200 but with an error in the response if the image can't be processed.
        assert response.status_code == 200
        data = response.json()
        assert "error" in data or "detections" in data

    def test_unknown_endpoint(self, server_url):
        """Test that unknown endpoints return 404."""
        response = requests.post(f"{server_url}/unknown")
        assert response.status_code == 404
        data = response.json()
        assert "error" in data
        assert "not found" in data["error"]
