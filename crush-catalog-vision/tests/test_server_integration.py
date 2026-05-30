import os
import sys
import time
import requests
import pytest
import threading
from http.server import HTTPServer

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "src")))

import server
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

    def test_identify_endpoint_ranks_local_cormorant_above_nonlocal_predictions(self, server_url, monkeypatch):
        """Use the cormorant sample as a regression test for local species ranking."""

        class FakeBirdIdentifier:
            def __init__(self, model_name=None, device=None):
                pass

            def predict_from_file(self, file_path, top_k=20):
                assert os.path.isfile(file_path)
                assert top_k == 20
                return [
                    {
                        "detection_id": 1,
                        "box": [0, 0, 100, 100],
                        "image": None,
                        "predictions": [
                            {"species": "Phalacrocorax brasilianus", "confidence": 0.95},
                            {"species": "Vireo gilvus", "confidence": 0.80},
                            {"species": "Nannopterum auritum", "confidence": 0.55},
                        ],
                    }
                ]

        class FakeEBirdClient:
            def __init__(self, api_token):
                pass

            def get_species_by_scientific_name(self):
                return {
                    "vireo gilvus": {
                        "comName": "Eastern Warbling Vireo",
                        "sciName": "Vireo gilvus",
                        "speciesCode": "warvir",
                        "familyComName": "Vireos, Shrike-Babblers, and Erpornis",
                        "familySciName": "Vireonidae",
                        "order": "Passeriformes",
                    },
                    "nannopterum brasilianum": {
                        "comName": "Neotropic Cormorant",
                        "sciName": "Nannopterum brasilianum",
                        "speciesCode": "neocor",
                        "familyComName": "Cormorants and Shags",
                        "familySciName": "Phalacrocoracidae",
                        "order": "Suliformes",
                    },
                    "nannopterum auritum": {
                        "comName": "Double-crested Cormorant",
                        "sciName": "Nannopterum auritum",
                        "speciesCode": "doccor",
                        "familyComName": "Cormorants and Shags",
                        "familySciName": "Phalacrocoracidae",
                        "order": "Suliformes",
                    },
                }

            def get_sightings_for_time_of_year(self, lat, lng, timestamp, location_fallback=None):
                return {
                    "region_code": "US-TX-167",
                    "dates": ["2026/04/02"],
                    "sightings": [
                        {
                            "comName": "Double-crested Cormorant",
                            "sciName": "Nannopterum auritum",
                            "speciesCode": "doccor",
                        },
                        {
                            "comName": "Neotropic Cormorant",
                            "sciName": "Nannopterum brasilianum",
                            "speciesCode": "neocor",
                        },
                        {
                            "comName": "Eastern Warbling Vireo",
                            "sciName": "Vireo gilvus",
                            "speciesCode": "warvir",
                        },
                    ],
                }

        monkeypatch.setattr(server, "BirdIdentifier", FakeBirdIdentifier)
        monkeypatch.setattr(server, "EBirdClient", FakeEBirdClient)
        monkeypatch.setattr(server, "display_image_from_file", lambda file_path: None)
        monkeypatch.setattr(server.TerminalImage, "display", lambda image: None)
        monkeypatch.setattr(server, "get_cr3_metadata", lambda file_path: {})
        monkeypatch.setattr(
            server,
            "extract_coordinates_and_time",
            lambda metadata: (29.7604, -95.3698, "2026:04:02 12:00:00"),
        )

        sample_image_path = os.path.abspath(
            os.path.join(os.path.dirname(__file__), "..", "..", "samples", "20260402-IMG_7906.jpg")
        )
        with open(sample_image_path, "rb") as image_file:
            files = {
                "image_data": ("20260402-IMG_7906.jpg", image_file, "image/jpeg"),
                "ebird_token": (None, "test_token"),
            }
            response = requests.post(
                f"{server_url}/identify",
                files=files,
            )

        assert response.status_code == 200
        data = response.json()
        best_match = data["detections"][0]["best_match"]
        alternatives = data["detections"][0]["alternatives"]

        assert best_match["comName"] == "Neotropic Cormorant"
        assert best_match["sciName"] == "Nannopterum brasilianum"
        assert best_match["is_local"] is True
        assert best_match["confidence"] > best_match["model_confidence"]
        assert alternatives[0]["comName"] == "Double-crested Cormorant"
        assert alternatives[0]["sciName"] == "Nannopterum auritum"

    def test_unknown_endpoint(self, server_url):
        """Test that unknown endpoints return 404."""
        response = requests.post(f"{server_url}/unknown")
        assert response.status_code == 404
        data = response.json()
        assert "error" in data
        assert "not found" in data["error"]
