import os
import sys

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "src")))

import server
from server import (
    annotate_non_avian_detections,
    build_response,
    build_local_species,
    enrich_non_avian_predictions_with_common_names,
    enrich_predictions_with_taxonomy,
    filter_predictions_to_taxonomy,
    flatten_predictions,
    get_identifier,
    prediction_is_non_avian,
    lookup_location,
    match_prediction_and_location_data,
    prime_ebird_cache,
    resolve_location_fallback,
)
from bird_identifier import _box_containment, _box_iou, _remove_duplicate_boxes


def test_flatten_predictions_returns_prediction_entries():
    detections = [
        {
            "detection_id": 1,
            "box": [10.0, 20.0, 100.0, 120.0],
            "predictions": [
                {"species": "House Sparrow", "confidence": 0.95},
                {"species": "American Robin", "confidence": 0.05},
            ],
        }
    ]

    flat = flatten_predictions(detections)
    assert len(flat) == 2
    assert flat[0]["detection_id"] == 1
    assert flat[0]["box"] == [10.0, 20.0, 100.0, 120.0]
    assert flat[0]["species"] == "House Sparrow"


def test_enrich_predictions_with_taxonomy_adds_common_and_scientific_names():
    detections = [
        {
            "predictions": [
                {"species": "Tyto alba", "confidence": 0.92},
                {"species": "Unknown bird", "confidence": 0.08},
            ],
        }
    ]
    species_by_scientific_name = {
        "tyto alba": {
            "comName": "Barn Owl",
            "sciName": "Tyto alba",
            "speciesCode": "brnowl",
            "familyComName": "Barn-Owls",
            "familySciName": "Tytonidae",
            "order": "Strigiformes",
        }
    }

    enrich_predictions_with_taxonomy(detections, species_by_scientific_name)

    assert detections[0]["predictions"][0]["comName"] == "Barn Owl"
    assert detections[0]["predictions"][0]["sciName"] == "Tyto alba"
    assert detections[0]["predictions"][0]["speciesCode"] == "brnowl"
    assert detections[0]["predictions"][0]["familySciName"] == "Tytonidae"
    assert detections[0]["predictions"][0]["order"] == "Strigiformes"
    assert "comName" not in detections[0]["predictions"][1]


def test_enrich_predictions_with_taxonomy_does_not_load_aliases_for_current_taxonomy_match():
    detections = [
        {
            "predictions": [
                {"species": "Tyto alba", "confidence": 0.92},
            ],
        }
    ]
    species_by_scientific_name = {
        "tyto alba": {
            "comName": "Barn Owl",
            "sciName": "Tyto alba",
            "speciesCode": "brnowl",
        }
    }

    def fail_if_loaded():
        raise AssertionError("Taxonomy drift aliases should be loaded lazily")

    enrich_predictions_with_taxonomy(detections, species_by_scientific_name, scientific_name_aliases=fail_if_loaded)

    assert detections[0]["predictions"][0]["comName"] == "Barn Owl"


def test_enrich_predictions_with_taxonomy_uses_scientific_name_aliases():
    detections = [
        {
            "predictions": [
                {"species": "Phalacrocorax brasilianus", "confidence": 0.94},
                {"species": "Phalacrocorax auritus", "confidence": 0.01},
            ],
        }
    ]
    species_by_scientific_name = {
        "nannopterum brasilianum": {
            "comName": "Neotropic Cormorant",
            "sciName": "Nannopterum brasilianum",
            "speciesCode": "neocor",
            "familySciName": "Phalacrocoracidae",
            "order": "Suliformes",
        },
        "nannopterum auritum": {
            "comName": "Double-crested Cormorant",
            "sciName": "Nannopterum auritum",
            "speciesCode": "doccor",
            "familySciName": "Phalacrocoracidae",
            "order": "Suliformes",
        },
    }
    aliases = {
        "phalacrocorax brasilianus": "nannopterum brasilianum",
        "phalacrocorax auritus": "nannopterum auritum",
    }

    enrich_predictions_with_taxonomy(detections, species_by_scientific_name, scientific_name_aliases=aliases)

    assert detections[0]["predictions"][0]["comName"] == "Neotropic Cormorant"
    assert detections[0]["predictions"][0]["sciName"] == "Nannopterum brasilianum"
    assert detections[0]["predictions"][1]["comName"] == "Double-crested Cormorant"
    assert detections[0]["predictions"][1]["sciName"] == "Nannopterum auritum"


def test_enrich_predictions_with_taxonomy_uses_ebird_taxonomy_drift_aliases():
    detections = [
        {
            "predictions": [
                {"species": "Oldus birdus", "confidence": 0.94},
            ],
        }
    ]
    species_by_scientific_name = {
        "newus birdus": {
            "comName": "Renamed Bird",
            "sciName": "Newus birdus",
            "speciesCode": "renbir",
            "familySciName": "Exampleidae",
            "order": "Passeriformes",
        },
    }
    aliases = {
        "oldus birdus": "newus birdus",
    }

    enrich_predictions_with_taxonomy(detections, species_by_scientific_name, scientific_name_aliases=aliases)

    assert detections[0]["predictions"][0]["comName"] == "Renamed Bird"
    assert detections[0]["predictions"][0]["sciName"] == "Newus birdus"


def test_identify_photo_uses_cached_ebird_taxonomy_aliases_without_hardcoded_mapping(monkeypatch, tmp_path):
    assert "oldus birdus" not in server.SCIENTIFIC_NAME_ALIAS_OVERRIDES

    class FakeBirdIdentifier:
        def __init__(self, model_name=None, device=None):
            pass

        def predict_from_file(self, file_path, top_k=20):
            return [
                {
                    "detection_id": 1,
                    "box": [0, 0, 100, 100],
                    "image": None,
                    "predictions": [
                        {"species": "Oldus birdus", "confidence": 0.94},
                    ],
                }
            ]

    class FakeEBirdClient:
        def __init__(self, api_token):
            pass

        def get_cached_scientific_name_aliases(self):
            return {"oldus birdus": "newus birdus"}

        def get_species_by_scientific_name(self):
            return {
                "newus birdus": {
                    "comName": "Renamed Bird",
                    "sciName": "Newus birdus",
                    "speciesCode": "renbir",
                    "familySciName": "Exampleidae",
                    "order": "Passeriformes",
                },
            }

        def get_sightings_for_time_of_year(self, lat, lng, timestamp, location_fallback=None):
            return {
                "region_code": "US-TX-167",
                "dates": ["2026/04/02"],
                "sightings": [
                    {
                        "comName": "Renamed Bird",
                        "sciName": "Newus birdus",
                        "speciesCode": "renbir",
                    },
                ],
            }

        def get_location_info(self, lat, lng, location_fallback=None):
            return {"region_code": "US-TX-167", "hotspot_id": None, "hotspot_name": None}

    image_path = tmp_path / "photo.jpg"
    image_path.write_bytes(b"fake image bytes")

    server._IDENTIFIER_CACHE.clear()
    server._EBIRD_CLIENT_CACHE.clear()
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

    result = server.identify_photo(str(image_path), "token")

    best_match = result["detections"][0]["best_match"]
    assert best_match["comName"] == "Renamed Bird"
    assert best_match["sciName"] == "Newus birdus"
    assert best_match["is_local"] is True


def test_filter_predictions_to_taxonomy_removes_non_bird_predictions():
    detections = [
        {
            "predictions": [
                {"species": "Tyto alba", "comName": "Western Barn Owl", "sciName": "Tyto alba"},
                {"species": "Gekko gecko"},
                {"species": "Hippopotamus amphibius"},
            ],
            "top_prediction": {"species": "Tyto alba"},
        }
    ]

    filter_predictions_to_taxonomy(detections)

    assert detections[0]["predictions"] == [
        {"species": "Tyto alba", "comName": "Western Barn Owl", "sciName": "Tyto alba"}
    ]
    assert detections[0]["top_prediction"]["species"] == "Tyto alba"


def test_prediction_is_non_avian_uses_inaturalist_taxon_class_and_confidence():
    prediction = {
        "class_label": "08952_Animalia_Chordata_Mammalia_Carnivora_Canidae_Canis_lupus",
        "species": "Canis lupus",
        "confidence": 0.20,
    }

    assert prediction_is_non_avian(prediction) is True


def test_prediction_is_non_avian_ignores_birds():
    prediction = {
        "class_label": "04200_Animalia_Chordata_Aves_Strigiformes_Tytonidae_Tyto_alba",
        "species": "Tyto alba",
        "confidence": 0.98,
    }

    assert prediction_is_non_avian(prediction) is False


def test_annotate_non_avian_detections_requires_high_aggregate_non_avian_confidence():
    prediction = {
        "class_label": "08952_Animalia_Chordata_Mammalia_Carnivora_Canidae_Canis_lupus",
        "species": "Canis lupus",
        "confidence": 0.40,
    }
    detections = [{"predictions": [prediction], "top_prediction": prediction}]

    annotate_non_avian_detections(detections)

    assert "review_suggestion" not in detections[0]


def test_annotate_non_avian_detections_preserves_signal_before_taxonomy_filtering():
    detections = [
        {
            "predictions": [
                {
                    "class_label": "08952_Animalia_Chordata_Mammalia_Carnivora_Canidae_Canis_lupus",
                    "species": "Canis lupus",
                    "confidence": 0.60,
                },
                {
                    "class_label": "04679_Animalia_Chordata_Mammalia_Carnivora_Felidae_Felis_catus",
                    "species": "Felis catus",
                    "confidence": 0.33,
                },
                {
                    "class_label": "04200_Animalia_Chordata_Aves_Strigiformes_Tytonidae_Tyto_alba",
                    "species": "Tyto alba",
                    "confidence": 0.02,
                    "comName": "Western Barn Owl",
                    "sciName": "Tyto alba",
                },
            ],
        }
    ]

    annotate_non_avian_detections(detections)
    filter_predictions_to_taxonomy(detections)

    assert detections[0]["review_suggestion"] == "not_a_bird"
    assert detections[0]["non_avian_prediction"]["species"] == "Canis lupus"
    assert detections[0]["non_avian_prediction"]["aggregate_confidence"] == 0.93
    assert detections[0]["non_avian_prediction"]["taxonKingdom"] == "Animalia"
    assert detections[0]["non_avian_prediction"]["taxonClass"] == "Mammalia"
    assert detections[0]["non_avian_prediction"]["taxonPath"] == [
        {"rank": "kingdom", "scientificName": "Animalia"},
        {"rank": "phylum", "scientificName": "Chordata"},
        {"rank": "class", "scientificName": "Mammalia"},
        {"rank": "order", "scientificName": "Carnivora"},
        {"rank": "family", "scientificName": "Canidae"},
        {"rank": "genus", "scientificName": "Canis"},
        {"rank": "species", "scientificName": "Canis lupus"},
    ]
    assert detections[0]["top_prediction"]["species"] == "Tyto alba"


def test_annotate_non_avian_detections_adds_plant_lineage_for_keyword_routing():
    prediction = {
        "class_label": "12345_Plantae_Tracheophyta_Magnoliopsida_Malpighiales_Salicaceae_Populus_nigra",
        "species": "Populus nigra",
        "confidence": 0.96,
    }
    detections = [{"predictions": [prediction], "top_prediction": prediction}]

    annotate_non_avian_detections(detections)

    assert detections[0]["review_suggestion"] == "not_a_bird"
    assert detections[0]["non_avian_prediction"]["taxonKingdom"] == "Plantae"
    assert detections[0]["non_avian_prediction"]["taxonClass"] == "Magnoliopsida"
    assert detections[0]["non_avian_prediction"]["taxonPath"][0]["scientificName"] == "Plantae"
    assert detections[0]["non_avian_prediction"]["taxonPath"][-1]["scientificName"] == "Populus nigra"


def test_enrich_non_avian_predictions_with_common_names_uses_scientific_name_lookup():
    detections = [
        {
            "non_avian_prediction": {
                "species": "Canis lupus familiaris",
                "taxonKingdom": "Animalia",
                "taxonClass": "Mammalia",
                "taxonPath": [
                    {"rank": "kingdom", "scientificName": "Animalia"},
                    {"rank": "class", "scientificName": "Mammalia"},
                    {"rank": "species", "scientificName": "Canis lupus familiaris"},
                ],
                "confidence": 0.93,
            },
        },
        {
            "non_avian_prediction": {
                "species": "Unknownus example",
                "confidence": 0.80,
            },
        },
    ]

    enrich_non_avian_predictions_with_common_names(
        detections,
        lambda scientific_name: {
            "Canis lupus familiaris": "Domestic Dog",
            "Animalia": "Animals",
            "Mammalia": "Mammals",
        }.get(scientific_name),
    )

    assert detections[0]["non_avian_prediction"]["commonName"] == "Domestic Dog"
    assert detections[0]["non_avian_prediction"]["taxonKingdomName"] == "Animals"
    assert detections[0]["non_avian_prediction"]["taxonClassName"] == "Mammals"
    assert detections[0]["non_avian_prediction"]["taxonPath"] == [
        {"rank": "kingdom", "scientificName": "Animalia", "englishName": "Animals"},
        {"rank": "class", "scientificName": "Mammalia", "englishName": "Mammals"},
        {"rank": "species", "scientificName": "Canis lupus familiaris", "englishName": "Domestic Dog"},
    ]
    assert "commonName" not in detections[1]["non_avian_prediction"]


def test_enrich_non_avian_predictions_with_common_names_adds_non_animal_kingdom_name():
    detections = [
        {
            "non_avian_prediction": {
                "species": "Populus nigra",
                "taxonKingdom": "Plantae",
                "taxonClass": "Magnoliopsida",
                "taxonPath": [
                    {"rank": "kingdom", "scientificName": "Plantae"},
                    {"rank": "class", "scientificName": "Magnoliopsida"},
                    {"rank": "species", "scientificName": "Populus nigra"},
                ],
            },
        },
    ]

    enrich_non_avian_predictions_with_common_names(
        detections,
        lambda scientific_name: {
            "Populus nigra": "Black Poplar",
            "Plantae": "Plants",
            "Magnoliopsida": "Dicots",
        }.get(scientific_name),
    )

    assert detections[0]["non_avian_prediction"]["commonName"] == "Black Poplar"
    assert detections[0]["non_avian_prediction"]["taxonKingdomName"] == "Plants"
    assert detections[0]["non_avian_prediction"]["taxonClassName"] == "Dicots"


def test_enrich_non_avian_predictions_with_common_names_keeps_not_bird_when_lookup_fails():
    detections = [
        {
            "review_suggestion": "not_a_bird",
            "non_avian_prediction": {
                "species": "Canis lupus familiaris",
                "confidence": 0.93,
            },
        },
    ]

    def fail_lookup(scientific_name):
        raise RuntimeError("archive unavailable")

    enrich_non_avian_predictions_with_common_names(detections, fail_lookup)

    assert detections[0]["review_suggestion"] == "not_a_bird"
    assert "commonName" not in detections[0]["non_avian_prediction"]


def test_resolve_location_fallback_prefers_request_value(monkeypatch):
    monkeypatch.setenv("DEFAULT_EBIRD_REGION", "US-TX-167")

    assert resolve_location_fallback("US-CA") == "US-CA"


def test_resolve_location_fallback_uses_default_region(monkeypatch):
    monkeypatch.setenv("DEFAULT_EBIRD_REGION", "US-TX-167")

    assert resolve_location_fallback(" ") == "US-TX-167"


def test_resolve_location_fallback_returns_none_when_no_region(monkeypatch):
    monkeypatch.delenv("DEFAULT_EBIRD_REGION", raising=False)

    assert resolve_location_fallback(None) is None


def test_lookup_location_returns_backend_location_payload(monkeypatch):
    class FakeEBirdClient:
        def get_location_info(self, latitude, longitude, location_fallback=None):
            assert latitude == 29.5
            assert longitude == -95.0
            return {
                "region_code": "US-TX-201",
                "hotspot_id": "L123",
                "hotspot_name": "City Park",
            }

    monkeypatch.setattr(server, "get_ebird_client", lambda token: FakeEBirdClient())

    assert lookup_location(29.5, -95.0, "token") == {
        "location": {
            "source": "gps",
            "region_code": "US-TX-201",
            "hotspot_id": "L123",
            "hotspot_name": "City Park",
        }
    }


def test_get_identifier_reuses_model_for_same_configuration(monkeypatch):
    created_identifiers = []

    class FakeBirdIdentifier:
        def __init__(self, model_name=None, device=None):
            self.model_name = model_name
            self.device = device
            created_identifiers.append(self)

    server._IDENTIFIER_CACHE.clear()
    monkeypatch.setattr(server, "BirdIdentifier", FakeBirdIdentifier)

    first = get_identifier(model_name="test-model", device="cpu")
    second = get_identifier(model_name="test-model", device="cpu")
    third = get_identifier(model_name="test-model", device="other-device")

    assert first is second
    assert third is not first
    assert len(created_identifiers) == 2
    assert first.model_name == "test-model"
    assert first.device == "cpu"


def test_get_ebird_client_prefetches_taxonomy_aliases(monkeypatch):
    created_clients = []

    class FakeEBirdClient:
        def __init__(self, api_token):
            self.api_token = api_token
            self.prefetch_count = 0
            created_clients.append(self)

        def prefetch_scientific_name_aliases(self):
            self.prefetch_count += 1

    server._EBIRD_CLIENT_CACHE.clear()
    monkeypatch.setattr(server, "EBirdClient", FakeEBirdClient)

    first = server.get_ebird_client("token")
    second = server.get_ebird_client("token")

    assert first is second
    assert len(created_clients) == 1
    assert first.prefetch_count == 1


def test_prime_ebird_cache_uses_env_token(monkeypatch):
    clients = []

    class FakeEBirdClient:
        def __init__(self, api_token):
            self.api_token = api_token
            self.prefetch_count = 0
            clients.append(self)

        def prefetch_scientific_name_aliases(self):
            self.prefetch_count += 1

    server._EBIRD_CLIENT_CACHE.clear()
    monkeypatch.setenv("EBIRD_TOKEN", "env-token")
    monkeypatch.setattr(server, "EBirdClient", FakeEBirdClient)

    client = prime_ebird_cache()

    assert client.api_token == "env-token"
    assert len(clients) == 1
    assert clients[0].prefetch_count == 1


def test_prime_ebird_cache_skips_when_env_token_is_missing(monkeypatch):
    server._EBIRD_CLIENT_CACHE.clear()
    monkeypatch.delenv("EBIRD_TOKEN", raising=False)

    client = prime_ebird_cache()

    assert client is None
    assert server._EBIRD_CLIENT_CACHE == {}


def test_build_local_species_returns_sorted_unique_species():
    sightings = {
        "sightings": [
            {"comName": "Double-crested Cormorant", "sciName": "Nannopterum auritum", "speciesCode": "doccor"},
            {"comName": "Anhinga", "sciName": "Anhinga anhinga", "speciesCode": "anhing"},
            {"comName": "Double-crested Cormorant", "sciName": "Nannopterum auritum", "speciesCode": "doccor"},
        ]
    }

    local_species = build_local_species(sightings)

    assert local_species == [
        {"comName": "Anhinga", "sciName": "Anhinga anhinga", "speciesCode": "anhing"},
        {"comName": "Double-crested Cormorant", "sciName": "Nannopterum auritum", "speciesCode": "doccor"},
    ]


def test_match_prediction_and_location_data_matches_common_and_scientific_names():
    predictions = [
        {
            "species": "House Sparrow",
            "confidence": 0.75,
            "comName": "House Sparrow",
            "sciName": "Passer domesticus",
            "speciesCode": "houspa",
        },
        {
            "species": "Passer domesticus",
            "confidence": 0.65,
            "comName": "House Sparrow",
            "sciName": "Passer domesticus",
            "speciesCode": "houspa",
        },
    ]
    sightings = {
        "region_code": "US-CA",
        "dates": ["2024-06-01", "2024-06-30"],
        "sightings": [
            {"comName": "House Sparrow", "sciName": "Passer domesticus", "speciesCode": "houspa"}
        ]
    }

    matches = match_prediction_and_location_data(predictions, sightings)

    assert len(matches) == 2
    assert matches[0]["comName"] == "House Sparrow"
    assert matches[1]["sciName"] == "Passer domesticus"
    assert matches[0]["is_local"] is True
    assert matches[0]["model_confidence"] == 0.75


def test_match_prediction_and_location_data_boosts_local_same_family_matches():
    predictions = [
        {
            "species": "Distant Cormorant",
            "confidence": 0.95,
            "comName": "Distant Cormorant",
            "sciName": "Phalacrocorax distantus",
            "speciesCode": "discor",
            "familySciName": "Phalacrocoracidae",
            "detection_top_familySciName": "Phalacrocoracidae",
        },
        {
            "species": "Double-crested Cormorant",
            "confidence": 0.55,
            "comName": "Double-crested Cormorant",
            "sciName": "Nannopterum auritum",
            "speciesCode": "doccor",
            "familySciName": "Phalacrocoracidae",
            "detection_top_familySciName": "Phalacrocoracidae",
        },
    ]
    sightings = {
        "sightings": [
            {
                "comName": "Double-crested Cormorant",
                "sciName": "Nannopterum auritum",
                "speciesCode": "doccor",
            }
        ]
    }

    matches = match_prediction_and_location_data(predictions, sightings)

    assert matches[0]["comName"] == "Double-crested Cormorant"
    assert matches[0]["is_local"] is True
    assert matches[0]["confidence"] > matches[0]["model_confidence"]
    assert matches[1]["comName"] == "Distant Cormorant"
    assert matches[1]["is_local"] is False
    assert matches[1]["confidence"] < matches[1]["model_confidence"]


def test_build_response_includes_error_when_no_best_match():
    response = build_response(
        file_path="/tmp/photo.cr3",
        detections=[],
        matches=[],
        location_source="gps",
        location_info={
            "region_code": "US-TX-167",
            "hotspot_id": "L123",
            "hotspot_name": "Tiny Marsh",
        },
    )

    assert response["error"] == "No matching species were found for this photo."
    assert response["location_source"] == "gps"
    assert response["location"] == {
        "source": "gps",
        "region_code": "US-TX-167",
        "hotspot_id": "L123",
        "hotspot_name": "Tiny Marsh",
    }
    assert response["file_path"] == "/tmp/photo.cr3"
    assert response["local_species"] == []


def test_box_containment_detects_nested_duplicate_boxes():
    smaller_box = [2883.59, 2069.34, 3234.30, 2380.20]
    larger_box = [2878.69, 2067.78, 3239.15, 2506.43]

    assert _box_iou(smaller_box, larger_box) < 0.85
    assert _box_containment(smaller_box, larger_box) >= 0.85


def test_remove_duplicate_boxes_filters_nested_boxes():
    boxes = [
        [2883.59, 2069.34, 3234.30, 2380.20],
        [2878.69, 2067.78, 3239.15, 2506.43],
    ]

    assert _remove_duplicate_boxes(boxes) == [boxes[0]]
