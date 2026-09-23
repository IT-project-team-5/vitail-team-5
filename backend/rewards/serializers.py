from rest_framework import serializers

from .models import PointEntry, Redemption, Reward


class PointEntrySerializer(serializers.ModelSerializer):
    class Meta:
        model = PointEntry
        fields = ("id", "amount", "type", "expires_at", "created_at")
        read_only_fields = fields


class RewardSerializer(serializers.ModelSerializer):
    cafe_name = serializers.CharField(source="cafe_user.display_name", read_only=True)

    class Meta:
        model = Reward
        fields = ("id", "name", "description", "point_cost", "cafe_name")
        read_only_fields = fields


class CafeProductSerializer(serializers.ModelSerializer):
    name = serializers.CharField(max_length=100, trim_whitespace=True)
    description = serializers.CharField(max_length=2000, allow_blank=True, required=False)
    # Keep prices within the range supported by every Django database and the
    # signed integer used for the matching wallet debit.
    point_cost = serializers.IntegerField(min_value=1, max_value=2147483647)

    class Meta:
        model = Reward
        fields = ("id", "name", "description", "point_cost", "is_available")
        read_only_fields = ("id",)

    def to_internal_value(self, data):
        if isinstance(data, dict):
            allowed_fields = set(self.fields) - set(self.Meta.read_only_fields)
            unsupported = set(data) - allowed_fields
            if unsupported:
                raise serializers.ValidationError({
                    field: ["This field cannot be set."] for field in sorted(unsupported)
                })
        return super().to_internal_value(data)


class RedemptionSerializer(serializers.ModelSerializer):
    class Meta:
        model = Redemption
        fields = (
            "id", "reference_number", "reward", "reward_name_snapshot",
            "point_cost_snapshot", "status", "created_at", "collected_at", "expires_at",
            "cafe_name_snapshot",
        )
        read_only_fields = fields


class CreateRedemptionSerializer(serializers.Serializer):
    reward_id = serializers.IntegerField(min_value=1)
    request_id = serializers.UUIDField(required=False)


class CafeOrderSerializer(serializers.ModelSerializer):
    owner_name = serializers.CharField(source="owner_name_snapshot", read_only=True)
    items = serializers.SerializerMethodField()
    ordered_at = serializers.DateTimeField(source="created_at", read_only=True)

    class Meta:
        model = Redemption
        fields = ("id", "reference_number", "owner_name", "items", "ordered_at")

    def get_items(self, order):
        return [{"name": order.reward_name_snapshot, "quantity": 1}]
