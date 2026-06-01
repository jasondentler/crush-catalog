import os
from pathlib import Path

from crush_catalog_vision.api.config import (
    DEFAULT_EBIRD_REGION_ENV,
    NON_AVIAN_CONFIDENCE_THRESHOLD,
    SCIENTIFIC_NAME_ALIAS_OVERRIDES,
)


def find_taxonomy_match(species, species_by_scientific_name, scientific_name_aliases=None):
    """Return the current eBird taxonomy row for a model species name."""
    if not species:
        return None

    key = species.lower()
    taxonomy_match = species_by_scientific_name.get(key)
    if taxonomy_match:
        return taxonomy_match

    alias = SCIENTIFIC_NAME_ALIAS_OVERRIDES.get(key)
    if alias:
        return species_by_scientific_name.get(alias)

    if callable(scientific_name_aliases):
        aliases = scientific_name_aliases()
    else:
        aliases = scientific_name_aliases or {}

    alias = aliases.get(key)
    if alias:
        return species_by_scientific_name.get(alias)

    return None


def flatten_predictions(detections):
    """Convert nested per-detection predictions into one ranked prediction list."""
    predictions = []
    for detection in detections:
        top_prediction = detection.get("top_prediction") or {}
        for pred in detection.get("predictions", []):
            predictions.append({
                **pred,
                "detection_id": detection.get("detection_id"),
                "detection_top_familySciName": top_prediction.get("familySciName"),
                "detection_top_familyComName": top_prediction.get("familyComName"),
                "detection_top_order": top_prediction.get("order"),
                "box": detection.get("box"),
            })
    return predictions


def enrich_predictions_with_taxonomy(detections, species_by_scientific_name, scientific_name_aliases=None):
    """Attach eBird taxonomy fields to model predictions in place."""
    taxonomy_fields = (
        "comName",
        "sciName",
        "speciesCode",
        "familyComName",
        "familySciName",
        "order",
    )
    for detection in detections:
        for pred in detection.get("predictions", []):
            taxonomy_match = find_taxonomy_match(
                pred.get("species"),
                species_by_scientific_name,
                scientific_name_aliases=scientific_name_aliases,
            )
            if taxonomy_match:
                for field in taxonomy_fields:
                    pred[field] = taxonomy_match.get(field)


def filter_predictions_to_taxonomy(detections):
    """Remove predictions that could not be matched to eBird taxonomy."""
    for detection in detections:
        detection["predictions"] = [
            pred
            for pred in detection.get("predictions", [])
            if pred.get("comName") and pred.get("sciName")
        ]
        detection["top_prediction"] = detection["predictions"][0] if detection["predictions"] else None


def get_inaturalist_taxon_class(prediction):
    """Return the iNaturalist class name encoded in a Birder class label."""
    class_label = prediction.get("class_label") if prediction else None
    if not class_label:
        return None

    parts = class_label.split("_")
    if len(parts) < 4:
        return None

    return parts[3]


def prediction_is_non_avian(prediction):
    """Return whether a model prediction names a non-bird taxon."""
    if not prediction:
        return False

    taxon_class = get_inaturalist_taxon_class(prediction)
    return bool(taxon_class) and taxon_class != "Aves"


def prediction_confidence(prediction):
    """Return a prediction confidence as a float, or zero when missing."""
    try:
        return float(prediction.get("confidence") or 0)
    except (TypeError, ValueError):
        return 0


def non_avian_confidence(predictions):
    """Return summed confidence for non-bird iNaturalist predictions."""
    return sum(
        prediction_confidence(prediction)
        for prediction in predictions or []
        if prediction_is_non_avian(prediction)
    )


def annotate_non_avian_detections(detections, threshold=NON_AVIAN_CONFIDENCE_THRESHOLD):
    """Mark detections whose raw predictions are confidently non-avian overall."""
    for detection in detections:
        predictions = detection.get("predictions") or []
        top_prediction = detection.get("top_prediction")
        if not top_prediction and predictions:
            top_prediction = predictions[0] if predictions else None

        aggregate_confidence = non_avian_confidence(predictions)
        if prediction_is_non_avian(top_prediction) and aggregate_confidence >= threshold:
            detection["review_suggestion"] = "not_a_bird"
            non_avian_prediction = dict(top_prediction)
            non_avian_prediction["aggregate_confidence"] = round(aggregate_confidence, 4)
            detection["non_avian_prediction"] = non_avian_prediction


def log_raw_detection_predictions(detections, limit=5):
    """Print raw model predictions before taxonomy filtering for debugging."""
    for detection_index, detection in enumerate(detections or [], start=1):
        predictions = detection.get("predictions") or []
        print(
            f"Raw detection index={detection_index} id={detection.get('detection_id')} predictions={len(predictions)}",
            flush=True,
        )
        for prediction in predictions[:limit]:
            print(
                "Raw prediction "
                f"detection={detection_index} "
                f"rank={prediction.get('rank')} "
                f"species={prediction.get('species')} "
                f"confidence={prediction.get('confidence')} "
                f"taxon_class={get_inaturalist_taxon_class(prediction) or 'unknown'} "
                f"class_label={prediction.get('class_label')}",
                flush=True,
            )


def parse_location_fallback(location_fallback: str | None) -> str | None:
    """Normalize a user-provided fallback eBird region code."""
    if not location_fallback:
        return None
    fallback = location_fallback.strip()
    if fallback == "":
        return None
    return fallback


def resolve_location_fallback(location_fallback: str | None) -> str | None:
    """Return the request fallback region or the configured default region."""
    return parse_location_fallback(location_fallback) or parse_location_fallback(os.getenv(DEFAULT_EBIRD_REGION_ENV))


def build_local_species(sightings):
    """Build a sorted, unique species list from eBird sightings data."""
    if not sightings or not sightings.get("sightings"):
        return []

    local_species = []
    seen_species_codes = set()
    for sighting in sightings.get("sightings", []):
        species_code = sighting.get("speciesCode")
        if species_code in seen_species_codes:
            continue

        common_name = sighting.get("comName")
        scientific_name = sighting.get("sciName")
        if not common_name and not scientific_name:
            continue

        seen_species_codes.add(species_code)
        local_species.append({
            "comName": common_name,
            "sciName": scientific_name,
            "speciesCode": species_code,
        })

    return sorted(local_species, key=lambda item: (item.get("comName") or item.get("sciName") or "").lower())


def build_response(file_path: str, detections, matches, location_source: str, local_species=None, location_info=None, terminal_image=None):
    """Build the JSON-serializable identification response payload."""
    matches_by_detection = {}
    for match in matches:
        detection_id = match.get("detection_id")
        if detection_id is not None:
            matches_by_detection.setdefault(detection_id, []).append(match)

    serializable_detections = []
    for detection_number, detection in enumerate(detections, start=1):
        if terminal_image is not None:
            terminal_image.display(detection["image"])

        detection_copy = detection.copy()
        detection_copy.pop("image", None)

        detection_id = detection.get("detection_id")
        detection_matches = matches_by_detection.get(detection_id, [])

        if detection_matches:
            best_match = detection_matches[0]
            common_name = best_match.get("comName")
            sci_name = best_match.get("sciName")
            confidence = best_match.get("confidence")
            print(f"🪶 Bird #{detection_number} is probably {common_name} ({sci_name}) - {confidence:.1%}")
            detection_copy["best_match"] = best_match
            detection_copy["alternatives"] = detection_matches[1:] if len(detection_matches) > 1 else []
        else:
            print(f"🛑 No match for detected bird #{detection_number}")
            detection_copy["best_match"] = None
            detection_copy["alternatives"] = []

        serializable_detections.append(detection_copy)

    response = {
        "file_path": file_path,
        "location_source": location_source,
        "location": build_location_payload(location_source, location_info),
        "local_species": local_species or [],
        "detections": serializable_detections,
    }

    if not matches:
        response["error"] = "No matching species were found for this photo."

    return response


def build_location_payload(source, location_info=None):
    """Return the location block used by backend JSON responses."""
    return {
        "source": source,
        "region_code": location_info.get("region_code") if location_info else None,
        "hotspot_id": location_info.get("hotspot_id") if location_info else None,
        "hotspot_name": location_info.get("hotspot_name") if location_info else None,
    }


def identify_photo(
    file_path: str,
    ebird_token: str,
    dependencies,
    model_name: str | None = None,
    device: str | None = None,
    location_fallback: str | None = None,
):
    """Run detection, taxonomy enrichment, and local-species ranking for a photo."""
    if not Path(file_path).is_file():
        return {"error": f"File path does not exist: {file_path}"}

    dependencies.display_image_from_file(file_path)

    identifier = dependencies.get_identifier(model_name=model_name, device=device)
    ebird = dependencies.get_ebird_client(ebird_token)

    detections = identifier.predict_from_file(file_path, top_k=20)
    log_raw_detection_predictions(detections)
    metadata = dependencies.get_cr3_metadata(file_path)
    latitude, longitude, timestamp = dependencies.extract_coordinates_and_time(metadata)
    location_source = "gps"

    if latitude is None or longitude is None:
        location_source = "fallback"
        location_fallback = dependencies.resolve_location_fallback(location_fallback)
        if not location_fallback:
            return {"error": "Missing GPS coordinates and no location fallback was provided."}

    sightings = ebird.get_sightings_for_time_of_year(latitude, longitude, timestamp, location_fallback=location_fallback)
    location_info = ebird.get_location_info(latitude, longitude, location_fallback=location_fallback) if hasattr(ebird, "get_location_info") else {}

    scientific_name_aliases = (
        ebird.get_cached_scientific_name_aliases()
        if hasattr(ebird, "get_cached_scientific_name_aliases")
        else {}
    )
    dependencies.enrich_predictions_with_taxonomy(
        detections,
        ebird.get_species_by_scientific_name(),
        scientific_name_aliases=scientific_name_aliases,
    )
    if hasattr(dependencies, "annotate_non_avian_detections"):
        dependencies.annotate_non_avian_detections(detections)
    dependencies.filter_predictions_to_taxonomy(detections)
    predictions = dependencies.flatten_predictions(detections)
    matches = dependencies.match_prediction_and_location_data(predictions, sightings)
    local_species = dependencies.build_local_species(sightings)

    return dependencies.build_response(file_path, detections, matches, location_source, local_species, location_info)


def lookup_location(latitude: float | None, longitude: float | None, ebird_token: str, dependencies, location_fallback: str | None = None):
    """Look up eBird region and hotspot metadata for GPS coordinates."""
    if latitude is None or longitude is None:
        return {"error": "Missing latitude or longitude."}

    ebird = dependencies.get_ebird_client(ebird_token)
    location_info = ebird.get_location_info(latitude, longitude, location_fallback=location_fallback)
    return {"location": build_location_payload("gps", location_info)}
