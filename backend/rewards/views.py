import re

from django.db import transaction
from django.utils import timezone
from rest_framework import status
from rest_framework.response import Response
from rest_framework.views import APIView

from .models import PointEntry, Redemption, Reward
from .permissions import IsCafeRole, IsOwnerRole
from .serializers import (
    CafeOrderSerializer, CreateRedemptionSerializer, PointEntrySerializer,
    RedemptionSerializer, RewardSerializer,
)
from .services import (
    IdempotencyConflictError, InsufficientPointsError, RedemptionNotCollectibleError,
    RewardUnavailableError, collect_redemption, create_redemption,
    expire_points, expire_redemptions, get_balance, lock_feed_state,
)


class WalletView(APIView):
    permission_classes = [IsOwnerRole]

    def get(self, request):
        expire_redemptions(owner=request.user)
        expire_points(owner=request.user)
        return Response({"balance": get_balance(request.user)})


class WalletLedgerView(APIView):
    permission_classes = [IsOwnerRole]

    def get(self, request):
        expire_redemptions(owner=request.user)
        expire_points(owner=request.user)
        return Response(PointEntrySerializer(
            PointEntry.objects.filter(user=request.user), many=True
        ).data)


class RewardListView(APIView):
    permission_classes = [IsOwnerRole]

    def get(self, request):
        rewards = Reward.objects.filter(
            is_available=True, cafe_user__is_active=True, cafe_user__role="CAFE"
        ).select_related("cafe_user")
        return Response(RewardSerializer(rewards, many=True).data)


class RedemptionListCreateView(APIView):
    permission_classes = [IsOwnerRole]

    def get(self, request):
        expire_redemptions(owner=request.user)
        return Response(RedemptionSerializer(request.user.redemptions.all(), many=True).data)

    def post(self, request):
        serializer = CreateRedemptionSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        expire_redemptions(owner=request.user)
        try:
            redemption = create_redemption(owner=request.user, **serializer.validated_data)
        except InsufficientPointsError as exc:
            return Response({"code": "INSUFFICIENT_POINTS", "message": str(exc)}, status=400)
        except RewardUnavailableError as exc:
            return Response({"code": "REWARD_UNAVAILABLE", "message": str(exc)}, status=400)
        except IdempotencyConflictError as exc:
            return Response({"code": "IDEMPOTENCY_CONFLICT", "message": str(exc)}, status=409)
        return Response(RedemptionSerializer(redemption).data, status=status.HTTP_201_CREATED)


class RedemptionCollectView(APIView):
    permission_classes = [IsOwnerRole]

    def post(self, request, redemption_id):
        try:
            redemption = collect_redemption(owner=request.user, redemption_id=redemption_id)
        except RedemptionNotCollectibleError as exc:
            return Response({"code": "REDEMPTION_NOT_COLLECTIBLE", "message": str(exc)}, status=409)
        if redemption is None:
            return Response(status=404)
        return Response(RedemptionSerializer(redemption).data)


CURSOR_HEADER = "X-Cafe-Orders-Cursor"


class CafeOrderFeedView(APIView):
    """Read-only delta feed over the same orders owners created.

    Orders are retained, so their last-change cursor is enough to send the
    latest state (or removal); a separate event log/retention system isn't
    necessary for this MVP.
    """

    permission_classes = [IsCafeRole]

    def get(self, request):
        values = request.query_params.getlist("since")
        if values and (
            len(values) != 1 or len(values[0]) > 19
            or re.fullmatch(r"[0-9]+", values[0]) is None
        ):
            return Response({"code": "INVALID_CURSOR", "message": "The since cursor must be a non-negative integer."}, status=400)
        since = int(values[0]) if values else None
        now = timezone.now()
        expire_redemptions(cafe=request.user, now=now)
        with transaction.atomic():
            state = lock_feed_state(request.user.pk)
            if since is not None and since > state.cursor:
                return Response({"code": "INVALID_CURSOR", "message": "The since cursor is ahead of the server."}, status=400)
            if since == state.cursor:
                response = Response(status=status.HTTP_304_NOT_MODIFIED)
            else:
                orders = Redemption.objects.filter(cafe_user=request.user, feed_cursor__lte=state.cursor)
                if since is not None:
                    orders = orders.filter(feed_cursor__gt=since)
                rows = list(orders)
                pending = [row for row in rows if row.status == Redemption.Status.PENDING and row.expires_at > now]
                removed_ids = [] if since is None else sorted(
                    row.id for row in rows if row.status != Redemption.Status.PENDING or row.expires_at <= now
                )
                response = Response({
                    "cursor": state.cursor, "upserts": CafeOrderSerializer(pending, many=True).data,
                    "removed_ids": removed_ids, "reset": since is None,
                })
            response[CURSOR_HEADER] = str(state.cursor)
            response["Cache-Control"] = "no-store"
            return response
