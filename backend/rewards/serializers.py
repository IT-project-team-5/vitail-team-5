from rest_framework import serializers

from accounts.photos import photo_url
from accounts.venues import google_maps_url

from .models import PointEntry, Redemption, Reward


class PointEntrySerializer(serializers.ModelSerializer):
    class Meta:
        model = PointEntry
        fields = ("id", "amount", "type", "expires_at", "created_at")
        read_only_fields = fields


CAFE_DETAIL_FIELDS = (
    "cafe_id", "venue_id", "cafe_photo", "cafe_address", "cafe_description",
    "cafe_opening_hours", "cafe_google_maps_url",
)


class CafeDetailsSerializer(serializers.ModelSerializer):
    cafe_id = serializers.SerializerMethodField()
    venue_id = serializers.IntegerField(read_only=True)
    cafe_photo = serializers.SerializerMethodField()
    cafe_address = serializers.CharField(source="venue.address", read_only=True)
    cafe_description = serializers.CharField(source="venue.description", read_only=True)
    cafe_opening_hours = serializers.CharField(source="venue.opening_hours", read_only=True)
    cafe_google_maps_url = serializers.SerializerMethodField()

    def get_cafe_id(self, instance):
        # Legacy clients group cafés by login User ID, not the new place ID.
        return instance.cafe_user_id if isinstance(instance, Redemption) else instance.venue.manager_user_id

    def get_cafe_photo(self, instance):
        return photo_url(instance.venue.photo, self.context.get("request"))

    def get_cafe_google_maps_url(self, instance):
        return google_maps_url(instance.venue)


class RewardSerializer(CafeDetailsSerializer):
    photo = serializers.SerializerMethodField()
    cafe_name = serializers.CharField(source="venue.name", read_only=True)

    def get_photo(self, instance):
        return photo_url(instance.photo, self.context.get("request"))

    class Meta:
        model = Reward
        fields = ("id", "name", "description", "point_cost", "cafe_name", "photo", "starts_at", "ends_at", "daily_quantity_limit", "terms", "requires_store_purchase") + CAFE_DETAIL_FIELDS
        read_only_fields = fields


class CafeProductSerializer(serializers.ModelSerializer):
    photo = serializers.SerializerMethodField()
    terms = serializers.CharField(max_length=2000, allow_blank=True, required=False)
    daily_quantity_limit = serializers.IntegerField(min_value=1, max_value=2147483647, allow_null=True, required=False)
    name = serializers.CharField(max_length=100, trim_whitespace=True)
    description = serializers.CharField(max_length=2000, allow_blank=True, required=False)
    # Keep prices within the range supported by every Django database and the
    # signed integer used for the matching wallet debit.
    point_cost = serializers.IntegerField(min_value=1, max_value=2147483647)

    class Meta:
        model = Reward
        fields = ("id", "venue_id", "name", "description", "point_cost", "is_available", "photo", "starts_at", "ends_at", "daily_quantity_limit", "terms", "requires_store_purchase", "updated_at")
        read_only_fields = ("id", "venue_id", "photo", "updated_at")

    def get_photo(self, instance):
        return photo_url(instance.photo, self.context.get("request"))

    def validate(self, attrs):
        start = attrs.get("starts_at", self.instance.starts_at if self.instance else None)
        end = attrs.get("ends_at", self.instance.ends_at if self.instance else None)
        if start and end and end <= start:
            raise serializers.ValidationError({"ends_at": "End time must be after start time."})
        return attrs

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
            "cafe_name_snapshot", "terms_snapshot", "order_date",
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
