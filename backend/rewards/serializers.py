from rest_framework import serializers

from accounts.photos import photo_url
from accounts.venues import cafe_profile_for, google_maps_url

from .models import PointEntry, Redemption, Reward


class PointEntrySerializer(serializers.ModelSerializer):
    class Meta:
        model = PointEntry
        fields = ("id", "amount", "type", "expires_at", "created_at")
        read_only_fields = fields


CAFE_DETAIL_FIELDS = (
    "cafe_id", "cafe_photo", "cafe_address", "cafe_description",
    "cafe_opening_hours", "cafe_google_maps_url",
)


class CafeDetailsSerializer(serializers.ModelSerializer):
    cafe_id = serializers.IntegerField(source="cafe_user_id", read_only=True)
    cafe_photo = serializers.SerializerMethodField()
    cafe_address = serializers.SerializerMethodField()
    cafe_description = serializers.SerializerMethodField()
    cafe_opening_hours = serializers.SerializerMethodField()
    cafe_google_maps_url = serializers.SerializerMethodField()

    def get_cafe_photo(self, instance):
        return photo_url(instance.cafe_user.photo, self.context.get("request"))

    def get_cafe_address(self, instance):
        profile = cafe_profile_for(instance.cafe_user)
        return profile.address if profile else ""

    def get_cafe_description(self, instance):
        profile = cafe_profile_for(instance.cafe_user)
        return profile.description if profile else ""

    def get_cafe_opening_hours(self, instance):
        profile = cafe_profile_for(instance.cafe_user)
        return profile.opening_hours if profile else ""

    def get_cafe_google_maps_url(self, instance):
        return google_maps_url(instance.cafe_user, cafe_profile_for(instance.cafe_user))


class RewardSerializer(CafeDetailsSerializer):
    cafe_name = serializers.CharField(source="cafe_user.display_name", read_only=True)

    class Meta:
        model = Reward
        fields = ("id", "name", "description", "point_cost", "cafe_name") + CAFE_DETAIL_FIELDS
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


class RedemptionSerializer(CafeDetailsSerializer):
    class Meta:
        model = Redemption
        fields = (
            "id", "reference_number", "reward", "reward_name_snapshot",
            "point_cost_snapshot", "status", "created_at", "collected_at", "expires_at",
            "cafe_name_snapshot",
        ) + CAFE_DETAIL_FIELDS
        read_only_fields = fields


class CreateRedemptionSerializer(serializers.Serializer):
    reward_id = serializers.IntegerField(min_value=1)
    request_id = serializers.UUIDField(required=False)


class CafeOrderSerializer(serializers.ModelSerializer):
    owner_dog_names = serializers.SerializerMethodField()
    owner_dogs = serializers.SerializerMethodField()
    owner_name = serializers.CharField(source="owner_name_snapshot", read_only=True)
    items = serializers.SerializerMethodField()
    ordered_at = serializers.DateTimeField(source="created_at", read_only=True)

    class Meta:
        model = Redemption
        fields = ("id", "reference_number", "owner_name", "owner_dog_names", "owner_dogs", "items", "ordered_at", "status", "expires_at")

    def get_owner_dog_names(self, order):
        # Current profile dogs, not an assertion of dogs present at collection.
        return [dog.name for dog in order.owner_user.dogs.all()]

    def get_owner_dogs(self, order):
        request = self.context.get("request")
        return [
            {
                "id": dog.pk,
                "name": dog.name,
                "photo": photo_url(dog.uploaded_photo, request) if dog.uploaded_photo else dog.photo,
            }
            for dog in order.owner_user.dogs.all()
        ]

    def get_items(self, order):
        return [{"name": order.reward_name_snapshot, "quantity": 1}]
