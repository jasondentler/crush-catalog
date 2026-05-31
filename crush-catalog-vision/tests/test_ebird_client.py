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

    class TestGetLocationInfo:

        def test_when_coordinates_are_valid_then_region_and_hotspot_are_returned(self, monkeypatch, ebird_client):
            def mock_get_region_from_coords(lat, lng):
                return "US-TX-167"

            def mock_get_nearest_hotspot(lat, lng):
                return {
                    "locId": "L123",
                    "locName": "Tiny Marsh",
                }

            monkeypatch.setattr(ebird_client, "_get_region_from_coords", mock_get_region_from_coords)
            monkeypatch.setattr(ebird_client, "_get_nearest_hotspot", mock_get_nearest_hotspot)

            location_info = ebird_client.get_location_info(29.5, -95.0, None)

            assert location_info == {
                "region_code": "US-TX-167",
                "hotspot_id": "L123",
                "hotspot_name": "Tiny Marsh",
            }

        def test_when_coordinates_are_missing_then_location_metadata_is_blank(self, monkeypatch, ebird_client):
            def mock_get_best_region_from_coords(lat, lng, location_fallback):
                raise AssertionError("Location metadata should not use fallback/default region lookup without GPS")

            monkeypatch.setattr(ebird_client, "_get_best_region_from_coords", mock_get_best_region_from_coords)

            location_info = ebird_client.get_location_info(None, None, "US-TX-167")

            assert location_info == {
                "region_code": None,
                "hotspot_id": None,
                "hotspot_name": None,
            }

        def test_when_gps_region_is_missing_then_hotspot_region_can_verify_region(self, monkeypatch, ebird_client):
            def mock_get_region_from_coords(lat, lng):
                return None

            def mock_get_nearest_hotspot(lat, lng):
                return {
                    "locId": "L123",
                    "locName": "Tiny Marsh",
                }

            def mock_get_region_from_hotspot_id(loc_id):
                return "US-TX-167"

            monkeypatch.setattr(ebird_client, "_get_region_from_coords", mock_get_region_from_coords)
            monkeypatch.setattr(ebird_client, "_get_nearest_hotspot", mock_get_nearest_hotspot)
            monkeypatch.setattr(ebird_client, "_get_region_from_hotspot_id", mock_get_region_from_hotspot_id)

            location_info = ebird_client.get_location_info(29.5, -95.0, "US-CA")

            assert location_info == {
                "region_code": "US-TX-167",
                "hotspot_id": "L123",
                "hotspot_name": "Tiny Marsh",
            }

    class TestLocationCaching:

        def test_best_region_cache_reuses_coordinates_within_30_meters(self, monkeypatch, ebird_client):
            ebird_client._best_region_cache = []
            call_count = 0

            def mock_get_region_from_coords(lat, lng):
                nonlocal call_count
                call_count += 1
                return "US-TX-167"

            monkeypatch.setattr(ebird_client, "_get_region_from_coords", mock_get_region_from_coords)

            first_region = ebird_client._get_best_region_from_coords(29.760400, -95.369800, None)
            second_region = ebird_client._get_best_region_from_coords(29.760500, -95.369800, None)

            assert first_region == "US-TX-167"
            assert second_region == "US-TX-167"
            assert call_count == 1

        def test_best_region_cache_misses_coordinates_farther_than_30_meters(self, monkeypatch, ebird_client):
            ebird_client._best_region_cache = []
            call_count = 0

            def mock_get_region_from_coords(lat, lng):
                nonlocal call_count
                call_count += 1
                return "US-TX-167"

            monkeypatch.setattr(ebird_client, "_get_region_from_coords", mock_get_region_from_coords)

            first_region = ebird_client._get_best_region_from_coords(29.760400, -95.369800, None)
            second_region = ebird_client._get_best_region_from_coords(29.761000, -95.369800, None)

            assert first_region == "US-TX-167"
            assert second_region == "US-TX-167"
            assert call_count == 2

        def test_nearest_hotspot_cache_reuses_coordinates_within_30_meters(self, monkeypatch, ebird_client):
            ebird_client._nearest_hotspot_cache = []
            call_count = 0

            def mock_get(endpoint, params=None, headers=None):
                nonlocal call_count
                call_count += 1
                return [{
                    "locId": "L123",
                    "locName": "Tiny Marsh",
                }]

            monkeypatch.setattr(ebird_client, "_get", mock_get)

            first_hotspot = ebird_client._get_nearest_hotspot(29.760400, -95.369800)
            second_hotspot = ebird_client._get_nearest_hotspot(29.760500, -95.369800)

            assert first_hotspot["locId"] == "L123"
            assert second_hotspot["locId"] == "L123"
            assert call_count == 1

        def test_nearest_hotspot_chooses_closest_result_not_first_result(self, monkeypatch, ebird_client):
            ebird_client._nearest_hotspot_cache = []

            def mock_get(endpoint, params=None, headers=None):
                return [
                    {
                        "locId": "far",
                        "locName": "Far Hotspot",
                        "lat": 30.134,
                        "lng": -95.668,
                    },
                    {
                        "locId": "near",
                        "locName": "Nearby Hotspot",
                        "lat": 29.720400,
                        "lng": -95.628300,
                    },
                ]

            monkeypatch.setattr(ebird_client, "_get", mock_get)

            hotspot = ebird_client._get_nearest_hotspot(29.720402, -95.628327)

            assert hotspot["locId"] == "near"

    class TestTaxonomyDriftAliases:

        def test_builds_aliases_from_old_taxonomy_versions(self, monkeypatch, ebird_client):
            ebird_client._taxonomy_versions_cache = None
            ebird_client._taxonomy_aliases_cache = None

            def mock_get(endpoint, params=None, headers=None):
                if endpoint.endswith("/ref/taxonomy/versions"):
                    return [
                        {"authorityVer": 2025.0, "latest": True},
                        {"authorityVer": 2024.0, "latest": False},
                    ]

                if params == {"fmt": "json"}:
                    return [
                        {
                            "speciesCode": "doccor",
                            "sciName": "Nannopterum auritum",
                        },
                        {
                            "speciesCode": "unchanged",
                            "sciName": "Sameus birdus",
                        },
                    ]

                if params == {"fmt": "json", "version": "2024"}:
                    return [
                        {
                            "speciesCode": "doccor",
                            "sciName": "Phalacrocorax auritus",
                        },
                        {
                            "speciesCode": "unchanged",
                            "sciName": "Sameus birdus",
                        },
                    ]

                raise AssertionError(f"Unexpected taxonomy request: {endpoint} {params}")

            monkeypatch.setattr(ebird_client, "_get", mock_get)

            aliases = ebird_client.get_scientific_name_aliases()

            assert aliases == {
                "phalacrocorax auritus": "nannopterum auritum",
            }

        def test_taxonomy_aliases_are_cached(self, monkeypatch, ebird_client):
            ebird_client._taxonomy_versions_cache = None
            ebird_client._taxonomy_aliases_cache = None
            call_count = 0

            def mock_get(endpoint, params=None, headers=None):
                nonlocal call_count
                call_count += 1
                if endpoint.endswith("/ref/taxonomy/versions"):
                    return [
                        {"authorityVer": 2025.0, "latest": True},
                        {"authorityVer": 2024.0, "latest": False},
                    ]

                if params == {"fmt": "json"}:
                    return [{"speciesCode": "doccor", "sciName": "Nannopterum auritum"}]

                if params == {"fmt": "json", "version": "2024"}:
                    return [{"speciesCode": "doccor", "sciName": "Phalacrocorax auritus"}]

                raise AssertionError(f"Unexpected taxonomy request: {endpoint} {params}")

            monkeypatch.setattr(ebird_client, "_get", mock_get)

            assert ebird_client.get_scientific_name_aliases()["phalacrocorax auritus"] == "nannopterum auritum"
            assert ebird_client.get_scientific_name_aliases()["phalacrocorax auritus"] == "nannopterum auritum"
            assert call_count == 3

        def test_cached_aliases_returns_empty_dict_before_preload(self, ebird_client):
            ebird_client._taxonomy_aliases_cache = None

            assert ebird_client.get_cached_scientific_name_aliases() == {}

        def test_cached_aliases_returns_preloaded_aliases(self, ebird_client):
            ebird_client._taxonomy_aliases_cache = {
                "phalacrocorax auritus": "nannopterum auritum",
            }

            assert ebird_client.get_cached_scientific_name_aliases() == {
                "phalacrocorax auritus": "nannopterum auritum",
            }

        def test_prefetch_scientific_name_aliases_runs_in_background(self, monkeypatch, ebird_client):
            ebird_client._taxonomy_aliases_cache = None
            ebird_client._taxonomy_aliases_loading = False
            started_threads = []

            class FakeThread:
                def __init__(self, target, name=None, daemon=None):
                    self.target = target
                    self.name = name
                    self.daemon = daemon
                    started_threads.append(self)

                def start(self):
                    self.target()

            monkeypatch.setattr("ebird_client.threading.Thread", FakeThread)
            monkeypatch.setattr(ebird_client, "get_scientific_name_aliases", lambda: {"old": "new"})

            ebird_client.prefetch_scientific_name_aliases()

            assert len(started_threads) == 1
            assert started_threads[0].name == "ebird-taxonomy-alias-prefetch"
            assert started_threads[0].daemon is True
            assert ebird_client._taxonomy_aliases_loading is False
