import io
import subprocess
import json
from PIL import Image
import PIL
import rawpy
from terminal_image import TerminalImage

# Metadata Tag Constants
TAG_TIMESTAMP = "Composite:GPSDateTime"
TAG_TIMESTAMP2 = "EXIF:CreateDate"
TAG_LATITUDE = "Composite:GPSLatitude"
TAG_LONGITUDE = "Composite:GPSLongitude"


def get_image_type(data):
    """Detects type from raw bytes."""
    if len(data) < 12:
        return 'unknown'

    # JPEG starts with FF D8 FF
    if data.startswith(b'\xff\xd8\xff'):
        return 'jpeg'

    # CR3 has 'ftypcrx ' starting at offset 4
    if data[4:12] == b'ftypcrx ':
        return 'cr3'

    return 'unknown'

def detect_file_type(file_path):
    """Reads file data and calls get_image_type."""
    try:
        with open(file_path, 'rb') as f:
            # Only read the first 12 bytes for efficiency
            header_data = f.read(12)
            return get_image_type(header_data)
    except (FileNotFoundError, PermissionError, IOError):
        return 'unknown'


def get_pillow_from_cr3(cr3_path: str) -> Image.Image:
    """
    Extracts the full-size embedded JPEG preview from a CR3 file
    and returns it as a Pillow Image.
    """
    with rawpy.imread(cr3_path) as raw:
        try:
            # Extract the embedded JPEG instead of demosaicing the whole raw
            # This is extremely fast compared to processing the raw sensor data
            thumb = raw.extract_thumb()
            if thumb.format == rawpy.ThumbFormat.JPEG:
                return Image.open(io.BytesIO(thumb.data))
        except rawpy.LibRawNoThumbnailError:
            pass

        # Fallback if no thumb exists: do a quick demosaic
        rgb = raw.postprocess(use_camera_wb=True, half_size=True)
        return Image.fromarray(rgb)

def get_pillow_from_file(file_path: str) -> Image.Image:
    """
    Detects file type and returns a PIL Image object.
    Handles CR3 raw files and standard JPEGs.
    """
    file_type = detect_file_type(file_path)

    if file_type == 'cr3':
        # Process RAW to RGB numpy array, then to PIL
        return get_pillow_from_cr3(file_path)

    elif file_type == 'jpeg':
        # Standard PIL open
        return Image.open(file_path)

    else:
        raise PIL.UnidentifiedImageError(f"Unsupported image type for {file_path}; only JPEG and CR3 files are supported")

def display_image_from_file(file_path: str) -> None:
    image = get_pillow_from_file(file_path)
    try:
        TerminalImage.display(image)
    finally:
        image.close()


def get_cr3_metadata(cr3_path: str) -> dict:
    """
    Calls ExifTool via subprocess to extract GPS and timestamp data.
    Returns a dictionary of raw tags.
    """
    try:
        # We request output in JSON format for easy parsing
        cmd = ["exiftool", "-json", "-G", "-n", cr3_path]
        result = subprocess.run(cmd, capture_output=True, text=True, check=True)
        metadata_list = json.loads(result.stdout)

        if metadata_list:
            return metadata_list[0]

    except Exception as e:
        print(f"Error reading metadata with ExifTool: {e}")

    return {}


def extract_coordinates_and_time(metadata: dict) -> tuple:
    """Parses decimal GPS coordinates and timestamp from raw ExifTool dict."""
    # 1. Fetch Timestamp
    timestamp = metadata.get(TAG_TIMESTAMP, metadata.get(TAG_TIMESTAMP2, None))

    # 2. Fetch Decimal Lat/Lng
    lat = metadata.get(TAG_LATITUDE, None)
    lng = metadata.get(TAG_LONGITUDE, None)

    lat_float = float(lat) if lat is not None else None
    lng_float = float(lng) if lng is not None else None

    return lat_float, lng_float, timestamp
