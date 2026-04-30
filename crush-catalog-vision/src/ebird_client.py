import datetime
import os
import requests
import requests_cache
import json
from urllib.parse import urlencode

class EBirdClient:
    """A wrapper around the eBird API 2.0 to fetch bird observation data based

    on coordinates or fallbacks.
    """

    def __init__(self, api_token: str):
        self.api_token = api_token
        self.base_url = "https://api.ebird.org/v2"
        self.default_region = os.getenv("DEFAULT_EBIRD_REGION")

        self.session = requests_cache.CachedSession(
            "ebird_cache",
            backend="sqlite",
            expire_after=5*60,  # Cache expires after 24 hours (in seconds)
        )

    def get_sightings_in_region(self, lat: float, lng: float) -> set:
        """Queries eBird for sightings in the region around the coordinates (or fallback)
        """
        codes_of_species_sighted = set()

        region_code = self._get_best_region_from_coords(lat, lng)

        if not region_code:
            print("⚠️ No region code provided or available in fallback.")
            return set()

        endpoint = f"{self.base_url}/product/spplist/{region_code}"
        headers = {"x-ebirdapitoken": self.api_token}

        data = self._get(endpoint, headers=headers)
        codes_of_species_sighted.update(data)

        species_dict = self.get_species_code_dict()

        matching_values = [species_dict[code] for code in codes_of_species_sighted if code in species_dict]

        return matching_values

    def get_sightings_on_date(self, lat: float, lng: float, timestamp_str: str) -> set:
        """Queries eBird for sightings on an exact date using resolved region or

        fallback.
        """
        try:
            dt = datetime.datetime.strptime(timestamp_str[:10], "%Y:%m:%d")
            formatted_date = dt.strftime("%Y/%m/%d")
        except ValueError:
            print(f"⚠️ Invalid timestamp format: {timestamp_str}")
            return set()

        region_code = self._get_best_region_from_coords(lat, lng)

        if not region_code:
            print("⚠️ No region code provided or available in fallback.")
            return set()

        endpoint = f"{self.base_url}/data/obs/{region_code}/historic/{formatted_date}"
        headers = {"x-ebirdapitoken": self.api_token}

        try:
            data = self._get(endpoint, headers=headers)

            return {obs["comName"].lower() for obs in data}

        except requests.exceptions.RequestException as e:
            print(f"Error fetching data from eBird API: {e}")
            return set()

    def get_species_code_dict(self) -> dict[str, any]:
        """Queries the eBird taxonomy data
        """
        endpoint = f"{self.base_url}/ref/taxonomy/ebird"
        params = {
            "fmt": "json",
        }
        headers = {"x-ebirdapitoken": self.api_token}
        data = self._get(endpoint, params=params, headers=headers)
        species_dict = {item["speciesCode"]: item for item in data}
        return species_dict

    def _get_best_region_from_coords(self, lat: float, lng: float) -> str | None:

        if lat and lng:
            # 1. Attempt to resolve region directly from coordinates
            region_code = self._get_region_from_coords(lat, lng)

            # 2. Fallback to finding the NEAREST hotspot's region
            if not region_code:
                region_code = self._get_nearest_hotspot_region(lat, lng)
        else:
            region_code = None

        # 3. Fallback to the .env default if no hotspots are found
        if not region_code:
            print(f"⚠️ No hotspots found. Using fallback region: {self.default_region}")
            region_code = self.default_region

        if not region_code:
            print("⚠️ No region code provided or available in fallback.")
            return None
        
        return region_code

    def _get_region_from_coords(self, lat: float, lng: float) -> str | None:
        """Helper to find the eBird region code mapped directly to coordinates."""
        endpoint = f"{self.base_url}/ref/geo/pos/{lat}/{lng}?fmt=json"
        headers = {"x-ebirdapitoken": self.api_token}

        try:
            data = self._get(endpoint, headers=headers)
            return data["code"] if data else None
        except Exception as e:
            return None

    def _get_nearest_hotspot_region(self, lat: float, lng: float) -> str | None:
        """Finds the nearest public hotspot and returns its county/subnational

        code.
        """
        # Fetches up to 50km radius from your water coordinates
        endpoint = f"{self.base_url}/ref/hotspot/geo"
        headers = {"x-ebirdapitoken": self.api_token}
        params = {"lat": lat, "lng": lng, "dist": 50, "fmt": "json"}

        try:
            data = self._get(endpoint, headers=headers, params=params)

            if data:
                # eBird naturally returns these sorted by closest distance first
                closest_hotspot = data[0]

                # We can call the hotspot info to get its subnational2 (county) code
                loc_id = closest_hotspot["locId"]
                return self._get_region_from_hotspot_id(loc_id)
            else:
                print(f"⚠️ No hotspots near coordinates: {lat}, {lng}")
        except Exception as e:
            print(f"⚠️ Failed to find nearby hotspots: {e}")
            return None

        return None

    def _get_region_from_hotspot_id(self, loc_id: str) -> str | None:
        """Fetches the detailed region code associated with a specific hotspot

        ID.
        """
        endpoint = f"{self.base_url}/ref/hotspot/info/{loc_id}"
        headers = {"x-ebirdapitoken": self.api_token, "fmt": "json"}

        try:
            data = self._get(endpoint, headers=headers)

            # Return county code (subnational2) or state code (subnational1)
            if "subnational2Code" in data:
                return data["subnational2Code"]
            return data.get("subnational1Code")
        except Exception as e:
            print(f"⚠️ Failed to lookup region from hotspot id: {e}")
            return None

    def _get(self, endpoint: str, params: dict[str, any] | None = None, headers: dict[str, any] | None = None) -> any:
        response = self.session.get(endpoint, params=params, headers=headers)

        if params:
            query_string = f"?{urlencode(params)}"
        else:
            query_string = ""

        full_url=f"{endpoint}{query_string}"

        # Print a debug line to prove the cache is working
        if getattr(response, "from_cache", False):
            print(f"⚡️ [CACHE HIT]   {full_url}")
        else:
            print(f"📡 [NETWORK HIT] {full_url}")


        response.raise_for_status()

        # 🎯 CHECK MIME TYPE BEFORE PARSING
        content_type = response.headers.get("Content-Type", "")

        if "application/json" not in content_type:
            print(f"⚠️ Expected JSON, but received MIME type: {content_type}")
            print(f"Server says: {response.text[:200]}")
        
        data = response.json()
        # print(json.dumps(data, indent=2))
        return data