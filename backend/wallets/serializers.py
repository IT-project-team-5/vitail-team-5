from rest_framework import serializers

from .models import PointLedger


class WalletBalanceSerializer(serializers.Serializer):
    balance = serializers.IntegerField()


class PointLedgerSerializer(serializers.ModelSerializer):
    class Meta:
        model = PointLedger
        fields = ("id", "amount", "entry_type", "reason", "created_at")
        read_only_fields = fields
