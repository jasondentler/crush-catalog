import math
import os

LOCATION_CACHE_RADIUS_METERS = 30
EARTH_RADIUS_METERS = 6371000
_CACHE_MISS = object()


class EBirdLocationService:
    """Resolve eBird regions and hotspots from coordinates and fallbacks."""

    def __init__(self, api):
        """Create a location resolver backed by an eBird API client."""
        self.api = api
        self._best_region_cache = []
        self._nearest_hotspot_cache = []

    def get_location_info(self, lat: float | None, lng: float | None, location_fallback: str | None = None) -> dict:
        """Return region and nearest hotspot metadata for GPS coordinates."""
        region_code = None
        hotspot = None

        if lat is not None and lng is not None:
            region_code = self.get_best_region_from_coords(lat, lng, None)
            hotspot = self.get_nearest_hotspot(lat, lng)
            if not region_code and hotspot:
                region_code = self.get_region_from_hotspot_id(hotspot["locId"])

        print(
            "📍 Location info "
            f"lat={lat} lng={lng} region={region_code} "
            f"hotspot={hotspot.get('locName') if hotspot else None}"
        )

        return {
            "region_code": region_code,
            "hotspot_id": hotspot.get("locId") if hotspot else None,
            "hotspot_name": hotspot.get("locName") if hotspot else None,
        }

    def get_best_region_from_coords(self, lat: float | None, lng: float | None, location_fallback: str | None = None) -> str | None:
        """Resolve the best eBird region from GPS, hotspot, fallback, or default."""
        cached_region = self._get_cached_best_region(lat, lng, location_fallback)
        if cached_region is not _CACHE_MISS:
            return cached_region

        if lat is not None and lng is not None:
            region_code = self.get_region_from_coords(lat, lng)
            if region_code:
                self._cache_best_region(lat, lng, location_fallback, region_code)
                return region_code

            region_code = self.get_nearest_hotspot_region(lat, lng)
            if region_code:
                self._cache_best_region(lat, lng, location_fallback, region_code)
                return region_code

        region_code = self.get_region_from_fallback(location_fallback)
        if region_code:
            print(f"⚠️ GPS coordinates not available, using fallback region: {region_code}")
            self._cache_best_region(lat, lng, location_fallback, region_code)
            return region_code

        default_region = os.getenv("DEFAULT_EBIRD_REGION")
        if default_region:
            print(f"⚠️ GPS coordinates and fallback not available, using default region: {default_region}")
            self._cache_best_region(lat, lng, location_fallback, default_region)
            return default_region

        print("❌ No GPS coordinates, fallback, or default region available to determine location for eBird sightings.")
        self._cache_best_region(lat, lng, location_fallback, None)
        return None

    def get_region_from_coords(self, lat: float, lng: float) -> str | None:
        """Look up the eBird region code containing GPS coordinates."""
        try:
            data = self.api.get_region_from_coords(lat, lng)
            if data and "code" in data:
                return data["code"]
            return None
        except Exception:
            return None

    def get_region_from_fallback(self, fallback: str | None) -> str | None:
        """Normalize a caller-provided fallback eBird region code."""
        if not fallback:
            return None
        fallback = fallback.strip()
        if fallback == "":
            return None
        return fallback

    def get_nearest_hotspot_region(self, lat: float, lng: float) -> str | None:
        """Return the region code for the nearest eBird hotspot."""
        closest_hotspot = self.get_nearest_hotspot(lat, lng)
        if not closest_hotspot:
            return None

        return self.get_region_from_hotspot_id(closest_hotspot["locId"])

    def get_nearest_hotspot(self, lat: float, lng: float) -> dict | None:
        """Return the nearest hotspot to GPS coordinates, using a local cache."""
        cached_hotspot = self._get_cached_nearest_hotspot(lat, lng)
        if cached_hotspot is not _CACHE_MISS:
            return cached_hotspot

        try:
            data = self.api.get_hotspots_near(lat, lng)
            if data:
                closest_hotspot = self.closest_hotspot(lat, lng, data)
                self._cache_nearest_hotspot(lat, lng, closest_hotspot)
                return closest_hotspot
            self._cache_nearest_hotspot(lat, lng, None)
            return None
        except Exception:
            self._cache_nearest_hotspot(lat, lng, None)
            return None

    def get_region_from_hotspot_id(self, loc_id: str) -> str | None:
        """Return the county or state/province region for a hotspot ID."""
        try:
            data = self.api.get_hotspot_info(loc_id)
            if "subnational2Code" in data:
                return data["subnational2Code"]
            return data.get("subnational1Code")
        except Exception:
            return None

    def _get_cached_best_region(self, lat, lng, location_fallback):
        """Return a cached best-region result when coordinates are nearby."""
        fallback = self.normalize_fallback(location_fallback)
        default_region = self.normalize_fallback(os.getenv("DEFAULT_EBIRD_REGION"))
        for item in self._best_region_cache:
            if (
                item["fallback"] == fallback
                and item["default_region"] == default_region
                and self.same_cached_location(item, lat, lng)
            ):
                return item["region_code"]
        return _CACHE_MISS

    def _cache_best_region(self, lat, lng, location_fallback, region_code):
        """Store a best-region lookup result in memory."""
        self._best_region_cache.append({
            "lat": lat,
            "lng": lng,
            "fallback": self.normalize_fallback(location_fallback),
            "default_region": self.normalize_fallback(os.getenv("DEFAULT_EBIRD_REGION")),
            "region_code": region_code,
        })

    def _get_cached_nearest_hotspot(self, lat, lng):
        """Return a cached nearest-hotspot result when coordinates are nearby."""
        for item in self._nearest_hotspot_cache:
            if self.same_cached_location(item, lat, lng):
                return item["hotspot"]
        return _CACHE_MISS

    def _cache_nearest_hotspot(self, lat, lng, hotspot):
        """Store a nearest-hotspot lookup result in memory."""
        self._nearest_hotspot_cache.append({
            "lat": lat,
            "lng": lng,
            "hotspot": hotspot,
        })

    @classmethod
    def same_cached_location(cls, item, lat, lng):
        """Return whether coordinates match a cached item within the radius."""
        if item["lat"] is None or item["lng"] is None or lat is None or lng is None:
            return item["lat"] is None and item["lng"] is None and lat is None and lng is None

        return cls.distance_meters(item["lat"], item["lng"], lat, lng) <= LOCATION_CACHE_RADIUS_METERS

    @classmethod
    def closest_hotspot(cls, lat, lng, hotspots):
        """Choose the hotspot with the shortest distance to coordinates."""
        closest_hotspot = None
        closest_distance = None

        for hotspot in hotspots:
            hotspot_lat = hotspot.get("lat")
            hotspot_lng = hotspot.get("lng")
            if hotspot_lat is None or hotspot_lng is None:
                continue

            distance = cls.distance_meters(lat, lng, float(hotspot_lat), float(hotspot_lng))
            if closest_distance is None or distance < closest_distance:
                closest_hotspot = hotspot
                closest_distance = distance

        return closest_hotspot or hotspots[0]

    @staticmethod
    def normalize_fallback(location_fallback):
        """Normalize blank fallback strings to None."""
        if not location_fallback:
            return None
        fallback = location_fallback.strip()
        return fallback or None

    @staticmethod
    def distance_meters(lat1, lng1, lat2, lng2):
        """Calculate haversine distance between two coordinate pairs."""
        lat1_r = math.radians(lat1)
        lat2_r = math.radians(lat2)
        delta_lat = math.radians(lat2 - lat1)
        delta_lng = math.radians(lng2 - lng1)

        a = (
            math.sin(delta_lat / 2) ** 2
            + math.cos(lat1_r) * math.cos(lat2_r) * math.sin(delta_lng / 2) ** 2
        )
        return EARTH_RADIUS_METERS * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))
