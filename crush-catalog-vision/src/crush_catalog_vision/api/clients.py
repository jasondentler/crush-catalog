import os

from crush_catalog_vision.api.config import DEFAULT_DEVICE_ENV, DEFAULT_EBIRD_TOKEN_ENV, DEFAULT_MODEL_ENV
from crush_catalog_vision.clients.ebird_client import EBirdClient
from crush_catalog_vision.vision.bird_identifier import BirdIdentifier

_IDENTIFIER_CACHE = {}
_EBIRD_CLIENT_CACHE = {}


def _cached_instance_matches_class(instance, expected_class):
    """Return whether a cached dependency was created from the expected class."""
    try:
        return isinstance(instance, expected_class)
    except TypeError:
        return True


def get_identifier(model_name: str | None = None, device: str | None = None, identifier_class=BirdIdentifier):
    """Return a cached bird identifier for the requested model/device pair."""
    resolved_model_name = model_name or os.getenv(DEFAULT_MODEL_ENV)
    resolved_device = device or os.getenv(DEFAULT_DEVICE_ENV, "cpu")
    cache_key = (resolved_model_name, resolved_device)

    if (
        cache_key not in _IDENTIFIER_CACHE
        or not _cached_instance_matches_class(_IDENTIFIER_CACHE[cache_key], identifier_class)
    ):
        _IDENTIFIER_CACHE[cache_key] = identifier_class(
            model_name=resolved_model_name,
            device=resolved_device,
        )

    return _IDENTIFIER_CACHE[cache_key]


def get_ebird_client(api_token: str | None, client_class=EBirdClient):
    """Return a cached eBird client for the requested API token."""
    resolved_token = api_token or os.getenv(DEFAULT_EBIRD_TOKEN_ENV)
    if (
        resolved_token not in _EBIRD_CLIENT_CACHE
        or not _cached_instance_matches_class(_EBIRD_CLIENT_CACHE[resolved_token], client_class)
    ):
        _EBIRD_CLIENT_CACHE[resolved_token] = client_class(resolved_token)
        if hasattr(_EBIRD_CLIENT_CACHE[resolved_token], "prefetch_scientific_name_aliases"):
            _EBIRD_CLIENT_CACHE[resolved_token].prefetch_scientific_name_aliases()

    return _EBIRD_CLIENT_CACHE[resolved_token]


def prime_ebird_cache(client_factory=get_ebird_client):
    """Warm eBird taxonomy caches when an environment token is configured."""
    token = os.getenv(DEFAULT_EBIRD_TOKEN_ENV)
    if not token:
        print("⚠️ EBIRD_TOKEN is not set; eBird taxonomy cache will warm on first request with a token.")
        return None

    return client_factory(token)
