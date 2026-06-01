import threading


class EBirdTaxonomyService:
    """Build and cache taxonomy lookup data from eBird API responses."""

    def __init__(self, api):
        """Create a taxonomy service backed by an eBird API client."""
        self.api = api
        self._taxonomy_aliases_cache = None
        self._taxonomy_aliases_loading = False
        self._taxonomy_aliases_lock = threading.Lock()

    def get_species_code_dict(self) -> dict[str, any]:
        """Return current eBird taxonomy keyed by species code."""
        return {item["speciesCode"]: item for item in self.api.get_taxonomy()}

    def get_taxonomy_versions(self) -> list[dict[str, any]]:
        """Return available eBird taxonomy versions."""
        return self.api.get_taxonomy_versions()

    def get_taxonomy(self, version: str | int | float | None = None) -> list[dict[str, any]]:
        """Return eBird taxonomy for the latest or requested taxonomy version."""
        return self.api.get_taxonomy(version)

    def get_scientific_name_aliases(self) -> dict[str, str]:
        """Build aliases from historical scientific names to current names."""
        if self._taxonomy_aliases_cache is not None:
            return self._taxonomy_aliases_cache

        with self._taxonomy_aliases_lock:
            if self._taxonomy_aliases_cache is not None:
                return self._taxonomy_aliases_cache

            current_by_code = self.get_species_code_dict()
            aliases = {}

            for version in self.get_taxonomy_versions():
                authority_version = version.get("authorityVer")
                if not authority_version or version.get("latest"):
                    continue

                for old_taxon in self.get_taxonomy(authority_version):
                    species_code = old_taxon.get("speciesCode")
                    old_scientific_name = old_taxon.get("sciName")
                    current_taxon = current_by_code.get(species_code)
                    current_scientific_name = current_taxon.get("sciName") if current_taxon else None

                    if (
                        old_scientific_name
                        and current_scientific_name
                        and old_scientific_name.lower() != current_scientific_name.lower()
                    ):
                        aliases[old_scientific_name.lower()] = current_scientific_name.lower()

            self._taxonomy_aliases_cache = aliases
            return self._taxonomy_aliases_cache

    def get_cached_scientific_name_aliases(self) -> dict[str, str]:
        """Return preloaded scientific-name aliases without blocking on loading."""
        return self._taxonomy_aliases_cache or {}

    def prefetch_scientific_name_aliases(self):
        """Load scientific-name aliases in a background thread."""
        if self._taxonomy_aliases_cache is not None or self._taxonomy_aliases_loading:
            return

        self._taxonomy_aliases_loading = True

        def load_aliases():
            """Load taxonomy aliases and record preload status."""
            try:
                aliases = self.get_scientific_name_aliases()
                print(f"✅ Preloaded {len(aliases)} eBird taxonomy drift aliases")
            except Exception as exc:
                print(f"⚠️ Could not preload eBird taxonomy drift aliases: {exc}")
            finally:
                self._taxonomy_aliases_loading = False

        thread = threading.Thread(target=load_aliases, name="ebird-taxonomy-alias-prefetch", daemon=True)
        thread.start()

    def get_species_by_scientific_name(self) -> dict[str, any]:
        """Return current eBird taxonomy keyed by lowercase scientific name."""
        species_by_code = self.get_species_code_dict()
        return {
            item["sciName"].lower(): item
            for item in species_by_code.values()
            if item.get("sciName")
        }
