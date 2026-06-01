DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 8000
DEFAULT_MODEL_ENV = "BIRDER_MODEL"
DEFAULT_DEVICE_ENV = "COMPUTE_DEVICE"
DEFAULT_EBIRD_TOKEN_ENV = "EBIRD_TOKEN"
DEFAULT_EBIRD_REGION_ENV = "DEFAULT_EBIRD_REGION"
NON_AVIAN_CONFIDENCE_THRESHOLD = 0.85

SCIENTIFIC_NAME_ALIAS_OVERRIDES = {
    "phalacrocorax auritus": "nannopterum auritum",
    "phalacrocorax brasilianus": "nannopterum brasilianum",
    # "bubulcus ibis": "ardea ibis" # Cattle Egret --> Western Cattle Egret
}
