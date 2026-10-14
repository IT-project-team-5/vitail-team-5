from django.db.models import Prefetch
from rest_framework import status
from rest_framework.response import Response
from rest_framework.views import APIView

from checkins.models import CheckIn
from rewards.permissions import IsOwnerRole
from rewards.services import get_balance

from .models import Walk
from .serializers import CreateWalkSerializer, WalkSerializer
from .services import WalkConflictError, create_walk


class WalkListCreateView(APIView):
    permission_classes = [IsOwnerRole]

    def get(self, request):
        awarded_checkins = CheckIn.objects.filter(
            point_entry__isnull=False,
        ).select_related("point_entry").order_by("collected_at", "id")
        walks = Walk.objects.filter(owner=request.user).select_related(
            "owner", "net_point_entry", "checkin_context",
        ).prefetch_related(
            "dogs",
            Prefetch(
                "checkin_context__checkins",
                queryset=awarded_checkins,
                to_attr="awarded_checkins",
            ),
        )
        context = {
            "wallet_balance": get_balance(request.user),
            "checkins_prefetched": True,
        }
        return Response(WalkSerializer(walks, many=True, context=context).data)

    def post(self, request):
        serializer = CreateWalkSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        try:
            walk = create_walk(owner=request.user, **serializer.validated_data)
        except WalkConflictError as exc:
            return Response({"code": "IDEMPOTENCY_CONFLICT", "message": str(exc)}, status=409)
        context = {"wallet_balance": get_balance(request.user)}
        return Response(WalkSerializer(walk, context=context).data, status=status.HTTP_201_CREATED)
