import datetime
import os
import requests
import requests_cache
import json
from urllib.parse import urlencode

DEBUG=False
TIME_OF_YEAR_PROXY_DAYS = 4
TIME_OF_YEAR_YEARS_BACK = 2

class EBirdClient:
    """A wrapper around the eBird API 2.0 to fetch bird observation data."""

    def __init__(self, api_token: str | None):
        self.api_token = api_token
        self.base_url = "https://api.ebird.org/v2"
        self.default_region = os.getenv("DEFAULT_EBIRD_REGION")
        self.cache_allowable_codes = [200, 404]

        self.session = requests_cache.CachedSession(
            "ebird_cache",
            backend="sqlite",
            expire_after=60 * 60, # Cache responses for 1 hour
            allowable_methods=["GET"],
            allowable_codes=self.cache_allowable_codes,
        )

    def get_sightings_in_region(self, lat: float | None, lng: float | None, location_fallback: str | None = None) -> set:
        region_code = self._get_best_region_from_coords(lat, lng, location_fallback)
        if not region_code:
            return None

        endpoint = f"{self.base_url}/product/spplist/{region_code}"
        headers = {"x-ebirdapitoken": self.api_token}
        data = self._get(endpoint, headers=headers)
        return {
            "region_code": region_code,
            "sightings": set(data)
        }

    def get_sightings_for_time_of_year(self, lat: float | None, lng: float | None, timestamp_str: str, location_fallback: str | None = None) -> set:
        try:
            dt = datetime.datetime.strptime(timestamp_str[:10], "%Y:%m:%d")
            proxy_dates = []
            for yeardelta in range(TIME_OF_YEAR_YEARS_BACK, 0, -1):
                nearby_dates = self._get_centered_window(dt.replace(year=dt.year - yeardelta))
                proxy_dates.extend(nearby_dates)

            codes_of_species_sighted = set()

            region_code = self._get_best_region_from_coords(lat, lng, location_fallback)

            for proxy_date in proxy_dates:
                results = self.get_sightings_on_date(region_code, lat, lng, proxy_date, location_fallback=location_fallback)
                if not results or not results.get("sightings"):
                    continue
                region_code = results.get("region_code")
                sightings = results.get("sightings", [])
                for sighting in sightings:
                    codes_of_species_sighted.add(sighting["speciesCode"])

            species_dict = self.get_species_code_dict()
            data = [species_dict[code] for code in codes_of_species_sighted if code in species_dict]
            result = {
                "region_code": region_code,
                "dates": [proxy_date.strftime("%Y/%m/%d") for proxy_date in proxy_dates],
                "sightings": data
            }
            return result

        except ValueError:
            return None
        
    def get_sightings_on_date(self, region_code: str | None, lat: float | None, lng: float | None, timestamp: str | datetime.datetime, location_fallback: str | None = None) -> set:
        try:
            if isinstance(timestamp, str):
                dt = datetime.datetime.strptime(timestamp[:10], "%Y:%m:%d")
            elif isinstance(timestamp, datetime.datetime):
                dt = timestamp
            formatted_date = dt.strftime("%Y/%m/%d")
        except ValueError:
            return None

        if not region_code:
            region_code = self._get_best_region_from_coords(lat, lng, location_fallback)

        if not region_code:
            return None

        endpoint = f"{self.base_url}/data/obs/{region_code}/historic/{formatted_date}"
        headers = {"x-ebirdapitoken": self.api_token}

        try:
            data = self._get(endpoint, headers=headers)
            codes_of_species_sighted = {obj["speciesCode"] for obj in data}
            species_dict = self.get_species_code_dict()
            results = [species_dict[code] for code in codes_of_species_sighted if code in species_dict]

            return {
                "region_code": region_code,
                "dates": [formatted_date],
                "sightings": results
            }
        except requests.exceptions.RequestException:
            return None

    def get_species_code_dict(self) -> dict[str, any]:
        endpoint = f"{self.base_url}/ref/taxonomy/ebird"
        params = {"fmt": "json"}
        headers = {"x-ebirdapitoken": self.api_token}
        data = self._get(endpoint, params=params, headers=headers)
        return {item["speciesCode"]: item for item in data}

    def _get_best_region_from_coords(self, lat: float | None, lng: float | None, location_fallback: str | None = None) -> str | None:
        if lat is not None and lng is not None:
            region_code = self._get_region_from_coords(lat, lng)
            if region_code:
                return region_code
            
            region_code = self._get_nearest_hotspot_region(lat, lng)
            if region_code:
                return region_code

        region_code = self._get_region_from_fallback(location_fallback)
        if region_code:
            print(f"⚠️ GPS coordinates not available, using fallback region: {region_code}")
            return region_code

        default_region = os.getenv("DEFAULT_EBIRD_REGION")
        if default_region:
            print(f"⚠️ GPS coordinates and fallback not available, using default region: {default_region}")
            return default_region

        print("❌ No GPS coordinates, fallback, or default region available to determine location for eBird sightings.")
        return None

    def _get_region_from_coords(self, lat: float, lng: float) -> str | None:
        endpoint = f"{self.base_url}/ref/geo/pos/{lat}/{lng}?fmt=json"
        headers = {"x-ebirdapitoken": self.api_token}
        try:
            data = self._get(endpoint, headers=headers)
            if data and "code" in data:
                return data["code"]
            return None
        except Exception:
            return None

    def _get_region_from_fallback(self, fallback: str | None) -> str | None:
        if not fallback:
            return None
        fallback = fallback.strip()
        if fallback == "":
            return None
        return fallback

    def _get_nearest_hotspot_region(self, lat: float, lng: float) -> str | None:
        endpoint = f"{self.base_url}/ref/hotspot/geo"
        headers = {"x-ebirdapitoken": self.api_token}
        params = {"lat": lat, "lng": lng, "dist": 50, "fmt": "json"}
        try:
            data = self._get(endpoint, headers=headers, params=params)
            if data:
                closest_hotspot = data[0]
                loc_id = closest_hotspot["locId"]
                return self._get_region_from_hotspot_id(loc_id)
            return None
        except Exception:
            return None

    def _get_region_from_hotspot_id(self, loc_id: str) -> str | None:
        endpoint = f"{self.base_url}/ref/hotspot/info/{loc_id}"
        headers = {"x-ebirdapitoken": self.api_token, "fmt": "json"}
        try:
            data = self._get(endpoint, headers=headers)
            if "subnational2Code" in data:
                return data["subnational2Code"]
            return data.get("subnational1Code")
        except Exception:
            return None

    def _get(self, endpoint: str, params: dict[str, any] | None = None, headers: dict[str, any] | None = None) -> any:
        if DEBUG:
            if params:
                query_string = f"?{urlencode(params)}"
            else:
                query_string = ""
            full_url = f"{endpoint}{query_string}"
            print(f"Making API request: GET {full_url}")

        response = self.session.get(endpoint, params=params, headers=headers)

        request = response.request
        full_url = request.url

        if DEBUG:
            if response.status_code in self.cache_allowable_codes and getattr(response, "from_cache", False):
                print(f"⚡️ [CACHE HIT]      {request.url} - Status code: {response.status_code}")
            elif response.status_code in self.cache_allowable_codes:
                print(f"📡 [CACHE MISS]     {request.url} - Status code: {response.status_code}")
            else:
                print(f"❌ [CACHE DISABLED] {request.url} - Status code: {response.status_code}")

        if response.status_code == 400:
            print(f"❌ Bad request to eBird API: {response.text}")
            # 1. Print Request Method and URL
            print(f"Request: GET {request.url}")

            # 2. Print Request Headers
            print("\n--- REQUEST HEADERS ---")
            for key, value in request.headers.items():
                print(f"{key}: {value}")

        if response.status_code == 500:
            print(f"❌ Server error from eBird API: {response.text}")
            # 1. Print Request Method and URL
            print(f"Request: GET {request.url}")

            # 2. Print Request Headers
            print("\n--- REQUEST HEADERS ---")
            for key, value in request.headers.items():
                print(f"{key}: {value}")

            # 3. Print Response Headers
            print("\n--- RESPONSE HEADERS ---")
            for key, value in (response.headers or {}).items():
                print(f"{key}: {value}")

            print("\n--- RESPONSE BODY ---")
            print(response.text)

        response.raise_for_status()
        return response.json()

    @staticmethod
    def _get_centered_window(target_date):
        start_date = target_date - datetime.timedelta(days=TIME_OF_YEAR_PROXY_DAYS/2)
        return [start_date + datetime.timedelta(days=x) for x in range(TIME_OF_YEAR_PROXY_DAYS + 1)]
