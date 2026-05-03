import os
import sys

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "src")))

from server import flatten_predictions, match_prediction_and_location_data, build_response


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


def test_match_prediction_and_location_data_matches_common_and_scientific_names():
    predictions = [
        {"species": "House Sparrow", "confidence": 0.75},
        {"species": "Passer domesticus", "confidence": 0.65},
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
