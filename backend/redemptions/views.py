from rest_framework import status
from rest_framework.response import Response
from rest_framework.views import APIView

from wallets.services import InsufficientPointsError

from .serializers import CreateOrderSerializer, RedemptionOrderSerializer
from .services import (
    EmptyOrderError,
    OfferUnavailableError,
    OrderNotCollectibleError,
    collect_order,
    create_order,
)


class RedemptionOrderListCreateView(APIView):
    def get(self, request):
        """GET /api/redemptions/orders — the signed-in owner's own history."""
        orders = request.user.redemption_orders.all()
        return Response(RedemptionOrderSerializer(orders, many=True).data)

    def post(self, request):
        """POST /api/redemptions/orders — create an order and deduct points
        immediately. Ownership is always the authenticated user; the app
        never sends an owner id (TECH_STACK.md, section 15).
        """
        serializer = CreateOrderSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)

        try:
            order = create_order(
                owner=request.user,
                venue=serializer.validated_data["venue"],
                items=serializer.validated_data["resolved_items"],
            )
        except InsufficientPointsError:
            return Response(
                {
                    "code": "INSUFFICIENT_POINTS",
                    "message": "Not enough points to complete this redemption.",
                },
                status=status.HTTP_400_BAD_REQUEST,
            )
        except (EmptyOrderError, OfferUnavailableError) as exc:
            return Response(
                {"code": "INVALID_ORDER", "message": str(exc)},
                status=status.HTTP_400_BAD_REQUEST,
            )

        return Response(RedemptionOrderSerializer(order).data, status=status.HTTP_201_CREATED)


class RedemptionOrderCollectView(APIView):
    def post(self, request, order_id):
        """POST /api/redemptions/orders/{id}/collect — the owner's Redeem
        button. Not location-gated at MVP (README.md, "Redeeming Points").
        """
        try:
            order = collect_order(owner=request.user, order_id=order_id)
        except OrderNotCollectibleError as exc:
            return Response(
                {"code": "ORDER_NOT_COLLECTIBLE", "message": str(exc)},
                status=status.HTTP_409_CONFLICT,
            )

        if order is None:
            return Response(status=status.HTTP_404_NOT_FOUND)

        return Response(RedemptionOrderSerializer(order).data)
