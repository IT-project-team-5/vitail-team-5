from rest_framework import serializers

from venues.models import Venue, VenueOffer

from .models import RedemptionOrder, RedemptionOrderItem


class RedemptionOrderItemSerializer(serializers.ModelSerializer):
    class Meta:
        model = RedemptionOrderItem
        fields = ("id", "item_name_snapshot", "point_price_snapshot", "quantity")
        read_only_fields = fields


class RedemptionOrderSerializer(serializers.ModelSerializer):
    items = RedemptionOrderItemSerializer(many=True, read_only=True)
    venue_name = serializers.CharField(source="venue.name", read_only=True)

    class Meta:
        model = RedemptionOrder
        fields = (
            "id",
            "reference_number",
            "status",
            "total_points",
            "venue",
            "venue_name",
            "items",
            "created_at",
            "collected_at",
            "expires_at",
        )
        read_only_fields = fields


class CreateOrderItemSerializer(serializers.Serializer):
    offer_id = serializers.IntegerField()
    quantity = serializers.IntegerField(min_value=1, default=1)


class CreateOrderSerializer(serializers.Serializer):
    """Validates the request shape, then resolves `venue_id`/`offer_id`
    into real model instances so `services.create_order` never has to.
    """

    venue_id = serializers.IntegerField()
    items = CreateOrderItemSerializer(many=True)

    def validate_items(self, value):
        if not value:
            raise serializers.ValidationError("An order needs at least one item.")
        return value

    def validate(self, attrs):
        venue = Venue.objects.filter(id=attrs["venue_id"], is_active=True).first()
        if venue is None:
            raise serializers.ValidationError({"venue_id": "Venue not found."})

        resolved_items = []
        for item in attrs["items"]:
            offer = VenueOffer.objects.filter(id=item["offer_id"], venue=venue).first()
            if offer is None:
                raise serializers.ValidationError(
                    {"items": f"Offer {item['offer_id']} was not found for this venue."}
                )
            resolved_items.append({"offer": offer, "quantity": item["quantity"]})

        attrs["venue"] = venue
        attrs["resolved_items"] = resolved_items
        return attrs
