import csv
import os
import threading
import zipfile
from pathlib import Path

import requests

from crush_catalog_vision.api.config import (
    DEFAULT_INATURALIST_TAXONOMY_DWCA_PATH,
    DEFAULT_INATURALIST_TAXONOMY_DWCA_URL,
    INATURALIST_TAXONOMY_DWCA_PATH_ENV,
    INATURALIST_TAXONOMY_DWCA_URL_ENV,
)

DARWIN_CORE_TERMS = "http://rs.tdwg.org/dwc/terms/"
GBIF_TERMS = "http://rs.gbif.org/terms/1.0/"
DUBLIN_CORE_TERMS = "http://purl.org/dc/terms/"
DUBLIN_CORE_ELEMENTS = "http://purl.org/dc/elements/1.1/"
VERNACULAR_NAME_ROWTYPE = f"{GBIF_TERMS}VernacularName"
ENGLISH_VERNACULAR_FILE = "VernacularNames-english.csv"


class INaturalistTaxonomyService:
    """Read iNaturalist taxonomy common names from a Darwin Core Archive."""

    def __init__(
        self,
        archive_path: str | Path | None = None,
        archive_url: str | None = None,
        reader_factory=None,
        session=None,
    ):
        """Create a taxonomy service backed by the iNaturalist DwC-A archive."""
        self.archive_path = Path(
            archive_path
            or os.getenv(INATURALIST_TAXONOMY_DWCA_PATH_ENV)
            or DEFAULT_INATURALIST_TAXONOMY_DWCA_PATH
        )
        self.archive_url = (
            archive_url
            or os.getenv(INATURALIST_TAXONOMY_DWCA_URL_ENV)
            or DEFAULT_INATURALIST_TAXONOMY_DWCA_URL
        )
        self.reader_factory = reader_factory or build_dwca_reader
        self.session = session or requests.Session()
        self._common_names_by_scientific_name = None
        self._lock = threading.Lock()

    def get_common_name(self, scientific_name: str | None) -> str | None:
        """Return the preferred English common name for a scientific name."""
        if not scientific_name:
            return None

        return self.get_common_names_by_scientific_name().get(scientific_name.strip().lower())

    def get_common_names_by_scientific_name(self) -> dict[str, str]:
        """Return iNaturalist common names keyed by lowercase scientific name."""
        if self._common_names_by_scientific_name is not None:
            return self._common_names_by_scientific_name

        with self._lock:
            if self._common_names_by_scientific_name is None:
                self._common_names_by_scientific_name = self._read_common_names()

        return self._common_names_by_scientific_name

    def _read_common_names(self) -> dict[str, str]:
        """Parse the local DwC-A archive into a scientific-name lookup."""
        archive_path = self._ensure_archive()
        english_common_names_by_taxon_id = read_english_common_names_by_taxon_id(archive_path)
        common_names = {}

        with self.reader_factory(archive_path) as archive:
            for row in archive:
                row_data = row_data_dict(row)
                scientific_name = first_value(row_data, "scientificName")
                taxon_id = row_taxon_id(row, row_data)
                common_name = english_common_names_by_taxon_id.get(taxon_id) or preferred_common_name_for_row(row)

                if scientific_name and common_name:
                    common_names.setdefault(scientific_name.strip().lower(), common_name)

        return common_names

    def _ensure_archive(self) -> Path:
        """Download the iNaturalist DwC-A archive when it is not cached locally."""
        if self.archive_path.is_file():
            return self.archive_path

        self.archive_path.parent.mkdir(parents=True, exist_ok=True)
        response = self.session.get(self.archive_url, stream=True, timeout=120)
        response.raise_for_status()

        with self.archive_path.open("wb") as archive_file:
            for chunk in response.iter_content(chunk_size=1024 * 1024):
                if chunk:
                    archive_file.write(chunk)

        return self.archive_path


def build_dwca_reader(archive_path: Path):
    """Return a python-dwca-reader archive reader for the provided path."""
    from dwca.read import DwCAReader

    return DwCAReader(str(archive_path))


def preferred_common_name_for_row(row) -> str | None:
    """Return the best common name for a DwC-A core row."""
    row_data = row_data_dict(row)
    core_common_name = first_value(row_data, "preferredCommonName", "vernacularName", "commonName")

    vernacular_rows = [
        extension
        for extension in getattr(row, "extensions", []) or []
        if is_vernacular_name_row(extension)
    ]
    if not vernacular_rows:
        return core_common_name

    return best_vernacular_name(vernacular_rows) or core_common_name


def read_english_common_names_by_taxon_id(archive_path: Path) -> dict[str, str]:
    """Return English common names keyed by iNaturalist numeric taxon id."""
    common_names = {}
    common_name_specificity = {}

    with zipfile.ZipFile(archive_path) as archive:
        if ENGLISH_VERNACULAR_FILE not in archive.namelist():
            return common_names

        with archive.open(ENGLISH_VERNACULAR_FILE) as common_name_file:
            rows = csv.DictReader((line.decode("utf-8") for line in common_name_file))
            for row in rows:
                taxon_id = (row.get("id") or "").strip()
                common_name = (row.get("vernacularName") or "").strip()
                language = (row.get("language") or "").strip().lower()
                if not taxon_id or not common_name or language not in {"en", "eng"}:
                    continue

                specificity = common_name_specificity_score(row)
                existing_specificity = common_name_specificity.get(taxon_id)
                if existing_specificity is None or specificity < existing_specificity:
                    common_names[taxon_id] = common_name
                    common_name_specificity[taxon_id] = specificity

    return common_names


def common_name_specificity_score(row: dict) -> int:
    """Return lower scores for broader names without locality limits."""
    locality = (row.get("locality") or "").strip()
    country_code = (row.get("countryCode") or "").strip()
    return 1 if locality or country_code else 0


def best_vernacular_name(vernacular_rows) -> str | None:
    """Choose the preferred English vernacular name from DwC-A extension rows."""
    english_fallback = None

    for row in vernacular_rows:
        data = row_data_dict(row)
        language = (first_value(data, "language") or "").lower()
        vernacular_name = first_value(data, "vernacularName")
        if not vernacular_name:
            continue

        if language not in {"en", "eng"}:
            continue

        if language in {"en", "eng"} and is_truthy(first_value(data, "isPreferredName")):
            return vernacular_name

        if not english_fallback:
            english_fallback = vernacular_name

    return english_fallback


def row_taxon_id(row, row_data: dict) -> str | None:
    """Return the numeric taxon id for a DwC-A row."""
    row_id = getattr(row, "id", None)
    if row_id:
        return str(row_id).strip()

    taxon_id = first_value(row_data, "taxonID")
    if not taxon_id:
        return None

    return taxon_id.rstrip("/").split("/")[-1]


def is_vernacular_name_row(row) -> bool:
    """Return whether a DwC-A extension row contains vernacular names."""
    rowtype = getattr(row, "rowtype", None)
    if rowtype == VERNACULAR_NAME_ROWTYPE:
        return True

    if rowtype and "VernacularName" in rowtype:
        return True

    return bool(first_value(row_data_dict(row), "vernacularName"))


def row_data_dict(row) -> dict:
    """Return the data mapping from a python-dwca-reader row-like object."""
    if isinstance(row, dict):
        return row

    return getattr(row, "data", {}) or {}


def first_value(data: dict, *terms: str) -> str | None:
    """Return the first non-empty value for any short or qualified DwC-A term."""
    for term in terms:
        for key in (
            term,
            f"{DARWIN_CORE_TERMS}{term}",
            f"{GBIF_TERMS}{term}",
            f"{DUBLIN_CORE_TERMS}{term}",
            f"{DUBLIN_CORE_ELEMENTS}{term}",
        ):
            value = data.get(key)
            if value is not None and str(value).strip():
                return str(value).strip()

    return None


def is_truthy(value) -> bool:
    """Return whether a Darwin Core text boolean should be treated as true."""
    return str(value).strip().lower() in {"1", "true", "t", "yes", "y"}
