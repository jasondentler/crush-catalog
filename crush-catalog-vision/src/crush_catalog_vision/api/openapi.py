OPENAPI_SPEC = {
    "openapi": "3.0.3",
    "info": {
        "title": "Crush Catalog Vision API",
        "version": "0.1.0",
        "description": "Local backend for Lightroom bird and non-bird identification workflows.",
    },
    "servers": [
        {
            "url": "http://127.0.0.1:8000",
            "description": "Default local backend",
        }
    ],
    "paths": {
        "/identify": {
            "post": {
                "summary": "Identify birds and confident non-birds in an uploaded image",
                "requestBody": {
                    "required": True,
                    "content": {
                        "multipart/form-data": {
                            "schema": {
                                "type": "object",
                                "required": ["image_data", "ebird_token"],
                                "properties": {
                                    "image_data": {
                                        "type": "string",
                                        "format": "binary",
                                        "description": "JPEG image payload.",
                                    },
                                    "ebird_token": {
                                        "type": "string",
                                        "description": "eBird API token used for location and taxonomy lookups.",
                                    },
                                    "location_fallback": {
                                        "type": "string",
                                        "description": "Optional eBird region code used when GPS metadata is unavailable.",
                                        "example": "US-TX-167",
                                    },
                                },
                            }
                        }
                    },
                },
                "responses": {
                    "200": {
                        "description": "Identification result or recoverable backend error.",
                        "content": {
                            "application/json": {
                                "schema": {
                                    "$ref": "#/components/schemas/IdentifyResponse"
                                }
                            }
                        },
                    },
                    "400": {
                        "description": "Invalid multipart request.",
                        "content": {
                            "application/json": {
                                "schema": {
                                    "$ref": "#/components/schemas/ErrorResponse"
                                }
                            }
                        },
                    },
                },
            }
        },
        "/location": {
            "post": {
                "summary": "Look up backend eBird location metadata for GPS coordinates",
                "requestBody": {
                    "required": True,
                    "content": {
                        "application/json": {
                            "schema": {
                                "type": "object",
                                "required": ["latitude", "longitude", "ebird_token"],
                                "properties": {
                                    "latitude": {
                                        "type": "number",
                                        "format": "double",
                                    },
                                    "longitude": {
                                        "type": "number",
                                        "format": "double",
                                    },
                                    "ebird_token": {
                                        "type": "string",
                                    },
                                    "location_fallback": {
                                        "type": "string",
                                        "example": "US-TX-167",
                                    },
                                },
                            }
                        }
                    },
                },
                "responses": {
                    "200": {
                        "description": "Location lookup result.",
                        "content": {
                            "application/json": {
                                "schema": {
                                    "$ref": "#/components/schemas/LocationResponse"
                                }
                            }
                        },
                    },
                    "400": {
                        "description": "Invalid lookup request.",
                        "content": {
                            "application/json": {
                                "schema": {
                                    "$ref": "#/components/schemas/ErrorResponse"
                                }
                            }
                        },
                    },
                },
            }
        },
    },
    "components": {
        "schemas": {
            "ErrorResponse": {
                "type": "object",
                "properties": {
                    "error": {
                        "type": "string",
                    }
                },
            },
            "Location": {
                "type": "object",
                "properties": {
                    "source": {"type": "string", "enum": ["gps", "fallback"]},
                    "region_code": {"type": "string", "nullable": True},
                    "hotspot_id": {"type": "string", "nullable": True},
                    "hotspot_name": {"type": "string", "nullable": True},
                },
            },
            "LocationResponse": {
                "type": "object",
                "properties": {
                    "location": {"$ref": "#/components/schemas/Location"},
                    "error": {"type": "string"},
                },
            },
            "TaxonPathItem": {
                "type": "object",
                "properties": {
                    "rank": {"type": "string"},
                    "scientificName": {"type": "string"},
                    "englishName": {"type": "string"},
                },
            },
            "Prediction": {
                "type": "object",
                "additionalProperties": True,
                "properties": {
                    "rank": {"type": "integer"},
                    "class_id": {"type": "integer"},
                    "class_label": {"type": "string"},
                    "species": {"type": "string"},
                    "confidence": {"type": "number"},
                    "comName": {"type": "string"},
                    "sciName": {"type": "string"},
                    "speciesCode": {"type": "string"},
                },
            },
            "Detection": {
                "type": "object",
                "additionalProperties": True,
                "properties": {
                    "detection_id": {"type": "integer"},
                    "box": {
                        "type": "array",
                        "items": {"type": "number"},
                        "minItems": 4,
                        "maxItems": 4,
                    },
                    "predictions": {
                        "type": "array",
                        "items": {"$ref": "#/components/schemas/Prediction"},
                    },
                    "top_prediction": {
                        "nullable": True,
                        "oneOf": [
                            {"$ref": "#/components/schemas/Prediction"},
                            {"type": "null"},
                        ],
                    },
                    "best_match": {
                        "nullable": True,
                        "oneOf": [
                            {"$ref": "#/components/schemas/Prediction"},
                            {"type": "null"},
                        ],
                    },
                    "alternatives": {
                        "type": "array",
                        "items": {"$ref": "#/components/schemas/Prediction"},
                    },
                    "review_suggestion": {
                        "type": "string",
                        "enum": ["not_a_bird"],
                    },
                    "non_avian_prediction": {
                        "type": "object",
                        "additionalProperties": True,
                        "properties": {
                            "species": {"type": "string"},
                            "commonName": {"type": "string"},
                            "taxonKingdom": {"type": "string"},
                            "taxonClass": {"type": "string"},
                            "taxonPath": {
                                "type": "array",
                                "items": {"$ref": "#/components/schemas/TaxonPathItem"},
                            },
                            "aggregate_confidence": {"type": "number"},
                        },
                    },
                },
            },
            "LocalSpecies": {
                "type": "object",
                "properties": {
                    "comName": {"type": "string"},
                    "sciName": {"type": "string"},
                    "speciesCode": {"type": "string"},
                },
            },
            "IdentifyResponse": {
                "type": "object",
                "properties": {
                    "file_path": {"type": "string"},
                    "location_source": {"type": "string", "enum": ["gps", "fallback"]},
                    "location": {"$ref": "#/components/schemas/Location"},
                    "local_species": {
                        "type": "array",
                        "items": {"$ref": "#/components/schemas/LocalSpecies"},
                    },
                    "detections": {
                        "type": "array",
                        "items": {"$ref": "#/components/schemas/Detection"},
                    },
                    "error": {"type": "string"},
                },
            },
        }
    },
}


SWAGGER_UI_HTML = """<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>Crush Catalog Vision API</title>
  <link rel="stylesheet" href="https://unpkg.com/swagger-ui-dist@5/swagger-ui.css">
  <style>
    body { margin: 0; background: #fafafa; }
  </style>
</head>
<body>
  <div id="swagger-ui"></div>
  <script src="https://unpkg.com/swagger-ui-dist@5/swagger-ui-bundle.js"></script>
  <script>
    window.onload = function() {
      window.ui = SwaggerUIBundle({
        url: "/swagger.json",
        dom_id: "#swagger-ui",
        deepLinking: true,
        presets: [SwaggerUIBundle.presets.apis],
        layout: "BaseLayout"
      });
    };
  </script>
</body>
</html>
"""
