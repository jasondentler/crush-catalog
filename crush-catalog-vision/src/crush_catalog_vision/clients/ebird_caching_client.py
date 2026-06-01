import requests_cache

DEBUG = False


class EBirdCachingClient:
    """Wrap eBird endpoint calls with persistent and process-local caching."""

    def __init__(self, api, session=None, cache_name="ebird_cache", expire_after=60 * 60, allowable_codes=None):
        """Wrap an eBird API-compatible object with cached HTTP and memoized calls."""
        self.api = api
        self.cache = {}
        self.allowable_codes = allowable_codes or [200, 404]
        self.session = session or requests_cache.CachedSession(
            cache_name,
            backend="sqlite",
            expire_after=expire_after,
            allowable_methods=["GET"],
            allowable_codes=self.allowable_codes,
        )
        self._attach_session(self.api)

    def get_species_list(self, region_code: str):
        """Return cached species codes reported for an eBird region."""
        return self._cached_call("get_species_list", region_code)

    def get_historic_observations(self, region_code: str, formatted_date: str):
        """Return cached historic observations for a region and date."""
        return self._cached_call("get_historic_observations", region_code, formatted_date)

    def get_taxonomy(self, version: str | int | float | None = None):
        """Return cached eBird taxonomy for the latest or requested version."""
        return self._cached_call("get_taxonomy", version)

    def get_taxonomy_versions(self):
        """Return cached available eBird taxonomy versions."""
        return self._cached_call("get_taxonomy_versions")

    def get_region_from_coords(self, lat: float, lng: float):
        """Return cached eBird region metadata for GPS coordinates."""
        return self._cached_call("get_region_from_coords", lat, lng)

    def get_hotspots_near(self, lat: float, lng: float, dist: int = 50):
        """Return cached eBird hotspots near GPS coordinates."""
        return self._cached_call("get_hotspots_near", lat, lng, dist)

    def get_hotspot_info(self, loc_id: str):
        """Return cached eBird metadata for a hotspot ID."""
        return self._cached_call("get_hotspot_info", loc_id)

    def _cached_call(self, method_name, *args):
        """Call the wrapped API once for a method/argument combination."""
        cache_key = (method_name, args)
        if cache_key not in self.cache:
            if DEBUG:
                print(f"Making cached eBird API call: {method_name}{args}")
            self.cache[cache_key] = getattr(self.api, method_name)(*args)
        return self.cache[cache_key]

    def _attach_session(self, api):
        """Attach the persistent cache session to the innermost API client."""
        if hasattr(api, "session"):
            api.session = self.session
            return

        wrapped_api = getattr(api, "api", None)
        if wrapped_api is not None:
            self._attach_session(wrapped_api)
