from django.utils import timezone
from rest_framework import serializers

from .models import CheckIn, Venue


class LocationSampleSerializer(serializers.Serializer):
    latitude = serializers.FloatField(min_value=-90, max_value=90)
    longitude = serializers.FloatField(min_value=-180, max_value=180)
    accuracy_m = serializers.FloatField(min_value=0)
    is_simulated = serializers.BooleanField(default=False)


class VenueSerializer(serializers.ModelSerializer):
    required_dwell_s = serializers.IntegerField(source="dwell_seconds", read_only=True)
    checked_in_today = serializers.SerializerMethodField()

    class Meta:
        model = Venue
        fields = (
            "id", "name", "venue_type", "description", "address", "opening_hours",
            "latitude", "longitude", "checkin_radius_m", "required_dwell_s", "checked_in_today",
        )
        read_only_fields = fields

    def get_checked_in_today(self, venue):
        return venue.id in self.context.get("checked_in_venue_ids", ())


class CheckInSerializer(serializers.ModelSerializer):
    venue_id = serializers.IntegerField(read_only=True)
    venue_name = serializers.CharField(source="venue.name", read_only=True)
    required_dwell_s = serializers.IntegerField(source="venue.dwell_seconds", read_only=True)
    verified_seconds = serializers.SerializerMethodField()

    class Meta:
        model = CheckIn
        fields = (
            "id", "venue_id", "venue_name", "status", "abandon_reason", "entered_at",
            "required_dwell_s", "verified_seconds", "awarded_points",
        )
        read_only_fields = fields

    def get_verified_seconds(self, check_in):
        end = check_in.dwell_completed_at or (
            check_in.last_report_at if check_in.status != CheckIn.Status.IN_PROGRESS
            else timezone.now()
        )
        elapsed = max(0, int((end - check_in.entered_at).total_seconds()))
        return min(elapsed, check_in.venue.dwell_seconds)
