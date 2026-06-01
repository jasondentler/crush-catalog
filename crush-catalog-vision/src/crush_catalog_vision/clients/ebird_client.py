from crush_catalog_vision.clients.ebird_api import build_ebird_api
from crush_catalog_vision.services.ebird_location import EBirdLocationService
from crush_catalog_vision.services.ebird_sightings import EBirdSightingsService
from crush_catalog_vision.services.ebird_taxonomy import EBirdTaxonomyService

DEBUG = False


class EBirdClient:
    """Compatibility façade for eBird endpoint clients and domain services."""

    def __init__(self, api_token: str | None):
        """Create the eBird API stack and domain services."""
        self.api_token = api_token
        self.base_url = "https://api.ebird.org/v2"

        self.api = build_ebird_api(api_token)
        self.location_service = EBirdLocationService(self.api)
        self.taxonomy_service = EBirdTaxonomyService(self.api)
        self.sightings_service = EBirdSightingsService(self.api, self.location_service, self.taxonomy_service)

    def get_sightings_in_region(self, lat: float | None, lng: float | None, location_fallback: str | None = None) -> set:
        """Return species codes reported in the best region for a location."""
        return self.sightings_service.get_sightings_in_region(lat, lng, location_fallback)

    def get_sightings_for_time_of_year(self, lat: float | None, lng: float | None, timestamp_str: str, location_fallback: str | None = None) -> set:
        """Return species reported near the same date in recent prior years."""
        return self.sightings_service.get_sightings_for_time_of_year(lat, lng, timestamp_str, location_fallback)

    def get_sightings_on_date(self, region_code: str | None, lat: float | None, lng: float | None, timestamp, location_fallback: str | None = None) -> set:
        """Return species reported in a region on a specific historical date."""
        return self.sightings_service.get_sightings_on_date(region_code, lat, lng, timestamp, location_fallback)

    def get_species_code_dict(self) -> dict[str, any]:
        """Return current eBird taxonomy keyed by species code."""
        return self.taxonomy_service.get_species_code_dict()

    def get_taxonomy_versions(self) -> list[dict[str, any]]:
        """Return available eBird taxonomy versions."""
        return self.taxonomy_service.get_taxonomy_versions()

    def get_taxonomy(self, version: str | int | float | None = None) -> list[dict[str, any]]:
        """Return eBird taxonomy for the latest or requested taxonomy version."""
        return self.taxonomy_service.get_taxonomy(version)

    def get_scientific_name_aliases(self) -> dict[str, str]:
        """Build aliases from historical scientific names to current names."""
        return self.taxonomy_service.get_scientific_name_aliases()

    def get_cached_scientific_name_aliases(self) -> dict[str, str]:
        """Return preloaded scientific-name aliases without blocking on loading."""
        return self.taxonomy_service.get_cached_scientific_name_aliases()

    def prefetch_scientific_name_aliases(self):
        """Load scientific-name aliases in a background thread."""
        return self.taxonomy_service.prefetch_scientific_name_aliases()

    def get_species_by_scientific_name(self) -> dict[str, any]:
        """Return current eBird taxonomy keyed by lowercase scientific name."""
        return self.taxonomy_service.get_species_by_scientific_name()

    def get_location_info(self, lat: float | None, lng: float | None, location_fallback: str | None = None) -> dict:
        """Return region and nearest hotspot metadata for GPS coordinates."""
        return self.location_service.get_location_info(lat, lng, location_fallback)
