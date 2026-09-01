from rest_framework.response import Response
from rest_framework.views import APIView

from .models import PointLedger
from .serializers import PointLedgerSerializer, WalletBalanceSerializer
from .services import get_balance


class WalletView(APIView):
    """GET /api/wallet — the signed-in owner's current point balance."""

    def get(self, request):
        data = {"balance": get_balance(request.user)}
        return Response(WalletBalanceSerializer(data).data)


class WalletLedgerView(APIView):
    """GET /api/wallet/ledger — every point change for the signed-in owner."""

    def get(self, request):
        entries = PointLedger.objects.filter(owner=request.user)
        return Response(PointLedgerSerializer(entries, many=True).data)
