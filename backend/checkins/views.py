from django.shortcuts import get_object_or_404
from rest_framework import status
from rest_framework.response import Response
from rest_framework.throttling import UserRateThrottle
from rest_framework.views import APIView

from quests.models import QuestDefinition
from rewards.permissions import IsOwnerRole
from rewards.policy import CHECKIN_POINTS, DAILY_ACTIVITY_CAP, local_date

from .models import CheckIn
from .serializers import (LocationSampleSerializer, RequestIDSerializer, StartCheckInSerializer,
                          VenueCheckInSerializer, VenueMapSerializer, WalkContextSerializer)
from .services import (
    cancel_checkin,
    collect_checkin,
    current_progress,
    daily_activity_points,
    eligible_venues,
    report_checkin_location,
    start_checkin,
    update_walk_context,
)
from walks.services import WalkConflictError
from rest_framework import serializers


def _walk_query(request):
    value = request.query_params.get("walk_request_id")
    return serializers.UUIDField().run_validation(value) if value is not None else None


class WalkContextView(APIView):
    permission_classes = [IsOwnerRole]

    def post(self, request):
        serializer = WalkContextSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        try:
            context = update_walk_context(owner=request.user, **serializer.validated_data)
        except WalkConflictError as exc:
            return Response({"code": "IDEMPOTENCY_CONFLICT", "message": str(exc)}, status=409)
        return Response({"walk_request_id": context.request_id, "started_at": context.started_at,
                         "state": context.state, "ended_at": context.ended_at,
                         "settled": bool(context.settled_at)})


class CheckInStartThrottle(UserRateThrottle):
    scope = "checkin_start"
    rate = "12/min"


class CheckInLocationThrottle(UserRateThrottle):
    scope = "checkin_location"
    rate = "12/min"


class CheckInCollectThrottle(UserRateThrottle):
    scope = "checkin_collect"
    rate = "30/min"


class CheckInCancelThrottle(UserRateThrottle):
    scope = "checkin_cancel"
    rate = "30/min"


class VenueMapView(APIView):
    permission_classes = [IsOwnerRole]

    def get(self, request):
        day = local_date()
        progress = current_progress(owner=request.user, walk_request_id=_walk_query(request))
        checkin_available = (
            QuestDefinition.objects.filter(code=QuestDefinition.Code.CHECK_IN, is_enabled=True).exists()
            and daily_activity_points(request.user, day) + CHECKIN_POINTS <= DAILY_ACTIVITY_CAP
        )
        by_venue = {row.venue_id: row for row in progress["items"]
                    if row.walk_context_id and progress["context"] and row.walk_context_id == progress["context"].pk}
        venues = list(eligible_venues().order_by("kind", "name", "id"))
        return Response(VenueMapSerializer(venues, many=True,
                                           context={
                                               "request": request,
                                               "by_venue": by_venue,
                                               "rewarded_categories": progress["rewarded_categories"],
                                               "checkin_available": checkin_available,
                                           }).data)


class CheckInProgressView(APIView):
    permission_classes = [IsOwnerRole]

    def get(self, request):
        progress = current_progress(owner=request.user, walk_request_id=_walk_query(request))
        return Response({
            "local_date": progress["local_date"], "server_time": progress["server_time"],
            "earned_points_today": progress["earned_points_today"],
            "items": VenueCheckInSerializer(progress["items"], many=True, context={"request": request}).data,
        })


class VenueCheckInStartView(APIView):
    permission_classes = [IsOwnerRole]
    throttle_classes = [CheckInStartThrottle]

    def post(self, request, venue_id):
        serializer = StartCheckInSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        sample = dict(serializer.validated_data)
        walk_request_id = sample.pop("walk_request_id")
        row = start_checkin(owner=request.user, venue_id=venue_id, walk_request_id=walk_request_id, sample=sample)
        return Response(VenueCheckInSerializer(row, context={"request": request}).data, status=status.HTTP_201_CREATED)


class CheckInLocationView(APIView):
    permission_classes = [IsOwnerRole]
    throttle_classes = [CheckInLocationThrottle]

    def post(self, request, attempt_id):
        serializer = LocationSampleSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        row = get_object_or_404(CheckIn, owner=request.user, attempt_id=attempt_id)
        row = report_checkin_location(owner=request.user, checkin_id=row.pk, sample=serializer.validated_data)
        return Response(VenueCheckInSerializer(row, context={"request": request}).data)


class CheckInCancelView(APIView):
    permission_classes = [IsOwnerRole]
    throttle_classes = [CheckInCancelThrottle]

    def post(self, request, attempt_id):
        row = get_object_or_404(CheckIn, owner=request.user, attempt_id=attempt_id)
        row = cancel_checkin(owner=request.user, checkin_id=row.pk)
        return Response({"cancelled": True}) if row is None else Response(VenueCheckInSerializer(row, context={"request": request}).data)


class CheckInCollectionView(APIView):
    permission_classes = [IsOwnerRole]
    throttle_classes = [CheckInCollectThrottle]

    def post(self, request, attempt_id):
        RequestIDSerializer(data=request.data).is_valid(raise_exception=True)
        row = CheckIn.objects.filter(owner=request.user, attempt_id=attempt_id).first()
        if row is None:
            return Response({"detail": "Not found."}, status=status.HTTP_404_NOT_FOUND)
        result = collect_checkin(owner=request.user, checkin_id=row.pk)
        return Response({
            "check_in": VenueCheckInSerializer(result["check_in"], context={"request": request}).data,
            "awarded_points": result["awarded_points"], "wallet_balance": result["wallet_balance"],
            "daily_earned_points": result["daily_earned_points"], "local_date": result["local_date"],
        })
