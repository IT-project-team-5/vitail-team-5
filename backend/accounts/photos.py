"""Validated avatar storage shared by account, café and dog endpoints."""
import base64
import binascii
import io
import uuid
import warnings

from django.core.files.base import ContentFile
from django.db import transaction
from PIL import Image, ImageOps, UnidentifiedImageError
from rest_framework import serializers
from rest_framework.exceptions import ParseError
from rest_framework.parsers import JSONParser

MAX_IMAGE_BYTES = 4 * 1024 * 1024
MAX_IMAGE_PIXELS = 16_000_000


class PhotoJSONParser(JSONParser):
    def parse(self, stream, media_type=None, parser_context=None):
        # DRF reads the request stream directly; Django's request.body size guard
        # alone does not bound JSON parsing. Read only the maximum payload here.
        limit = 6 * 1024 * 1024
        payload = stream.read(limit + 1)
        if len(payload) > limit:
            raise ParseError("Choose an image smaller than 4 MB.")
        return super().parse(io.BytesIO(payload), media_type, parser_context)


def photo_url(photo, request=None):
    if not photo:
        return None
    url = photo.url
    return request.build_absolute_uri(url) if request else url


class ImageUploadSerializer(serializers.Serializer):
    image_base64 = serializers.CharField(
        trim_whitespace=False, max_length=4 * ((MAX_IMAGE_BYTES + 2) // 3)
    )

    def validate_image_base64(self, value):
        try:
            data = base64.b64decode(value, validate=True)
        except (ValueError, binascii.Error) as exc:
            raise serializers.ValidationError("Choose a valid image.") from exc
        if not data or len(data) > MAX_IMAGE_BYTES:
            raise serializers.ValidationError("Choose an image smaller than 4 MB.")
        try:
            with warnings.catch_warnings():
                warnings.simplefilter("error", Image.DecompressionBombWarning)
                with Image.open(io.BytesIO(data)) as source:
                    if source.format not in {"JPEG", "PNG", "WEBP"}:
                        raise ValueError("Unsupported image format")
                    if source.width * source.height > MAX_IMAGE_PIXELS:
                        raise ValueError("Image dimensions are too large")
                    source.load()
                    oriented = ImageOps.exif_transpose(source)
                    oriented.thumbnail((1024, 1024))
                    # A fresh RGB canvas drops location/EXIF, ICC and other metadata.
                    image = Image.new("RGB", oriented.size, "white")
                    rgba = oriented.convert("RGBA")
                    image.paste(rgba, mask=rgba.getchannel("A"))
                    output = io.BytesIO()
                    image.save(output, format="JPEG", quality=88, optimize=True)
        except (UnidentifiedImageError, OSError, ValueError, SyntaxError,
                Image.DecompressionBombError, Image.DecompressionBombWarning) as exc:
            raise serializers.ValidationError(
                "Choose a JPEG, PNG or WebP image up to 16 megapixels."
            ) from exc
        return output.getvalue()


def replace_photo(instance, field_name, jpeg):
    """Caller holds a row lock; delete the replaced file only after DB commit."""
    field = getattr(instance, field_name)
    previous_name, storage = field.name, field.storage
    field.save(f"{uuid.uuid4().hex}.jpg", ContentFile(jpeg), save=False)
    try:
        instance.save(update_fields=[field_name])
    except Exception:
        storage.delete(field.name)
        raise
    if previous_name and previous_name != field.name:
        transaction.on_commit(lambda: storage.delete(previous_name))
