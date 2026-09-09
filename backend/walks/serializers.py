import math

from rest_framework import serializers

from .models import Walk


class WalkSampleSerializer(serializers.Serializer):
    latitude = serializers.FloatField(min_value=-90, max_value=90)
    longitude = serializers.FloatField(min_value=-180, max_value=180)
    recorded_at = serializers.DateTimeField()
    accuracy_m = serializers.FloatField(min_value=0)
    is_simulated = serializers.BooleanField(default=False)

    def validate(self, attrs):
        for key in ("latitude", "longitude", "accuracy_m"):
            if not math.isfinite(attrs[key]):
                raise serializers.ValidationError({key: "Use a finite number."})
        return attrs


class CreateWalkSerializer(serializers.Serializer):
    request_id = serializers.UUIDField()
    started_at = serializers.DateTimeField()
    ended_at = serializers.DateTimeField()
    dog_ids = serializers.ListField(
        child=serializers.IntegerField(min_value=1), min_length=1, max_length=10
    )
    samples = WalkSampleSerializer(many=True, min_length=2, max_length=5000)

    def validate_dog_ids(self, value):
        if len(value) != len(set(value)):
            raise serializers.ValidationError("Choose each dog only once.")
        return value


class WalkSerializer(serializers.ModelSerializer):
    distance_m = serializers.FloatField(read_only=True)
    dog_ids = serializers.PrimaryKeyRelatedField(source="dogs", many=True, read_only=True)

    class Meta:
        model = Walk
        fields = (
            "id", "request_id", "started_at", "ended_at", "distance_m",
            "points_awarded", "point_date", "dog_ids",
        )
        read_only_fields = fields
