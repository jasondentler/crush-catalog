import os
from crush_catalog_vision.clients.ebird_client import EBirdClient
from crush_catalog_vision.images.cr3_handler import get_cr3_metadata, extract_coordinates_and_time
from crush_catalog_vision.images.terminal_image import TerminalImage
from crush_catalog_vision.vision.bird_identifier import BirdIdentifier

TOP_K = 20
LOCAL_SPECIES_CONFIDENCE_BOOST = 0.05
SAME_FAMILY_CONFIDENCE_BOOST = 0.40
NON_LOCAL_CONFIDENCE_PENALTY = 0.25


def load_env_file(filepath: str = ".env"):
    """Manually reads an .env file and injects its variables into os.environ."""
    if not os.path.exists(filepath):
        return

    with open(filepath, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            # Skip comments and empty lines
            if not line or line.startswith("#"):
                continue
            if "=" in line:
                key, value = line.split("=", 1)
                os.environ[key.strip()] = value.strip()


def normalize_name(name: str) -> str:
    """Lowercases the string and strips hyphens to match Birder's class array."""
    return name.lower().replace("-", " ")


def _is_same_family_as_top_prediction(prediction):
    """Return whether a prediction shares the top prediction's family."""
    family = normalize_name(prediction.get("familySciName", "") or prediction.get("familyComName", ""))
    top_family = normalize_name(
        prediction.get("detection_top_familySciName", "") or prediction.get("detection_top_familyComName", "")
    )
    return family and top_family and family == top_family


def _score_prediction(prediction, local_species_codes):
    """Adjust model confidence using local occurrence and family context."""
    model_confidence = prediction.get("confidence", 0)
    species_code = prediction.get("speciesCode")
    is_local = species_code in local_species_codes
    adjusted_confidence = model_confidence

    if is_local:
        adjusted_confidence = min(1.0, adjusted_confidence + LOCAL_SPECIES_CONFIDENCE_BOOST)
        if _is_same_family_as_top_prediction(prediction):
            adjusted_confidence = min(1.0, adjusted_confidence + SAME_FAMILY_CONFIDENCE_BOOST)
    else:
        adjusted_confidence = adjusted_confidence * NON_LOCAL_CONFIDENCE_PENALTY

    return {
        **prediction,
        "model_confidence": model_confidence,
        "confidence": adjusted_confidence,
        "is_local": is_local,
    }


def match_prediction_and_location_data(predictions, sightings):
    """Rank predictions after applying local eBird sighting context."""
    if not predictions:
        return []

    local_sightings = sightings.get("sightings", []) if sightings else []
    local_species_codes = set()
    if local_sightings:
        local_species_codes = {
            sighting.get("speciesCode")
            for sighting in local_sightings
            if sighting.get("speciesCode")
        }

    matches = [
        _score_prediction(prediction, local_species_codes)
        for prediction in predictions
    ]

    matches = sorted(matches, key=lambda x: x.get("confidence", 0), reverse=True)

    print(f"Ranked {len(matches)} predictions against {len(local_sightings)} local sightings.")

    return matches


def identify(cr3_path: str, identifier: BirdIdentifier, ebird: EBirdClient):
    """Run the CLI-oriented identification workflow for a CR3 file."""
    print(f"🖼️ {cr3_path}")

    detected_birds = identifier.predict_from_file(cr3_path, TOP_K)

    if not detected_birds:
        print("🛑 No birds detected in the photo.")
        return
    
    print(f"🪶 Detected {len(detected_birds)} birds.")

    cr3_metadata = get_cr3_metadata(cr3_path)
    latitude, longitude, timestamp = extract_coordinates_and_time(cr3_metadata)

    sightings = ebird.get_sightings_for_time_of_year(latitude, longitude, timestamp)
    region_code = sightings.get("region_code") if sightings else None
    dates = sightings.get("dates") if sightings else None

    if not sightings:
        print("🛑 No sightings data available for this location and time of year.")
        return
    
    if not sightings.get("sightings"):
        print(f"🛑 No sightings found for region code {region_code} and date(s) {', '.join(dates) if dates else 'unknown'}.")
        return
    
    for detected_bird in detected_birds:
        print(f"🪶 Bird #{detected_bird['detection_id']}")

        matches = match_prediction_and_location_data(detected_bird.get("predictions", []), sightings)

        if not matches or matches[0].get("confidence", 0) < 0.5:
            TerminalImage.display(detected_bird['image'])

        if matches:
            match = matches[0]
            data = {
                "confidence": match["confidence"],
                "comName": match["comName"],
                "sciName": match["sciName"],
            }

            print(f"  ✅ Confidence: {data['confidence']:.1%}")
            print(f"  🧬 Scientific Name: {data['sciName']}")
            print(f"  🪶 Common Name: {data['comName']}")

            if data["confidence"] < 0.5:
                # Show other high-confidence matches as alternatives
                alternatives = matches[1:4]  # Show top 3 alternatives
                for alt in alternatives:
                    print(f"    🧳 {alt['species']} {alt['confidence']:.1%}")

            print()
        else:
            if detected_bird.get("predictions"):
                print("  🛑 Failed to identify the bird species in the photo.")
                print("    🧳 None of the predictions matched any eBird sightings")
                print(f"       for location {region_code} and date(s) {', '.join(dates) if dates else 'unknown'}.")
                print("    🧳 Top predictions (without considering location data):")
                for pred in detected_bird.get("predictions", []):
                    print(f"    🧳 {pred['species']} {pred['confidence']:.1%}")
                print()
            else:
                print("  🛑 Failed to identify the bird species in the photo and no predictions were available.")
                print()
