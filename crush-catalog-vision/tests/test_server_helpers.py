import os
import sys

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "src")))

from server import (
    build_response,
    build_local_species,
    enrich_predictions_with_taxonomy,
    filter_predictions_to_taxonomy,
    flatten_predictions,
    match_prediction_and_location_data,
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

    enrich_predictions_with_taxonomy(detections, species_by_scientific_name)

    assert detections[0]["predictions"][0]["comName"] == "Neotropic Cormorant"
    assert detections[0]["predictions"][0]["sciName"] == "Nannopterum brasilianum"
    assert detections[0]["predictions"][1]["comName"] == "Double-crested Cormorant"
    assert detections[0]["predictions"][1]["sciName"] == "Nannopterum auritum"


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


def test_resolve_location_fallback_prefers_request_value(monkeypatch):
    monkeypatch.setenv("DEFAULT_EBIRD_REGION", "US-TX-167")

    assert resolve_location_fallback("US-CA") == "US-CA"


def test_resolve_location_fallback_uses_default_region(monkeypatch):
    monkeypatch.setenv("DEFAULT_EBIRD_REGION", "US-TX-167")

    assert resolve_location_fallback(" ") == "US-TX-167"


def test_resolve_location_fallback_returns_none_when_no_region(monkeypatch):
    monkeypatch.delenv("DEFAULT_EBIRD_REGION", raising=False)

    assert resolve_location_fallback(None) is None


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
    )

    assert response["error"] == "No matching species were found for this photo."
    assert response["location_source"] == "gps"
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
