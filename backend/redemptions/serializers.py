from rest_framework import serializers

from .models import RedemptionOrder, RedemptionOrderItem


class CafeOrderItemSerializer(serializers.ModelSerializer):
    name = serializers.CharField(source="item_name_snapshot")

    class Meta:
        model = RedemptionOrderItem
        fields = ("name", "quantity")


class CafeOrderSerializer(serializers.ModelSerializer):
    owner_name = serializers.CharField(source="owner_name_snapshot")
    items = CafeOrderItemSerializer(many=True)
    ordered_at = serializers.DateTimeField(source="created_at")

    class Meta:
        model = RedemptionOrder
        fields = (
            "id",
            "reference_number",
            "owner_name",
            "items",
            "ordered_at",
        )
