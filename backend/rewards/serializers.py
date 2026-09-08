from rest_framework import serializers

from .models import PointEntry, Redemption, Reward


class WalletBalanceSerializer(serializers.Serializer):
    balance = serializers.IntegerField()


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


class RedemptionSerializer(serializers.ModelSerializer):
    class Meta:
        model = Redemption
        fields = (
            "id",
            "reference_number",
            "reward",
            "reward_name_snapshot",
            "point_cost_snapshot",
            "status",
            "created_at",
            "collected_at",
            "expires_at",
        )
        read_only_fields = fields


class CreateRedemptionSerializer(serializers.Serializer):
    """Validates the request shape; `services.create_redemption` re-checks
    availability itself under a row lock, so this is just a fast 400 for an
    obviously bad id."""

    reward_id = serializers.IntegerField()

    def validate_reward_id(self, value):
        if not Reward.objects.filter(id=value, is_available=True).exists():
            raise serializers.ValidationError("Reward not found or unavailable.")
        return value
