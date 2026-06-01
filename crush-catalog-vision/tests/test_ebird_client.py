import os
import sys

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "src")))

from ebird_client import EBirdClient
from crush_catalog_vision.clients.ebird_api import EBirdApiClient, EBirdCachingClient, EBirdLoggingClient
from crush_catalog_vision.services.ebird_location import EBirdLocationService
from crush_catalog_vision.services.ebird_taxonomy import EBirdTaxonomyService


class TestEBirdClient:
    def test_facade_delegates_location_lookup_to_location_service(self):
        class FakeLocationService:
            def get_location_info(self, lat, lng, location_fallback=None):
                return {
                    "region_code": "US-TX-167",
                    "hotspot_id": "L123",
                    "hotspot_name": "Tiny Marsh",
                }

        ebird = EBirdClient(api_token="token")
        ebird.location_service = FakeLocationService()

        assert ebird.get_location_info(29.5, -95.0, "US-TX-167") == {
            "region_code": "US-TX-167",
            "hotspot_id": "L123",
            "hotspot_name": "Tiny Marsh",
        }

    def test_facade_delegates_taxonomy_alias_prefetch_to_taxonomy_service(self):
        class FakeTaxonomyService:
            def __init__(self):
                self.prefetch_count = 0

            def prefetch_scientific_name_aliases(self):
                self.prefetch_count += 1

        ebird = EBirdClient(api_token="token")
        ebird.taxonomy_service = FakeTaxonomyService()

        ebird.prefetch_scientific_name_aliases()

        assert ebird.taxonomy_service.prefetch_count == 1


class TestEBirdLocationService:
    class TestGetBestRegionFromCoords:
        def test_when_coordinates_are_valid_then_region_is_returned(self, monkeypatch):
            location_service = EBirdLocationService(api=None)

            def mock_get_region_from_coords(lat, lng):
                return "US-CA"

            monkeypatch.setattr(location_service, "get_region_from_coords", mock_get_region_from_coords)

            region = location_service.get_best_region_from_coords(34.0, -118.0, None)
            assert region == "US-CA"

        def test_when_coordinates_are_none_then_fallback_region_is_returned(self):
            location_service = EBirdLocationService(api=None)

            region = location_service.get_best_region_from_coords(None, None, "US-CA")

            assert region == "US-CA"

        def test_when_fallback_is_whitespace_then_default_region_is_returned(self, monkeypatch):
            location_service = EBirdLocationService(api=None)
            monkeypatch.setenv("DEFAULT_EBIRD_REGION", "US-NY")

            region = location_service.get_best_region_from_coords(None, None, "   ")

            assert region == "US-NY"

        def test_when_coordinates_are_not_in_a_region_then_nearest_hotspot_region_is_returned(self, monkeypatch):
            location_service = EBirdLocationService(api=None)

            def mock_get_region_from_coords(lat, lng):
                return None

            def mock_get_nearest_hotspot_region(lat, lng):
                return "US-TX"

            monkeypatch.setattr(location_service, "get_region_from_coords", mock_get_region_from_coords)
            monkeypatch.setattr(location_service, "get_nearest_hotspot_region", mock_get_nearest_hotspot_region)

            region = location_service.get_best_region_from_coords(29.538217, -94.381486, None)
            assert region == "US-TX"

        def test_when_coordinates_are_none_and_fallback_is_none_then_default_region_is_returned(self, monkeypatch):
            location_service = EBirdLocationService(api=None)
            monkeypatch.setenv("DEFAULT_EBIRD_REGION", "US-NY")

            region = location_service.get_best_region_from_coords(None, None, None)

            assert region == "US-NY"

        def test_when_coordinates_are_none_and_fallback_and_default_are_none_then_none_is_returned(self, monkeypatch):
            location_service = EBirdLocationService(api=None)
            monkeypatch.delenv("DEFAULT_EBIRD_REGION", raising=False)

            region = location_service.get_best_region_from_coords(None, None, None)

            assert region is None

    class TestGetLocationInfo:
        def test_when_coordinates_are_valid_then_region_and_hotspot_are_returned(self, monkeypatch):
            location_service = EBirdLocationService(api=None)

            def mock_get_region_from_coords(lat, lng):
                return "US-TX-167"

            def mock_get_nearest_hotspot(lat, lng):
                return {
                    "locId": "L123",
                    "locName": "Tiny Marsh",
                }

            monkeypatch.setattr(location_service, "get_region_from_coords", mock_get_region_from_coords)
            monkeypatch.setattr(location_service, "get_nearest_hotspot", mock_get_nearest_hotspot)

            location_info = location_service.get_location_info(29.5, -95.0, None)

            assert location_info == {
                "region_code": "US-TX-167",
                "hotspot_id": "L123",
                "hotspot_name": "Tiny Marsh",
            }

        def test_when_coordinates_are_missing_then_location_metadata_is_blank(self, monkeypatch):
            location_service = EBirdLocationService(api=None)

            def mock_get_best_region_from_coords(lat, lng, location_fallback):
                raise AssertionError("Location metadata should not use fallback/default region lookup without GPS")

            monkeypatch.setattr(location_service, "get_best_region_from_coords", mock_get_best_region_from_coords)

            location_info = location_service.get_location_info(None, None, "US-TX-167")

            assert location_info == {
                "region_code": None,
                "hotspot_id": None,
                "hotspot_name": None,
            }

        def test_when_gps_region_is_missing_then_hotspot_region_can_verify_region(self, monkeypatch):
            location_service = EBirdLocationService(api=None)

            def mock_get_region_from_coords(lat, lng):
                return None

            def mock_get_nearest_hotspot(lat, lng):
                return {
                    "locId": "L123",
                    "locName": "Tiny Marsh",
                }

            def mock_get_region_from_hotspot_id(loc_id):
                return "US-TX-167"

            monkeypatch.setattr(location_service, "get_region_from_coords", mock_get_region_from_coords)
            monkeypatch.setattr(location_service, "get_nearest_hotspot", mock_get_nearest_hotspot)
            monkeypatch.setattr(location_service, "get_region_from_hotspot_id", mock_get_region_from_hotspot_id)

            location_info = location_service.get_location_info(29.5, -95.0, "US-CA")

            assert location_info == {
                "region_code": "US-TX-167",
                "hotspot_id": "L123",
                "hotspot_name": "Tiny Marsh",
            }

    class TestLocationCaching:
        def test_best_region_cache_reuses_coordinates_within_30_meters(self, monkeypatch):
            location_service = EBirdLocationService(api=None)
            call_count = 0

            def mock_get_region_from_coords(lat, lng):
                nonlocal call_count
                call_count += 1
                return "US-TX-167"

            monkeypatch.setattr(location_service, "get_region_from_coords", mock_get_region_from_coords)

            first_region = location_service.get_best_region_from_coords(29.760400, -95.369800, None)
            second_region = location_service.get_best_region_from_coords(29.760500, -95.369800, None)

            assert first_region == "US-TX-167"
            assert second_region == "US-TX-167"
            assert call_count == 1

        def test_best_region_cache_misses_coordinates_farther_than_30_meters(self, monkeypatch):
            location_service = EBirdLocationService(api=None)
            call_count = 0

            def mock_get_region_from_coords(lat, lng):
                nonlocal call_count
                call_count += 1
                return "US-TX-167"

            monkeypatch.setattr(location_service, "get_region_from_coords", mock_get_region_from_coords)

            first_region = location_service.get_best_region_from_coords(29.760400, -95.369800, None)
            second_region = location_service.get_best_region_from_coords(29.761000, -95.369800, None)

            assert first_region == "US-TX-167"
            assert second_region == "US-TX-167"
            assert call_count == 2

        def test_nearest_hotspot_cache_reuses_coordinates_within_30_meters(self):
            call_count = 0

            class FakeApi:
                def get_hotspots_near(self, lat, lng):
                    nonlocal call_count
                    call_count += 1
                    return [{
                        "locId": "L123",
                        "locName": "Tiny Marsh",
                    }]

            location_service = EBirdLocationService(api=FakeApi())

            first_hotspot = location_service.get_nearest_hotspot(29.760400, -95.369800)
            second_hotspot = location_service.get_nearest_hotspot(29.760500, -95.369800)

            assert first_hotspot["locId"] == "L123"
            assert second_hotspot["locId"] == "L123"
            assert call_count == 1

        def test_nearest_hotspot_chooses_closest_result_not_first_result(self):
            class FakeApi:
                def get_hotspots_near(self, lat, lng):
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

            location_service = EBirdLocationService(api=FakeApi())

            hotspot = location_service.get_nearest_hotspot(29.720402, -95.628327)

            assert hotspot["locId"] == "near"


class TestEBirdTaxonomyService:
    class TestTaxonomyDriftAliases:
        def test_builds_aliases_from_old_taxonomy_versions(self):
            class FakeApi:
                def get_taxonomy_versions(self):
                    return [
                        {"authorityVer": 2025.0, "latest": True},
                        {"authorityVer": 2024.0, "latest": False},
                    ]

                def get_taxonomy(self, version=None):
                    if version is None:
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

                    if version == 2024.0:
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

                    raise AssertionError(f"Unexpected taxonomy version: {version}")

            aliases = EBirdTaxonomyService(FakeApi()).get_scientific_name_aliases()

            assert aliases == {
                "phalacrocorax auritus": "nannopterum auritum",
            }

        def test_taxonomy_aliases_are_cached(self):
            call_count = 0

            class FakeApi:
                def get_taxonomy_versions(self):
                    nonlocal call_count
                    call_count += 1
                    return [
                        {"authorityVer": 2025.0, "latest": True},
                        {"authorityVer": 2024.0, "latest": False},
                    ]

                def get_taxonomy(self, version=None):
                    nonlocal call_count
                    call_count += 1
                    if version is None:
                        return [{"speciesCode": "doccor", "sciName": "Nannopterum auritum"}]

                    if version == 2024.0:
                        return [{"speciesCode": "doccor", "sciName": "Phalacrocorax auritus"}]

                    raise AssertionError(f"Unexpected taxonomy version: {version}")

            taxonomy_service = EBirdTaxonomyService(FakeApi())

            assert taxonomy_service.get_scientific_name_aliases()["phalacrocorax auritus"] == "nannopterum auritum"
            assert taxonomy_service.get_scientific_name_aliases()["phalacrocorax auritus"] == "nannopterum auritum"
            assert call_count == 3

        def test_cached_aliases_returns_empty_dict_before_preload(self):
            taxonomy_service = EBirdTaxonomyService(api=None)

            assert taxonomy_service.get_cached_scientific_name_aliases() == {}

        def test_cached_aliases_returns_preloaded_aliases(self):
            taxonomy_service = EBirdTaxonomyService(api=None)
            taxonomy_service._taxonomy_aliases_cache = {
                "phalacrocorax auritus": "nannopterum auritum",
            }

            assert taxonomy_service.get_cached_scientific_name_aliases() == {
                "phalacrocorax auritus": "nannopterum auritum",
            }

        def test_prefetch_scientific_name_aliases_runs_in_background(self, monkeypatch):
            taxonomy_service = EBirdTaxonomyService(api=None)
            started_threads = []

            class FakeThread:
                def __init__(self, target, name=None, daemon=None):
                    self.target = target
                    self.name = name
                    self.daemon = daemon
                    started_threads.append(self)

                def start(self):
                    self.target()

            monkeypatch.setattr("crush_catalog_vision.services.ebird_taxonomy.threading.Thread", FakeThread)
            monkeypatch.setattr(taxonomy_service, "get_scientific_name_aliases", lambda: {"old": "new"})

            taxonomy_service.prefetch_scientific_name_aliases()

            assert len(started_threads) == 1
            assert started_threads[0].name == "ebird-taxonomy-alias-prefetch"
            assert started_threads[0].daemon is True
            assert taxonomy_service._taxonomy_aliases_loading is False


class TestEBirdApiArchitecture:
    def test_simple_api_client_exposes_one_method_per_endpoint(self):
        calls = []

        class FakeResponse:
            status_code = 200

            def raise_for_status(self):
                pass

            def json(self):
                return {"ok": True}

        class FakeSession:
            def get(self, endpoint, params=None, headers=None):
                calls.append({"endpoint": endpoint, "params": params, "headers": headers})
                return FakeResponse()

        api = EBirdApiClient("token", base_url="https://example.test", session=FakeSession())

        assert api.get_taxonomy(version=2024.0) == {"ok": True}
        assert calls == [
            {
                "endpoint": "https://example.test/ref/taxonomy/ebird",
                "params": {"fmt": "json", "version": "2024"},
                "headers": {"x-ebirdapitoken": "token"},
            }
        ]

    def test_logging_and_caching_wrappers_forward_and_cache_endpoint_calls(self):
        calls = []

        class FakeApi:
            def get_taxonomy_versions(self):
                calls.append("get_taxonomy_versions")
                return [{"authorityVer": 2025.0, "latest": True}]

        api = EBirdCachingClient(EBirdLoggingClient(FakeApi()))

        assert api.get_taxonomy_versions() == [{"authorityVer": 2025.0, "latest": True}]
        assert api.get_taxonomy_versions() == [{"authorityVer": 2025.0, "latest": True}]
        assert calls == ["get_taxonomy_versions"]

    def test_caching_wrapper_attaches_session_to_inner_api_client(self):
        class FakeApi:
            def __init__(self):
                self.session = None

        class FakeSession:
            pass

        raw_api = FakeApi()
        session = FakeSession()

        EBirdCachingClient(EBirdLoggingClient(raw_api), session=session)

        assert raw_api.session is session
