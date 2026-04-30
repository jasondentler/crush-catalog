import os
import json
from pathlib import Path
from bird_identifier import BirdIdentifier
from ebird_client import EBirdClient
from cr3_handler import get_cr3_metadata, extract_coordinates_and_time


def load_env_file(filepath: str = ".env"):
    """Manually reads an .env file and injects its variables into os.environ."""
    if not os.path.exists(filepath):
        return

    with open(filepath, "r") as f:
        for line in f:
            line = line.strip()
            # Skip comments and empty lines
            if not line or line.startswith("#"):
                continue

            # Split by the first '=' to get key and value
            if "=" in line:
                key, value = line.split("=", 1)
                os.environ[key.strip()] = value.strip()


def normalize_name(name: str) -> str:
    """Lowercases the string and strips hyphens to match Birder's class array."""
    return name.lower().replace("-", " ")


def match_prediction_and_location_data(predictions, sightings):
    predictions_dict = {}
    for pred in predictions:
        key = normalize_name(pred["species"])
        predictions_dict[key] = pred

    sightings_by_common_name_dict = {}
    for sighting in sightings:
        key = normalize_name(sighting["comName"])
        sightings_by_common_name_dict[key] = sighting

    sightings_by_sci_name_dict = {}
    for sighting in sightings:
        key = normalize_name(sighting["sciName"])
        sightings_by_sci_name_dict[key] = sighting

    results = []
    common_keys = predictions_dict.keys() & sightings_by_common_name_dict.keys()
    sci_keys = predictions_dict.keys() & sightings_by_sci_name_dict.keys()

    for key in common_keys:
        prediction = predictions_dict[key]
        sighting = sightings_by_common_name_dict[key]
        results.append({**prediction, **sighting})

    for key in sci_keys:
        prediction = predictions_dict[key]
        sighting = sightings_by_sci_name_dict[key]
        results.append({**prediction, **sighting})

    top_results = sorted(results, key=lambda x: x["rank"])[:10]
    return top_results


def identify(cr3_path: str, identifier: BirdIdentifier, ebird: EBirdClient):
    print(f"🖼️ {cr3_path}")
    cr3_predictions = identifier.predict_from_file(cr3_path, None)
    cr3_metadata = get_cr3_metadata(cr3_path)
    latitude, longitude, timestamp = extract_coordinates_and_time(cr3_metadata)

    sightings = ebird.get_sightings_in_region(latitude, longitude)

    matches = match_prediction_and_location_data(cr3_predictions, sightings)

    if matches:
        match = matches[0]
        data = {
            "rank": match["rank"],
            "confidence": match["confidence"],
            "comName": match["comName"],
            "sciName": match["sciName"],
        }

        print(f"✅ Confidence: {data['confidence']:.1%} (rank: {data['rank']})")
        print(f"🧬 Scientific Name: {data['sciName']}")
        print(f"🪶 Common Name: {data['comName']}")

        if data["confidence"] < 0.5:
            miss_count = data["rank"] - 1
            misses = cr3_predictions[:miss_count]
            for miss in misses:
                print(
                    f"🧳 {miss['species']} {miss['confidence']:.1%} (#{miss['rank']})"
                )
                print(json.dumps(miss, indent=2))

        print()
    else:
        print("🛑 Failed to identify the bird species in the photo.")
        print()


def main():
    load_env_file()

    # Initialize the class (loads the heavy model to GPU once)
    birder_model = os.getenv("BIRDER_MODEL")
    print(f"🪶💾 Birder Model:\t{birder_model}")
    compute_device = os.getenv("COMPUTE_DEVICE")
    print(f"  💻 Compute Device:\t{compute_device}")

    # 🎯 FETCH THE TOKEN FROM THE ENVIRONMENT SECURELY
    ebird_token = os.getenv("EBIRD_TOKEN")

    # Perfect class matching
    identifier = BirdIdentifier(model_name=birder_model, device=compute_device)
    ebird = EBirdClient(ebird_token)

    # Use .expanduser() to resolve the tilde (~) to your user home directory
    folder_path = Path("~/Pictures/2026/2026-04/2026-04-19").expanduser()

    # 2. Enumerate all files ending in .CR3 (case-insensitive)
    for path_obj in folder_path.glob("*.[Cc][Rr]3"):
        cr3_path = str(path_obj.resolve())
        identify(cr3_path, identifier, ebird)


if __name__ == "__main__":
    main()
