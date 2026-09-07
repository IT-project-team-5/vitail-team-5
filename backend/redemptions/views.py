import re

from django.db.models import Prefetch
from rest_framework import status
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response
from rest_framework.views import APIView

from venues.models import Venue

from .models import CafeOrderEvent, RedemptionOrder, RedemptionOrderItem
from .permissions import IsCafeUser
from .serializers import CafeOrderSerializer


CURSOR_HEADER = "X-Cafe-Orders-Cursor"


class CafeOrderFeedView(APIView):
    permission_classes = (IsAuthenticated, IsCafeUser)

    def get(self, request):
        cursor_or_error = self._parse_cursor(request)
        if isinstance(cursor_or_error, Response):
            return cursor_or_error
        since = cursor_or_error

        try:
            venue = Venue.objects.get(account_id=request.user.pk)
        except Venue.DoesNotExist:
            return Response(
                {
                    "code": "CAFE_VENUE_NOT_FOUND",
                    "message": "No venue is attached to this café account.",
                },
                status=status.HTTP_404_NOT_FOUND,
            )

        high_water = venue.order_feed_cursor

        if since is not None and since > high_water:
            return Response(
                {
                    "code": "INVALID_CURSOR",
                    "message": "The since cursor is ahead of the server.",
                },
                status=status.HTTP_400_BAD_REQUEST,
            )

        if since is None:
            orders = self._pending_orders(venue_id=venue.id)
            return self._feed_response(
                high_water=high_water,
                orders=orders,
                removed_ids=[],
                reset=True,
            )

        if since == high_water:
            response = Response(status=status.HTTP_304_NOT_MODIFIED)
            return self._set_feed_headers(response, high_water)

        events = list(
            CafeOrderEvent.objects.filter(
                venue_id=venue.id,
                cursor__gt=since,
                cursor__lte=high_water,
            )
            .values("cursor", "order_id", "kind")
            .order_by("cursor")
        )
        if len(events) != high_water - since:
            # A missing range means retention (or external pruning) removed
            # history the client needs. A snapshot repairs it without allowing
            # a concurrent prune to silently skip changes.
            orders = self._pending_orders(venue_id=venue.id)
            return self._feed_response(
                high_water=high_water,
                orders=orders,
                removed_ids=[],
                reset=True,
            )

        latest_by_order = {}
        for event in events:
            latest_by_order[event["order_id"]] = event

        upsert_ids = [
            order_id
            for order_id, event in latest_by_order.items()
            if event["kind"] == CafeOrderEvent.Kind.UPSERT
        ]
        orders = list(
            self._pending_orders(venue_id=venue.id).filter(id__in=upsert_ids)
        )
        present_ids = {order.id for order in orders}
        removed_ids = sorted(
            order_id
            for order_id, event in latest_by_order.items()
            if event["kind"] == CafeOrderEvent.Kind.REMOVE
            or order_id not in present_ids
        )

        return self._feed_response(
            high_water=high_water,
            orders=orders,
            removed_ids=removed_ids,
            reset=False,
        )

    @staticmethod
    def _parse_cursor(request):
        values = request.query_params.getlist("since")
        if not values:
            return None
        if (
            len(values) != 1
            or len(values[0]) > 19
            or re.fullmatch(r"[0-9]+", values[0]) is None
        ):
            return Response(
                {
                    "code": "INVALID_CURSOR",
                    "message": "The since cursor must be a non-negative integer.",
                },
                status=status.HTTP_400_BAD_REQUEST,
            )
        return int(values[0])

    @staticmethod
    def _pending_orders(*, venue_id):
        return (
            RedemptionOrder.objects.filter(
                venue_id=venue_id,
                status=RedemptionOrder.Status.PENDING,
            )
            .prefetch_related(
                Prefetch(
                    "items",
                    queryset=RedemptionOrderItem.objects.order_by("id"),
                )
            )
            .order_by("-created_at", "-id")
        )

    @classmethod
    def _feed_response(cls, *, high_water, orders, removed_ids, reset):
        response = Response(
            {
                "cursor": high_water,
                "reset": reset,
                "upserts": CafeOrderSerializer(orders, many=True).data,
                "removed_ids": removed_ids,
            }
        )
        return cls._set_feed_headers(response, high_water)

    @staticmethod
    def _set_feed_headers(response, high_water):
        response[CURSOR_HEADER] = str(high_water)
        response["Cache-Control"] = "no-store"
        return response
