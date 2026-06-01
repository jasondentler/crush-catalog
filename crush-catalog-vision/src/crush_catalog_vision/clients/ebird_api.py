from crush_catalog_vision.clients.ebird_api_client import EBirdApiClient
from crush_catalog_vision.clients.ebird_caching_client import EBirdCachingClient
from crush_catalog_vision.clients.ebird_logging_client import EBirdLoggingClient


def build_ebird_api(api_token: str | None, session=None):
    """Build the standard eBird API stack: raw client, logging, then caching."""
    return EBirdCachingClient(EBirdLoggingClient(EBirdApiClient(api_token)), session=session)
