import re
from zoneinfo import ZoneInfo

from django.utils import timezone
from rest_framework import serializers

from .models import DocumentEntitlement, DocumentKind, DocumentSubmission
from .fingerprints import request_fingerprint
from .policy import council_entitlement, needs_expiry, reward_status
from .uploads import MAX_BYTES, validate_upload


def validate_document_reading(reading):
    def invalid():
        raise serializers.ValidationError({"document_reading": "Use bounded reading suggestions with source, pages_read and known candidate fields."})
    if not isinstance(reading, dict) or set(reading) != {"source", "pages_read", "candidates"}:
        invalid()
    pages = reading["pages_read"]
    if not isinstance(reading["source"], str) or reading["source"] not in {"APPLE_VISION", "PDF_TEXT", "MIXED"} or type(pages) is not int or not 1 <= pages <= 20:
        invalid()
    candidates = reading["candidates"]
    fields = {"registration_number", "council_name", "registry_name", "document_dog_name", "valid_to"}
    if not isinstance(candidates, dict) or not set(candidates) <= fields:
        invalid()
    for values in candidates.values():
        if not isinstance(values, list) or len(values) > 3:
            invalid()
        for item in values:
            if not isinstance(item, dict) or not {"value", "page"} <= set(item) or not set(item) <= {"value", "page", "source"}:
                invalid()
            value, page = item["value"], item["page"]
            if not isinstance(value, str) or not 1 <= len(value) <= 100 or not value.strip() or not value.isprintable():
                invalid()
            if type(page) is not int or not 1 <= page <= pages or ("source" in item and (not isinstance(item["source"], str) or item["source"] not in {"APPLE_VISION", "PDF_TEXT"})):
                invalid()


class DocumentRequestSerializer(serializers.Serializer):
    request_id = serializers.UUIDField()
    dog_id = serializers.IntegerField(min_value=1)
    kind = serializers.ChoiceField(choices=DocumentKind.choices)
    registration_number = serializers.CharField(max_length=100, allow_blank=True, required=False)
    council_name = serializers.CharField(max_length=100, required=False, allow_blank=True)
    registry_name = serializers.CharField(max_length=100, required=False, allow_blank=True)
    document_dog_name = serializers.CharField(max_length=100, required=False, allow_blank=True)
    document_reading = serializers.JSONField(required=False, allow_null=True)
    expected_entitlement_id = serializers.IntegerField(min_value=1, required=False)
    registration_year = serializers.IntegerField(min_value=1, max_value=9999, required=False, allow_null=True)
    event_date = serializers.DateField(required=False, allow_null=True)
    valid_from = serializers.DateField(required=False, allow_null=True)
    valid_to = serializers.DateField(required=False, allow_null=True)
    filename = serializers.CharField(max_length=150, required=False, allow_blank=True)
    file_base64 = serializers.CharField(required=False, trim_whitespace=False, max_length=4 * ((MAX_BYTES + 2) // 3))

    def validate(self, attrs):
        today = timezone.localdate(timezone=ZoneInfo("Australia/Melbourne"))
        kind = attrs["kind"]
        number = attrs.get("registration_number", "").strip()
        attrs["registration_number"] = number
        if attrs.get("file_base64"):
            attrs["upload"] = validate_upload(attrs.pop("file_base64"), attrs.pop("filename", ""), kind)
        else:
            attrs.pop("filename", None)

        # Already accepted requests keep their original receipt even when new
        # rules or expiry would reject a fresh submission.
        # The service checks the fingerprint again under the owner's row lock.
        owner = self.context.get("owner")
        previous = DocumentSubmission.objects.filter(owner=owner, request_id=attrs["request_id"]).first() if owner else None
        if previous and previous.request_fingerprint == request_fingerprint(attrs):
            return attrs
        if kind == DocumentKind.MICROCHIP:
            normalized = re.sub(r"[\s-]", "", number)
            # Older upload receipts normalized the number too. Try that exact
            # accepted representation before applying new upload semantics.
            if previous or not attrs.get("upload"):
                number = normalized
                attrs["registration_number"] = number
        if previous:
            return attrs

        for field in ("registration_number", "council_name", "registry_name", "document_dog_name"):
            if any(not char.isprintable() for char in attrs.get(field, "")):
                raise serializers.ValidationError({field: "Use a single line of printable text."})
        reading = attrs.get("document_reading")
        if reading is not None:
            validate_document_reading(reading)
            if not attrs.get("upload"):
                raise serializers.ValidationError({"document_reading": "Reading suggestions must accompany the original file."})

        if kind == DocumentKind.VET:
            if not attrs.get("event_date") or attrs["event_date"] > today:
                raise serializers.ValidationError({"event_date": "Enter the actual check-up date, today or earlier."})
            if not attrs.get("upload"):
                raise serializers.ValidationError({"file_base64": "Add a photo of the vet check-up evidence."})
            if number or any(attrs.get(field) for field in ("valid_from", "valid_to", "council_name", "registration_year", "registry_name", "document_dog_name", "document_reading", "expected_entitlement_id")):
                raise serializers.ValidationError("Vet check-ups use a visit date and photo.")
        else:
            if not number:
                raise serializers.ValidationError({"registration_number": "Confirm the registration number shown on your document."})
            if attrs.get("registration_year") is not None or attrs.get("event_date") or attrs.get("valid_from"):
                raise serializers.ValidationError("Use the actual Council expiry date, not an assumed registration year or start date.")
            if kind == DocumentKind.MICROCHIP:
                if attrs.get("council_name") or attrs.get("valid_to"):
                    raise serializers.ValidationError("Microchip registration does not expire and does not use Council details.")
                if not attrs.get("upload") and not re.fullmatch(r"[0-9]{15}", number):
                    raise serializers.ValidationError({"registration_number": "Enter 15 digits, or upload proof for a different microchip format."})
            else:
                if not attrs.get("upload") and (not re.fullmatch(r"[A-Za-z0-9 -]+", number) or not re.search(r"[A-Za-z0-9]", number)):
                    raise serializers.ValidationError({"registration_number": "Use letters, numbers, spaces and hyphens from your Animal ID or registration number."})
                if not attrs.get("council_name"):
                    raise serializers.ValidationError({"council_name": "Confirm the Council named on your registration."})
                if not attrs.get("valid_to"):
                    raise serializers.ValidationError({"valid_to": "Confirm the expiry date printed on the registration."})
                if attrs.get("registry_name"):
                    raise serializers.ValidationError({"registry_name": "Council registrations use the Council name."})
        return attrs


class DocumentSubmissionSerializer(serializers.ModelSerializer):
    dog_id = serializers.IntegerField(source="dog_id_snapshot")
    dog_name = serializers.CharField(source="dog_name_snapshot")
    file_url = serializers.SerializerMethodField()
    entitlement_id = serializers.IntegerField(read_only=True)
    reward_status = serializers.SerializerMethodField()
    reward_points = serializers.SerializerMethodField()
    collected_at = serializers.DateTimeField(source="entitlement.collected_at", read_only=True)
    needs_expiry = serializers.SerializerMethodField()
    reward_registration_year = serializers.IntegerField(source="entitlement.registration_year", read_only=True, allow_null=True)

    class Meta:
        model = DocumentSubmission
        fields = ("id", "request_id", "dog_id", "dog_name", "kind", "status", "registration_number", "council_name", "registry_name", "document_dog_name", "document_reading", "registration_year", "reward_registration_year", "needs_expiry", "event_date", "valid_from", "valid_to", "filename", "file_url", "awarded_points", "submitted_at", "entitlement_id", "reward_status", "reward_points", "collected_at")
        read_only_fields = fields

    def get_file_url(self, submission):
        return f"/api/quests/documents/{submission.pk}/file" if submission.file else None

    def get_reward_status(self, submission):
        row = submission.entitlement
        canonical = True
        if row.kind == DocumentKind.COUNCIL and not row.point_entry_id:
            cache = self.__dict__.setdefault("_council_ids", {})
            if row.dog_id_snapshot not in cache:
                current = council_entitlement(DocumentEntitlement.objects.filter(dog_id_snapshot=row.dog_id_snapshot, kind=DocumentKind.COUNCIL))
                cache[row.dog_id_snapshot] = current.pk if current else None
            canonical = cache[row.dog_id_snapshot] == row.pk
        return reward_status(row, canonical=canonical)

    def get_needs_expiry(self, submission):
        return needs_expiry(submission.entitlement)

    def get_reward_points(self, submission):
        return submission.entitlement.promised_points
