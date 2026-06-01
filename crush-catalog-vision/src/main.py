import os
from pathlib import Path
from crush_catalog_vision.clients.ebird_client import EBirdClient
from crush_catalog_vision.identification.scoring import identify, load_env_file
from crush_catalog_vision.vision.bird_identifier import BirdIdentifier


def main():
    """Run the sample CLI workflow against the configured photo folder."""
    print("🪶 Starting Crush Catalog Bird Identification Workflow")
    load_env_file()

    # Initialize the class (loads the heavy model to GPU once)
    birder_model = os.getenv("BIRDER_MODEL")
    print(f"🪶💾 Birder Model:\t{birder_model}")
    compute_device = os.getenv("COMPUTE_DEVICE")
    print(f"  💻 Compute Device:\t{compute_device}")

    # 🎯 FETCH THE TOKEN FROM THE ENVIRONMENT SECURELY
    print("🔐 Fetching eBird API token from environment...")
    ebird_token = os.getenv("EBIRD_TOKEN")

    # Perfect class matching
    print("🔍 Initializing Bird Identifier...")
    identifier = BirdIdentifier(model_name=birder_model, device=compute_device)
    print("🔍 Initializing eBird Client...")
    ebird = EBirdClient(ebird_token)

    print("🔍 Testing eBird API connectivity with a sample request...")
    ebird.get_sightings_for_time_of_year(34.0, -118.0, "2024-04-19T12:00:00Z")

    print("🔍 Testing eBird API connectivity with a sample request...")
    ebird.get_sightings_for_time_of_year(None, None, "2024-04-19T12:00:00Z")

    # Use .expanduser() to resolve the tilde (~) to your user home directory
    folder_path = Path("~/Pictures/2026/2026-04/2026-04-19").expanduser()

    # 2. Enumerate all files ending in .CR3 (case-insensitive)
    print(f"📂 Scanning folder for CR3 files: {folder_path}")
    for path_obj in folder_path.glob("*.[Cc][Rr]3"):
        cr3_path = str(path_obj.resolve())
        print(f"\n🪶 Processing file: {cr3_path}")
        identify(cr3_path, identifier, ebird)

    # identify(
    #     "/users/jasondentler/Pictures/2026/2026-04/2026-04-19/DA8A5506.CR3",
    #     identifier,
    #     ebird,
    # )


if __name__ == "__main__":
    main()
