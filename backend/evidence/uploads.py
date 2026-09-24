import base64
import binascii
import hashlib
import io
import warnings
from pathlib import PurePath

from PIL import Image, UnidentifiedImageError
from pypdf import PdfReader
from pypdf.errors import PdfReadError
from rest_framework import serializers
from rest_framework.exceptions import ParseError
from rest_framework.parsers import JSONParser

MAX_BYTES = 4 * 1024 * 1024


class DocumentJSONParser(JSONParser):
    def parse(self, stream, media_type=None, parser_context=None):
        limit = 6 * 1024 * 1024
        payload = stream.read(limit + 1)
        if len(payload) > limit:
            raise ParseError("Choose a file up to 4 MB.")
        return super().parse(io.BytesIO(payload), media_type, parser_context)


def validate_upload(value, filename, kind):
    try:
        data = base64.b64decode(value, validate=True)
    except (ValueError, binascii.Error) as exc:
        raise serializers.ValidationError({"file_base64": "Choose a valid file."}) from exc
    if not data or len(data) > MAX_BYTES:
        raise serializers.ValidationError({"file_base64": "Choose a file up to 4 MB."})
    if kind in {"COUNCIL_REGISTRATION", "MICROCHIP_REGISTRATION"}:
        try:
            if not data.startswith(b"%PDF-"):
                raise ValueError("Not PDF")
            pdf = PdfReader(io.BytesIO(data), strict=True)
            if pdf.is_encrypted or not 1 <= len(pdf.pages) <= 20:
                raise ValueError("Unsupported PDF")
        except (PdfReadError, ValueError, TypeError, KeyError, RecursionError, OSError) as exc:
            raise serializers.ValidationError({"file_base64": "Choose an unencrypted PDF with 1–20 pages."}) from exc
        content_type, extension = "application/pdf", ".pdf"
    else:
        try:
            with warnings.catch_warnings():
                warnings.simplefilter("error", Image.DecompressionBombWarning)
                with Image.open(io.BytesIO(data)) as image:
                    if image.format not in {"JPEG", "PNG"} or image.width * image.height > 16_000_000:
                        raise ValueError("Unsupported photo")
                    image.load()
                    content_type, extension = ("image/jpeg", ".jpg") if image.format == "JPEG" else ("image/png", ".png")
        except (UnidentifiedImageError, OSError, ValueError, SyntaxError, Image.DecompressionBombError, Image.DecompressionBombWarning) as exc:
            raise serializers.ValidationError({"file_base64": "Choose a JPEG or PNG photo up to 16 megapixels."}) from exc
    # A display filename never controls the storage path, file type or extension.
    stem = PurePath((filename or "Document").replace("\\", "/")).stem
    stem = "".join(char for char in stem if char.isprintable() and char not in '/\\')[:120].strip() or "Document"
    return {"bytes": data, "content_type": content_type, "extension": extension,
            "filename": stem + extension, "sha256": hashlib.sha256(data).hexdigest()}
