import datetime

import requests

TIME_OF_YEAR_PROXY_DAYS = 4
TIME_OF_YEAR_YEARS_BACK = 2


class EBirdSightingsService:
    """Resolve eBird species sightings from location and taxonomy services."""

    def __init__(self, api, location_service, taxonomy_service):
        """Create a sightings service backed by eBird collaborators."""
        self.api = api
        self.location_service = location_service
        self.taxonomy_service = taxonomy_service

    def get_sightings_in_region(self, lat: float | None, lng: float | None, location_fallback: str | None = None) -> set:
        """Return species codes reported in the best region for a location."""
        region_code = self.location_service.get_best_region_from_coords(lat, lng, location_fallback)
        if not region_code:
            return None

        data = self.api.get_species_list(region_code)
        return {
            "region_code": region_code,
            "sightings": set(data),
        }

    def get_sightings_for_time_of_year(self, lat: float | None, lng: float | None, timestamp_str: str, location_fallback: str | None = None) -> set:
        """Return species reported near the same date in recent prior years."""
        try:
            dt = datetime.datetime.strptime(timestamp_str[:10], "%Y:%m:%d")
            proxy_dates = []
            for yeardelta in range(TIME_OF_YEAR_YEARS_BACK, 0, -1):
                proxy_dates.extend(self.get_centered_window(dt.replace(year=dt.year - yeardelta)))

            codes_of_species_sighted = set()
            region_code = self.location_service.get_best_region_from_coords(lat, lng, location_fallback)

            for proxy_date in proxy_dates:
                results = self.get_sightings_on_date(region_code, lat, lng, proxy_date, location_fallback=location_fallback)
                if not results or not results.get("sightings"):
                    continue
                region_code = results.get("region_code")
                for sighting in results.get("sightings", []):
                    codes_of_species_sighted.add(sighting["speciesCode"])

            species_dict = self.taxonomy_service.get_species_code_dict()
            return {
                "region_code": region_code,
                "dates": [proxy_date.strftime("%Y/%m/%d") for proxy_date in proxy_dates],
                "sightings": [species_dict[code] for code in codes_of_species_sighted if code in species_dict],
            }

        except ValueError:
            return None

    def get_sightings_on_date(self, region_code: str | None, lat: float | None, lng: float | None, timestamp: str | datetime.datetime, location_fallback: str | None = None) -> set:
        """Return species reported in a region on a specific historical date."""
        try:
            if isinstance(timestamp, str):
                dt = datetime.datetime.strptime(timestamp[:10], "%Y:%m:%d")
            elif isinstance(timestamp, datetime.datetime):
                dt = timestamp
            formatted_date = dt.strftime("%Y/%m/%d")
        except ValueError:
            return None

        if not region_code:
            region_code = self.location_service.get_best_region_from_coords(lat, lng, location_fallback)

        if not region_code:
            return None

        try:
            data = self.api.get_historic_observations(region_code, formatted_date)
            codes_of_species_sighted = {obj["speciesCode"] for obj in data}
            species_dict = self.taxonomy_service.get_species_code_dict()
            results = [species_dict[code] for code in codes_of_species_sighted if code in species_dict]

            return {
                "region_code": region_code,
                "dates": [formatted_date],
                "sightings": results,
            }
        except requests.exceptions.RequestException:
            return None

    @staticmethod
    def get_centered_window(target_date):
        """Return dates centered around a target date for sightings lookup."""
        start_date = target_date - datetime.timedelta(days=TIME_OF_YEAR_PROXY_DAYS / 2)
        return [start_date + datetime.timedelta(days=x) for x in range(TIME_OF_YEAR_PROXY_DAYS + 1)]
