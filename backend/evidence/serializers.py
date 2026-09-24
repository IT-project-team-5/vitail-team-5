import calendar
from datetime import timedelta

from django.utils import timezone
from rest_framework import serializers

from .models import DocumentKind, DocumentSubmission
from .uploads import MAX_BYTES, validate_upload


def first_anniversary(value):
    year = value.year + 1
    return value.replace(year=year, day=min(value.day, calendar.monthrange(year, value.month)[1]))


class DocumentRequestSerializer(serializers.Serializer):
    request_id = serializers.UUIDField()
    dog_id = serializers.IntegerField(min_value=1)
    kind = serializers.ChoiceField(choices=DocumentKind.choices)
    registration_number = serializers.CharField(max_length=100, allow_blank=True, required=False)
    event_date = serializers.DateField(required=False, allow_null=True)
    valid_from = serializers.DateField(required=False, allow_null=True)
    valid_to = serializers.DateField(required=False, allow_null=True)
    filename = serializers.CharField(max_length=150, required=False, allow_blank=True)
    file_base64 = serializers.CharField(required=False, trim_whitespace=False, max_length=4 * ((MAX_BYTES + 2) // 3))

    def validate(self, attrs):
        today = timezone.localdate()
        kind = attrs["kind"]
        number = attrs.get("registration_number", "").strip()
        if any(not char.isprintable() for char in number):
            raise serializers.ValidationError({"registration_number": "Enter a registration number without line breaks."})
        attrs["registration_number"] = number
        if kind == DocumentKind.VET:
            if not attrs.get("event_date") or attrs["event_date"] > today:
                raise serializers.ValidationError({"event_date": "Enter the actual check-up date, today or earlier."})
            if not attrs.get("file_base64"):
                raise serializers.ValidationError({"file_base64": "Add a photo of the vet check-up evidence."})
            if number or attrs.get("valid_from") or attrs.get("valid_to"):
                raise serializers.ValidationError("Vet check-ups use a visit date and photo.")
        else:
            if not number and not attrs.get("file_base64"):
                raise serializers.ValidationError("Enter the registration number or attach a PDF.")
            if attrs.get("event_date"):
                raise serializers.ValidationError({"event_date": "Use registration validity dates for registrations."})
            if kind == DocumentKind.MICROCHIP:
                start, end = attrs.get("valid_from"), attrs.get("valid_to")
                if not start or not end:
                    raise serializers.ValidationError("Enter the registration's annual start and end dates.")
                if start > today:
                    raise serializers.ValidationError({"valid_from": "The registration start date cannot be in the future."})
                anniversary = first_anniversary(start)
                if end not in {anniversary, anniversary - timedelta(days=1)}:
                    raise serializers.ValidationError({"valid_to": "Use the annual registration end date: the first anniversary or the day before."})
            elif attrs.get("valid_from") or attrs.get("valid_to"):
                raise serializers.ValidationError("Council registration is a lifetime reward and does not need validity dates.")
        if attrs.get("file_base64"):
            attrs["upload"] = validate_upload(attrs.pop("file_base64"), attrs.pop("filename", ""), kind)
        else:
            attrs.pop("filename", None)
        return attrs


class DocumentSubmissionSerializer(serializers.ModelSerializer):
    dog_id = serializers.IntegerField(source="dog_id_snapshot")
    dog_name = serializers.CharField(source="dog_name_snapshot")
    file_url = serializers.SerializerMethodField()

    class Meta:
        model = DocumentSubmission
        fields = ("id", "request_id", "dog_id", "dog_name", "kind", "status", "registration_number", "event_date", "valid_from", "valid_to", "filename", "file_url", "awarded_points", "submitted_at")
        read_only_fields = fields

    def get_file_url(self, submission):
        return f"/api/quests/documents/{submission.pk}/file" if submission.file else None
