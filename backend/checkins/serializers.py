from rest_framework import serializers

from rewards.policy import CHECKIN_RADIUS_M, CHECKIN_SECONDS


class LocationSampleSerializer(serializers.Serializer):
    latitude = serializers.FloatField(min_value=-90, max_value=90)
    longitude = serializers.FloatField(min_value=-180, max_value=180)
    accuracy_m = serializers.FloatField(min_value=0)
    is_simulated = serializers.BooleanField(default=False)


class RequestIDSerializer(serializers.Serializer):
    request_id = serializers.UUIDField(required=False)


class VenueCheckInSerializer(serializers.Serializer):
    id = serializers.UUIDField(source="attempt_id")
    venue_id = serializers.IntegerField(read_only=True)
    venue_name = serializers.CharField(source="venue_name_snapshot", read_only=True)
    photo = serializers.SerializerMethodField()
    required_seconds = serializers.IntegerField(read_only=True)
    verified_seconds = serializers.IntegerField(read_only=True)
    status = serializers.CharField(read_only=True)
    updated_at = serializers.DateTimeField(read_only=True)
    reward_points = serializers.IntegerField(source="promised_points", read_only=True)
    collected_at = serializers.DateTimeField(read_only=True)

    def get_photo(self, row):
        if not row.venue_id or not row.venue.photo:
            return None
        request = self.context.get("request")
        return request.build_absolute_uri(row.venue.photo.url) if request else row.venue.photo.url


class VenueMapSerializer(serializers.Serializer):
    id = serializers.IntegerField(read_only=True)
    name = serializers.CharField(read_only=True)
    kind = serializers.CharField(read_only=True)
    description = serializers.CharField(read_only=True)
    address = serializers.CharField(read_only=True)
    opening_hours = serializers.CharField(read_only=True)
    photo = serializers.SerializerMethodField()
    latitude = serializers.FloatField(read_only=True)
    longitude = serializers.FloatField(read_only=True)
    checkin_radius_m = serializers.SerializerMethodField()
    required_seconds = serializers.SerializerMethodField()
    checkin_status = serializers.SerializerMethodField()

    def get_photo(self, venue):
        if not venue.photo:
            return None
        request = self.context.get("request")
        return request.build_absolute_uri(venue.photo.url) if request else venue.photo.url

    def get_checkin_radius_m(self, venue):
        return CHECKIN_RADIUS_M

    def get_required_seconds(self, venue):
        return CHECKIN_SECONDS[venue.kind]

    def get_checkin_status(self, venue):
        row = self.context.get("by_category", {}).get(venue.kind)
        if row is None:
            return "AVAILABLE"
        return row.status
