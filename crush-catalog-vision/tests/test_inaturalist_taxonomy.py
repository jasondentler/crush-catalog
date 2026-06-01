import os
import sys
import zipfile
from io import BytesIO
from pathlib import Path

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "src")))

from crush_catalog_vision.services.inaturalist_taxonomy import (  # noqa: E402
    DUBLIN_CORE_TERMS,
    GBIF_TERMS,
    INaturalistTaxonomyService,
    VERNACULAR_NAME_ROWTYPE,
)


class FakeRow:
    def __init__(self, data, extensions=None, rowtype=None, row_id=None):
        self.data = data
        self.extensions = extensions or []
        self.rowtype = rowtype
        self.id = row_id


class FakeArchive:
    def __init__(self, rows):
        self.rows = rows

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        return False

    def __iter__(self):
        return iter(self.rows)


def test_inaturalist_taxonomy_reads_preferred_english_vernacular_name(tmp_path):
    archive_path = tmp_path / "inaturalist-taxonomy.dwca.zip"
    write_english_vernacular_file(archive_path)

    rows = [
        FakeRow(
            {
                "http://rs.tdwg.org/dwc/terms/scientificName": "Canis lupus familiaris",
            },
            extensions=[
                FakeRow(
                    {
                        f"{GBIF_TERMS}vernacularName": "Chien",
                        f"{GBIF_TERMS}language": "fr",
                        f"{GBIF_TERMS}isPreferredName": "true",
                    },
                    rowtype=VERNACULAR_NAME_ROWTYPE,
                ),
                FakeRow(
                    {
                        f"{GBIF_TERMS}vernacularName": "Domestic Dog",
                        f"{GBIF_TERMS}language": "en",
                        f"{GBIF_TERMS}isPreferredName": "true",
                    },
                    rowtype=VERNACULAR_NAME_ROWTYPE,
                ),
            ],
        ),
    ]
    service = INaturalistTaxonomyService(
        archive_path=archive_path,
        reader_factory=lambda path: FakeArchive(rows),
    )

    assert service.get_common_name("Canis lupus familiaris") == "Domestic Dog"


def test_inaturalist_taxonomy_prefers_english_extension_over_localized_core_name(tmp_path):
    archive_path = tmp_path / "inaturalist-taxonomy.dwca.zip"
    write_english_vernacular_file(archive_path)

    service = INaturalistTaxonomyService(
        archive_path=archive_path,
        reader_factory=lambda path: FakeArchive([
            FakeRow(
                {
                    "scientificName": "Canis familiaris",
                    "preferredCommonName": "犬",
                },
                extensions=[
                    FakeRow(
                        {
                            f"{GBIF_TERMS}vernacularName": "Dog",
                            f"{GBIF_TERMS}language": "en",
                            f"{GBIF_TERMS}isPreferredName": "true",
                        },
                        rowtype=VERNACULAR_NAME_ROWTYPE,
                    ),
                ],
            )
        ]),
    )

    assert service.get_common_name("Canis familiaris") == "Dog"


def test_inaturalist_taxonomy_ignores_non_english_vernacular_names(tmp_path):
    archive_path = tmp_path / "inaturalist-taxonomy.dwca.zip"
    write_english_vernacular_file(archive_path)

    service = INaturalistTaxonomyService(
        archive_path=archive_path,
        reader_factory=lambda path: FakeArchive([
            FakeRow(
                {
                    "scientificName": "Canis familiaris",
                },
                extensions=[
                    FakeRow(
                        {
                            f"{GBIF_TERMS}vernacularName": "犬",
                            f"{DUBLIN_CORE_TERMS}language": "zh",
                        },
                        rowtype=VERNACULAR_NAME_ROWTYPE,
                    ),
                ],
            )
        ]),
    )

    assert service.get_common_name("Canis familiaris") is None


def test_inaturalist_taxonomy_uses_core_preferred_common_name(tmp_path):
    archive_path = tmp_path / "inaturalist-taxonomy.dwca.zip"
    write_english_vernacular_file(archive_path)

    service = INaturalistTaxonomyService(
        archive_path=archive_path,
        reader_factory=lambda path: FakeArchive([
            FakeRow({
                "scientificName": "Felis catus",
                "preferredCommonName": "Domestic Cat",
            })
        ]),
    )

    assert service.get_common_name("felis catus") == "Domestic Cat"


def test_inaturalist_taxonomy_joins_english_vernacular_file_to_dwca_reader_rows(tmp_path):
    archive_path = tmp_path / "inaturalist-taxonomy.dwca.zip"
    write_english_vernacular_file(
        archive_path,
        "id,vernacularName,language,locality,countryCode,source,lexicon,contributor,created\n"
        "47144,Domestic Dog,en,New Zealand Zone, NZ,,English,cwarneke,2008-04-02T13:53:33Z\n"
    )

    service = INaturalistTaxonomyService(
        archive_path=archive_path,
        reader_factory=lambda path: FakeArchive([
            FakeRow(
                {
                    "scientificName": "Canis familiaris",
                },
                extensions=[
                    FakeRow(
                        {
                            f"{GBIF_TERMS}vernacularName": "犬",
                            f"{DUBLIN_CORE_TERMS}language": "zh",
                        },
                        rowtype=VERNACULAR_NAME_ROWTYPE,
                    ),
                ],
                row_id="47144",
            )
        ]),
    )

    assert service.get_common_name("Canis familiaris") == "Domestic Dog"


def test_inaturalist_taxonomy_downloads_archive_when_missing(tmp_path):
    archive_path = tmp_path / "inaturalist-taxonomy.dwca.zip"
    archive_bytes = BytesIO()
    with zipfile.ZipFile(archive_bytes, "w") as archive:
        archive.writestr("VernacularNames-english.csv", "id,vernacularName,language\n")

    class FakeResponse:
        def raise_for_status(self):
            pass

        def iter_content(self, chunk_size):
            yield archive_bytes.getvalue()

    class FakeSession:
        def get(self, url, stream, timeout):
            assert url == "https://example.test/taxonomy.zip"
            assert stream is True
            assert timeout == 120
            return FakeResponse()

    service = INaturalistTaxonomyService(
        archive_path=archive_path,
        archive_url="https://example.test/taxonomy.zip",
        reader_factory=lambda path: FakeArchive([]),
        session=FakeSession(),
    )

    assert service.get_common_names_by_scientific_name() == {}
    assert archive_path.read_bytes() == archive_bytes.getvalue()


def write_english_vernacular_file(archive_path, contents=None):
    contents = contents or "id,vernacularName,language,locality,countryCode,source,lexicon,contributor,created\n"
    with zipfile.ZipFile(archive_path, "w") as archive:
        archive.writestr("VernacularNames-english.csv", contents)
