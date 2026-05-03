import os
import sys
import pytest

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "src")))

from ebird_client import EBirdClient
from identification import load_env_file

ENV_FILE = os.path.join(os.path.dirname(__file__), "..", ".env.test")

@pytest.fixture(scope="module")
def ebird_client_token():
    load_env_file(ENV_FILE)
    token = os.getenv("EBIRD_TOKEN")
    if not token:
        pytest.skip(f"EBIRD_TOKEN not set in environment file {ENV_FILE}")
    return EBirdClient(api_token=token)

@pytest.fixture(scope="module")
def ebird_client(ebird_client_token):
    return EBirdClient(api_token=ebird_client_token)

class TestEBirdClient:

    class TestGetBestRegionFromCoords:

        def test_when_coordinates_are_valid_then_region_is_returned(self, monkeypatch, ebird_client):
            # Mock the API call to return a specific region for given coordinates
            def mock_get_region_from_coords(lat, lng):
                return "US-CA"

            monkeypatch.setattr(ebird_client, "_get_region_from_coords", mock_get_region_from_coords)

            region = ebird_client._get_best_region_from_coords(34.0, -118.0, None)
            assert region == "US-CA"

        def test_when_coordinates_are_none_then_fallback_region_is_returned(self, monkeypatch, ebird_client):
            region = ebird_client._get_best_region_from_coords(None, None, "US-CA")
            assert region == "US-CA" 

        def test_when_fallback_is_whitespace_then_default_region_is_returned(self, monkeypatch, ebird_client):
            load_env_file(ENV_FILE)
            monkeypatch.setenv("DEFAULT_EBIRD_REGION", "US-NY")
            region = ebird_client._get_best_region_from_coords(None, None, "   ")
            assert region == "US-NY"

        def test_when_coordinates_are_not_in_a_region_then_nearest_hotspot_region_is_returned(self, monkeypatch, ebird_client):
            def mock_get_region_from_coords(lat, lng):
                return None

            def mock_get_nearest_hotspot_region(lat, lng):
                return "US-TX"

            monkeypatch.setattr(ebird_client, "_get_region_from_coords", mock_get_region_from_coords)
            monkeypatch.setattr(ebird_client, "_get_nearest_hotspot_region", mock_get_nearest_hotspot_region)

            region = ebird_client._get_best_region_from_coords(29.538217, -94.381486, None)
            assert region == "US-TX"

        def test_when_coordinates_are_none_and_fallback_is_none_then_default_region_is_returned(self, monkeypatch, ebird_client):
            load_env_file(ENV_FILE)
            monkeypatch.setenv("DEFAULT_EBIRD_REGION", "US-NY")
            region = ebird_client._get_best_region_from_coords(None, None, None)
            assert region == "US-NY"

        def test_when_coordinates_are_none_and_fallback_and_default_are_none_then_none_is_returned(self, monkeypatch, ebird_client):
            monkeypatch.delenv("DEFAULT_EBIRD_REGION", raising=False)
            region = ebird_client._get_best_region_from_coords(None, None, None)
            assert region is None

