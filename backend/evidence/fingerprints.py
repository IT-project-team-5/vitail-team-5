import hashlib
import json


def request_fingerprint(data):
    """Canonical request identity, shared by validation and atomic receipt replay."""
    fields = {key: value for key, value in data.items() if key not in {"request_id", "upload"}}
    upload = data.get("upload")
    if upload:
        fields["upload"] = {key: upload[key] for key in ("sha256", "filename", "content_type")}
    return hashlib.sha256(json.dumps(fields, sort_keys=True, default=str, separators=(",", ":")).encode()).hexdigest()
