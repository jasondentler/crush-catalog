import requests

EBIRD_BASE_URL = "https://api.ebird.org/v2"


class EBirdApiClient:
    """Call individual eBird API endpoints without domain orchestration."""

    def __init__(self, api_token: str | None, base_url: str = EBIRD_BASE_URL, session=None):
        """Create a simple endpoint client with an optional HTTP session."""
        self.api_token = api_token
        self.base_url = base_url
        self.session = session or requests.Session()

    def get_species_list(self, region_code: str):
        """Return species codes reported for an eBird region."""
        return self._get(f"{self.base_url}/product/spplist/{region_code}")

    def get_historic_observations(self, region_code: str, formatted_date: str):
        """Return historic observations for a region and date."""
        return self._get(f"{self.base_url}/data/obs/{region_code}/historic/{formatted_date}")

    def get_taxonomy(self, version: str | int | float | None = None):
        """Return eBird taxonomy for the latest or requested version."""
        params = {"fmt": "json"}
        if version is not None:
            params["version"] = self._taxonomy_version_param(version)

        return self._get(f"{self.base_url}/ref/taxonomy/ebird", params=params)

    def get_taxonomy_versions(self):
        """Return available eBird taxonomy versions."""
        return self._get(f"{self.base_url}/ref/taxonomy/versions")

    def get_region_from_coords(self, lat: float, lng: float):
        """Return eBird region metadata for GPS coordinates."""
        return self._get(f"{self.base_url}/ref/geo/pos/{lat}/{lng}", params={"fmt": "json"})

    def get_hotspots_near(self, lat: float, lng: float, dist: int = 50):
        """Return eBird hotspots near GPS coordinates."""
        params = {"lat": lat, "lng": lng, "dist": dist, "fmt": "json"}
        return self._get(f"{self.base_url}/ref/hotspot/geo", params=params)

    def get_hotspot_info(self, loc_id: str):
        """Return eBird metadata for a hotspot ID."""
        return self._get(f"{self.base_url}/ref/hotspot/info/{loc_id}", params={"fmt": "json"})

    def _get(self, endpoint: str, params: dict[str, any] | None = None):
        """Perform an authenticated GET request and return decoded JSON."""
        response = self.session.get(endpoint, params=params, headers=self._headers())
        response.raise_for_status()
        return response.json()

    def _headers(self):
        """Return the authentication headers required by eBird."""
        return {"x-ebirdapitoken": self.api_token}

    @staticmethod
    def _taxonomy_version_param(version):
        """Normalize taxonomy version values for eBird query parameters."""
        try:
            numeric_version = float(version)
            if numeric_version.is_integer():
                return str(int(numeric_version))
            return str(numeric_version)
        except (TypeError, ValueError):
            return str(version)
