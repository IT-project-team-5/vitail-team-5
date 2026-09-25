import re
from zoneinfo import ZoneInfo

from django.utils import timezone
from rest_framework import serializers

from .models import DocumentKind, DocumentSubmission
from .fingerprints import request_fingerprint
from .uploads import MAX_BYTES, validate_upload


class DocumentRequestSerializer(serializers.Serializer):
    request_id = serializers.UUIDField()
    dog_id = serializers.IntegerField(min_value=1)
    kind = serializers.ChoiceField(choices=DocumentKind.choices)
    registration_number = serializers.CharField(max_length=100, allow_blank=True, required=False)
    council_name = serializers.CharField(max_length=100, required=False, allow_blank=True)
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
        # rules or the current registration year would reject a fresh submission.
        # The service checks the fingerprint again under the owner's row lock.
        owner = self.context.get("owner")
        previous = DocumentSubmission.objects.filter(owner=owner, request_id=attrs["request_id"]).first() if owner else None
        if previous and previous.request_fingerprint == request_fingerprint(attrs):
            return attrs
        if kind == DocumentKind.MICROCHIP:
            number = re.sub(r"[\s-]", "", number)
            attrs["registration_number"] = number
        if previous:
            # A reused request ID is resolved as a conflict by the transactional
            # service, not treated as an unrelated new validation failure.
            return attrs

        if any(not char.isprintable() for char in number):
            raise serializers.ValidationError({"registration_number": "Enter a registration number without line breaks."})

        if kind == DocumentKind.VET:
            if not attrs.get("event_date") or attrs["event_date"] > today:
                raise serializers.ValidationError({"event_date": "Enter the actual check-up date, today or earlier."})
            if not attrs.get("upload"):
                raise serializers.ValidationError({"file_base64": "Add a photo of the vet check-up evidence."})
            if number or attrs.get("valid_from") or attrs.get("valid_to") or attrs.get("council_name") or attrs.get("registration_year"):
                raise serializers.ValidationError("Vet check-ups use a visit date and photo.")
        else:
            if bool(number) == bool(attrs.get("upload")):
                raise serializers.ValidationError("Enter the registration details or upload a PDF, JPEG or PNG, not both.")
            if any(attrs.get(field) for field in ("event_date", "valid_from", "valid_to")):
                raise serializers.ValidationError("Registration submissions do not use visit or start/end dates.")
            if attrs.get("upload") or kind == DocumentKind.MICROCHIP:
                if attrs.get("council_name") or attrs.get("registration_year"):
                    raise serializers.ValidationError("Council details are only needed when entering a Council registration number.")
            if kind == DocumentKind.MICROCHIP and number:
                if not re.fullmatch(r"[0-9]{15}", number):
                    raise serializers.ValidationError({"registration_number": "Enter 15 digits, or upload proof for a different microchip format."})
            elif kind == DocumentKind.COUNCIL and number:
                if not re.fullmatch(r"[A-Za-z0-9 -]+", number) or not re.search(r"[A-Za-z0-9]", number):
                    raise serializers.ValidationError({"registration_number": "Use letters, numbers, spaces and hyphens from your Animal ID or registration number."})
                council = attrs.get("council_name", "")
                if not council or any(not char.isprintable() for char in council):
                    raise serializers.ValidationError({"council_name": "Enter the Council named on your registration."})
                year = today.year + ((today.month, today.day) >= (4, 10))
                if attrs.get("registration_year") != year:
                    raise serializers.ValidationError({"registration_year": f"Use the current registration year, {year - 1}–{year} (ending year {year})."})
        return attrs


class DocumentSubmissionSerializer(serializers.ModelSerializer):
    dog_id = serializers.IntegerField(source="dog_id_snapshot")
    dog_name = serializers.CharField(source="dog_name_snapshot")
    file_url = serializers.SerializerMethodField()
    entitlement_id = serializers.IntegerField(read_only=True)
    reward_status = serializers.SerializerMethodField()
    reward_points = serializers.SerializerMethodField()
    collected_at = serializers.DateTimeField(source="entitlement.collected_at", read_only=True)

    class Meta:
        model = DocumentSubmission
        fields = ("id", "request_id", "dog_id", "dog_name", "kind", "status", "registration_number", "council_name", "registration_year", "event_date", "valid_from", "valid_to", "filename", "file_url", "awarded_points", "submitted_at", "entitlement_id", "reward_status", "reward_points", "collected_at")
        read_only_fields = fields

    def get_file_url(self, submission):
        return f"/api/quests/documents/{submission.pk}/file" if submission.file else None

    def get_reward_status(self, submission):
        return "COLLECTED" if submission.entitlement.point_entry_id else "READY"

    def get_reward_points(self, submission):
        return submission.entitlement.promised_points
