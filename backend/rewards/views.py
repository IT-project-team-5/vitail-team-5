from rest_framework import status
from rest_framework.response import Response
from rest_framework.views import APIView

from accounts.permissions import IsOwnerRole

from .models import PointEntry, Reward
from .serializers import (
    CreateRedemptionSerializer,
    PointEntrySerializer,
    RedemptionSerializer,
    RewardSerializer,
    WalletBalanceSerializer,
)
from .services import (
    InsufficientPointsError,
    RedemptionNotCollectibleError,
    RewardUnavailableError,
    collect_redemption,
    create_redemption,
    get_balance,
)


class WalletView(APIView):
    """GET /api/wallet — the signed-in owner's current point balance."""

    permission_classes = [IsOwnerRole]

    def get(self, request):
        return Response(WalletBalanceSerializer({"balance": get_balance(request.user)}).data)


class WalletLedgerView(APIView):
    """GET /api/wallet/ledger — every point change for the signed-in owner."""

    permission_classes = [IsOwnerRole]

    def get(self, request):
        entries = PointEntry.objects.filter(user=request.user)
        return Response(PointEntrySerializer(entries, many=True).data)


class RewardListView(APIView):
    """GET /api/redemptions/rewards — the rewards an owner can redeem."""

    permission_classes = [IsOwnerRole]

    def get(self, request):
        rewards = Reward.objects.filter(is_available=True)
        return Response(RewardSerializer(rewards, many=True).data)


class RedemptionListCreateView(APIView):
    permission_classes = [IsOwnerRole]

    def get(self, request):
        """GET /api/redemptions — the signed-in owner's own history."""
        redemptions = request.user.redemptions.all()
        return Response(RedemptionSerializer(redemptions, many=True).data)

    def post(self, request):
        """POST /api/redemptions — redeem a reward and deduct points
        immediately. Ownership is always the authenticated user; the app
        never sends an owner id.
        """
        serializer = CreateRedemptionSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)

        try:
            redemption = create_redemption(
                owner=request.user, reward_id=serializer.validated_data["reward_id"]
            )
        except InsufficientPointsError:
            return Response(
                {
                    "code": "INSUFFICIENT_POINTS",
                    "message": "Not enough points to complete this redemption.",
                },
                status=status.HTTP_400_BAD_REQUEST,
            )
        except RewardUnavailableError as exc:
            return Response(
                {"code": "REWARD_UNAVAILABLE", "message": str(exc)},
                status=status.HTTP_400_BAD_REQUEST,
            )

        return Response(RedemptionSerializer(redemption).data, status=status.HTTP_201_CREATED)


class RedemptionCollectView(APIView):
    """POST /api/redemptions/{id}/collect — the owner's Collect button. Not
    location-gated at MVP.
    """

    permission_classes = [IsOwnerRole]

    def post(self, request, redemption_id):
        try:
            redemption = collect_redemption(owner=request.user, redemption_id=redemption_id)
        except RedemptionNotCollectibleError as exc:
            return Response(
                {"code": "REDEMPTION_NOT_COLLECTIBLE", "message": str(exc)},
                status=status.HTTP_409_CONFLICT,
            )

        if redemption is None:
            return Response(status=status.HTTP_404_NOT_FOUND)

        return Response(RedemptionSerializer(redemption).data)
