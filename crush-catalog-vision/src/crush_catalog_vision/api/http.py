import re


def parse_multipart_form(body, boundary):
    """Extract supported fields from a multipart/form-data request body."""
    image_data = None
    ebird_token = None
    location_fallback = None
    filename = None

    for part in body.split(b"--" + boundary):
        if not part or part == b"--" or part == b"--\r\n":
            continue

        if b"\r\n\r\n" not in part:
            continue

        headers_section, content = part.split(b"\r\n\r\n", 1)
        content = content.rstrip(b"\r\n")
        headers_text = headers_section.decode("utf-8", errors="ignore")

        if 'name="image_data"' in headers_text:
            image_data = content
            match = re.search(r'filename="([^"]+)"', headers_text)
            if match:
                filename = match.group(1)
        elif 'name="ebird_token"' in headers_text:
            ebird_token = content.decode("utf-8").strip()
        elif 'name="location_fallback"' in headers_text:
            location_fallback = content.decode("utf-8").strip()

    return image_data, ebird_token, location_fallback, filename
