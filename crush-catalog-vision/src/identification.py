import os
import json
from pathlib import Path
from bird_identifier import BirdIdentifier
from ebird_client import EBirdClient
from cr3_handler import get_cr3_metadata, extract_coordinates_and_time
from terminal_image import TerminalImage

TOP_K = 20


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


def match_prediction_and_location_data(predictions, sightings):
    sightings_by_common_name = {}
    sightings_by_sci_name = {}
    
    if not predictions:
        return []

    if not sightings or not sightings.get("sightings"):
        return []
    
    for sighting in sightings.get("sightings", []):
        sightings_by_common_name[normalize_name(sighting.get("comName", ""))] = sighting
        sightings_by_sci_name[normalize_name(sighting.get("sciName", ""))] = sighting

    matches = []
    for pred in predictions:
        key = normalize_name(pred.get("species", ""))
        if key in sightings_by_common_name:
            matches.append({**pred, **sightings_by_common_name[key]})
        elif key in sightings_by_sci_name:
            matches.append({**pred, **sightings_by_sci_name[key]})

    matches = sorted(matches, key=lambda x: x.get("confidence", 0), reverse=True)

    print(f"Found {len(matches)} matches between predictions ({len(predictions)}) and sightings ({len(sightings.get('sightings', []))}).")

    return matches


def identify(cr3_path: str, identifier: BirdIdentifier, ebird: EBirdClient):
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