import math

from rest_framework import serializers

from .models import Walk


class WalkSampleSerializer(serializers.Serializer):
    latitude = serializers.FloatField(min_value=-90, max_value=90)
    longitude = serializers.FloatField(min_value=-180, max_value=180)
    recorded_at = serializers.DateTimeField()
    accuracy_m = serializers.FloatField(min_value=0)
    is_simulated = serializers.BooleanField(default=False)
    segment_id = serializers.IntegerField(min_value=0, max_value=4999, default=0)

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
    check_in_awards = serializers.SerializerMethodField()
    check_in_points_awarded = serializers.SerializerMethodField()
    net_points_awarded = serializers.SerializerMethodField()
    total_points_awarded = serializers.SerializerMethodField()
    wallet_balance = serializers.SerializerMethodField()

    def get_check_in_awards(self, walk):
        from checkins.models import CheckIn
        rows = CheckIn.objects.filter(walk_context__walk=walk, point_entry__isnull=False).select_related("point_entry").order_by("collected_at", "id")
        return [{"id": str(row.attempt_id), "venue_id": row.venue_id, "venue_name": row.venue_name_snapshot,
                 "kind": row.category_slot, "reward_category": row.reward_category,
                 "awarded_points": row.point_entry.amount} for row in rows]

    def get_check_in_points_awarded(self, walk):
        return sum(row["awarded_points"] for row in self.get_check_in_awards(walk))

    def get_net_points_awarded(self, walk):
        return walk.net_point_entry.amount if walk.net_point_entry_id else 0

    def get_total_points_awarded(self, walk):
        return walk.points_awarded + self.get_net_points_awarded(walk) + self.get_check_in_points_awarded(walk)

    def get_wallet_balance(self, walk):
        from rewards.services import get_balance
        return get_balance(walk.owner)

    class Meta:
        model = Walk
        fields = (
            "id", "request_id", "started_at", "ended_at", "distance_m",
            "points_awarded", "point_date", "dog_ids", "active_seconds",
            "check_in_awards", "check_in_points_awarded", "net_points_awarded",
            "total_points_awarded", "wallet_balance",
        )
        read_only_fields = fields
