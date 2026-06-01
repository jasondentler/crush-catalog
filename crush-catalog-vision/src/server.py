import os

from crush_catalog_vision.api import clients as client_cache
from crush_catalog_vision.api import identification as api_identification
from crush_catalog_vision.api.config import (
    DEFAULT_DEVICE_ENV,
    DEFAULT_EBIRD_REGION_ENV,
    DEFAULT_EBIRD_TOKEN_ENV,
    DEFAULT_HOST,
    DEFAULT_MODEL_ENV,
    DEFAULT_PORT,
    SCIENTIFIC_NAME_ALIAS_OVERRIDES,
)
from crush_catalog_vision.api.http import parse_multipart_form
from crush_catalog_vision.api.server import build_request_handler, run_server as _run_server
from crush_catalog_vision.clients.ebird_client import EBirdClient
from crush_catalog_vision.identification.scoring import load_env_file, match_prediction_and_location_data
from crush_catalog_vision.images.cr3_handler import display_image_from_file, extract_coordinates_and_time, get_cr3_metadata
from crush_catalog_vision.images.terminal_image import TerminalImage
from crush_catalog_vision.vision.bird_identifier import BirdIdentifier

_IDENTIFIER_CACHE = client_cache._IDENTIFIER_CACHE
_EBIRD_CLIENT_CACHE = client_cache._EBIRD_CLIENT_CACHE

_find_taxonomy_match = api_identification.find_taxonomy_match
flatten_predictions = api_identification.flatten_predictions
enrich_predictions_with_taxonomy = api_identification.enrich_predictions_with_taxonomy
enrich_non_avian_predictions_with_common_names = api_identification.enrich_non_avian_predictions_with_common_names
annotate_non_avian_detections = api_identification.annotate_non_avian_detections
prediction_is_non_avian = api_identification.prediction_is_non_avian
get_inaturalist_taxon_kingdom = api_identification.get_inaturalist_taxon_kingdom
get_inaturalist_taxon_class = api_identification.get_inaturalist_taxon_class
filter_predictions_to_taxonomy = api_identification.filter_predictions_to_taxonomy
parse_location_fallback = api_identification.parse_location_fallback
resolve_location_fallback = api_identification.resolve_location_fallback
build_local_species = api_identification.build_local_species


def get_identifier(model_name: str | None = None, device: str | None = None):
    """Return a cached bird identifier through the compatibility module."""
    return client_cache.get_identifier(model_name=model_name, device=device, identifier_class=BirdIdentifier)


def get_ebird_client(api_token: str | None):
    """Return a cached eBird client through the compatibility module."""
    return client_cache.get_ebird_client(api_token, client_class=EBirdClient)


def prime_ebird_cache():
    """Warm the eBird cache through the compatibility module."""
    return client_cache.prime_ebird_cache(client_factory=get_ebird_client)


def get_inaturalist_common_name(scientific_name: str | None):
    """Return an iNaturalist common name through the compatibility module."""
    return client_cache.get_inaturalist_taxonomy().get_common_name(scientific_name)


def build_response(file_path: str, detections, matches, location_source: str, local_species=None, location_info=None):
    """Build a response while preserving server-level TerminalImage patching."""
    return api_identification.build_response(
        file_path,
        detections,
        matches,
        location_source,
        local_species=local_species,
        location_info=location_info,
        terminal_image=TerminalImage,
    )


class _ServerDependencies:
    display_image_from_file = staticmethod(lambda file_path: display_image_from_file(file_path))
    get_cr3_metadata = staticmethod(lambda file_path: get_cr3_metadata(file_path))
    extract_coordinates_and_time = staticmethod(lambda metadata: extract_coordinates_and_time(metadata))
    get_identifier = staticmethod(lambda model_name=None, device=None: get_identifier(model_name=model_name, device=device))
    get_ebird_client = staticmethod(lambda token: get_ebird_client(token))
    resolve_location_fallback = staticmethod(lambda location_fallback: resolve_location_fallback(location_fallback))
    enrich_predictions_with_taxonomy = staticmethod(enrich_predictions_with_taxonomy)
    annotate_non_avian_detections = staticmethod(annotate_non_avian_detections)
    get_inaturalist_common_name = staticmethod(lambda scientific_name: get_inaturalist_common_name(scientific_name))
    filter_predictions_to_taxonomy = staticmethod(filter_predictions_to_taxonomy)
    flatten_predictions = staticmethod(flatten_predictions)
    match_prediction_and_location_data = staticmethod(match_prediction_and_location_data)
    build_local_species = staticmethod(build_local_species)
    build_response = staticmethod(build_response)


def identify_photo(
    file_path: str,
    ebird_token: str,
    model_name: str | None = None,
    device: str | None = None,
    location_fallback: str | None = None,
):
    """Identify a photo through the compatibility server module."""
    return api_identification.identify_photo(
        file_path,
        ebird_token,
        _ServerDependencies,
        model_name=model_name,
        device=device,
        location_fallback=location_fallback,
    )


def lookup_location(latitude: float | None, longitude: float | None, ebird_token: str, location_fallback: str | None = None):
    """Look up location metadata through the compatibility server module."""
    return api_identification.lookup_location(
        latitude,
        longitude,
        ebird_token,
        _ServerDependencies,
        location_fallback=location_fallback,
    )


class _RequestDependencies:
    identify_photo = staticmethod(identify_photo)
    lookup_location = staticmethod(lookup_location)


BirdIDRequestHandler = build_request_handler(_RequestDependencies)


def run_server(host: str = DEFAULT_HOST, port: int = DEFAULT_PORT):
    """Run the HTTP backend using compatibility module dependencies."""
    _run_server(BirdIDRequestHandler, load_env_file, prime_ebird_cache, host=host, port=port)


if __name__ == "__main__":
    host = os.getenv("BIRD_ID_HOST", DEFAULT_HOST)
    port = int(os.getenv("BIRD_ID_PORT", DEFAULT_PORT))
    run_server(host, port)
