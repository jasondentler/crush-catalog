import requests

DEBUG = False


class EBirdLoggingClient:
    """Wrap eBird endpoint calls with optional request and error logging."""

    def __init__(self, api):
        """Wrap an eBird API-compatible object."""
        self.api = api

    def get_species_list(self, region_code: str):
        """Return species codes reported for an eBird region."""
        return self._call("get_species_list", region_code)

    def get_historic_observations(self, region_code: str, formatted_date: str):
        """Return historic observations for a region and date."""
        return self._call("get_historic_observations", region_code, formatted_date)

    def get_taxonomy(self, version: str | int | float | None = None):
        """Return eBird taxonomy for the latest or requested version."""
        return self._call("get_taxonomy", version)

    def get_taxonomy_versions(self):
        """Return available eBird taxonomy versions."""
        return self._call("get_taxonomy_versions")

    def get_region_from_coords(self, lat: float, lng: float):
        """Return eBird region metadata for GPS coordinates."""
        return self._call("get_region_from_coords", lat, lng)

    def get_hotspots_near(self, lat: float, lng: float, dist: int = 50):
        """Return eBird hotspots near GPS coordinates."""
        return self._call("get_hotspots_near", lat, lng, dist)

    def get_hotspot_info(self, loc_id: str):
        """Return eBird metadata for a hotspot ID."""
        return self._call("get_hotspot_info", loc_id)

    def _call(self, method_name, *args):
        """Call a wrapped method and log useful diagnostics when enabled."""
        if DEBUG:
            print(f"Making eBird API call: {method_name}{args}")

        try:
            return getattr(self.api, method_name)(*args)
        except requests.exceptions.HTTPError as exc:
            self._log_http_error(exc)
            raise

    def _log_http_error(self, exc):
        """Print request and response details for failed API calls."""
        response = exc.response
        if response is None:
            return

        request = response.request
        if response.status_code == 400:
            print(f"❌ Bad request to eBird API: {response.text}")
        elif response.status_code == 500:
            print(f"❌ Server error from eBird API: {response.text}")
        else:
            return

        print(f"Request: {request.method} {request.url}")
        print("\n--- REQUEST HEADERS ---")
        for key, value in request.headers.items():
            print(f"{key}: {value}")

        if response.status_code == 500:
            print("\n--- RESPONSE HEADERS ---")
            for key, value in (response.headers or {}).items():
                print(f"{key}: {value}")
            print("\n--- RESPONSE BODY ---")
            print(response.text)
