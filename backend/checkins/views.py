from django.shortcuts import get_object_or_404
from rest_framework import status
from rest_framework.response import Response
from rest_framework.views import APIView

from rewards.permissions import IsOwnerRole
from rewards.policy import local_date
from venues.models import Venue

from .models import CheckIn
from .serializers import LocationSampleSerializer, RequestIDSerializer, VenueCheckInSerializer, VenueMapSerializer
from .services import cancel_checkin, collect_checkin, current_progress, report_checkin_location, start_checkin


class VenueMapView(APIView):
    permission_classes = [IsOwnerRole]

    def get(self, request):
        day = local_date()
        by_category = {
            row.category_slot: row for row in CheckIn.objects.filter(owner=request.user, local_date=day).select_related("venue", "point_entry")
        }
        venues = list(Venue.objects.filter(
            is_active=True, checkin_enabled=True, latitude__isnull=False, longitude__isnull=False,
        ).order_by("kind", "name", "id"))
        # One opportunity per category keeps the surface aligned with the four
        # daily Quest slots while retaining the venue's real location on the map.
        unique = {}
        for venue in venues:
            unique.setdefault(venue.kind, venue)
        # If a user already started a category today, keep that exact venue on
        # the map rather than replacing it with another venue of the same kind.
        for kind, row in by_category.items():
            if row.venue_id:
                unique[kind] = row.venue
        return Response(VenueMapSerializer(list(unique.values()), many=True,
                                           context={"request": request, "by_category": by_category}).data)


class CheckInProgressView(APIView):
    permission_classes = [IsOwnerRole]

    def get(self, request):
        progress = current_progress(owner=request.user)
        return Response({
            "local_date": progress["local_date"], "server_time": progress["server_time"],
            "earned_points_today": progress["earned_points_today"],
            "items": VenueCheckInSerializer(progress["items"], many=True, context={"request": request}).data,
        })


class VenueCheckInStartView(APIView):
    permission_classes = [IsOwnerRole]

    def post(self, request, venue_id):
        serializer = LocationSampleSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        row = start_checkin(owner=request.user, venue_id=venue_id, sample=serializer.validated_data)
        return Response(VenueCheckInSerializer(row, context={"request": request}).data, status=status.HTTP_201_CREATED)


class CheckInLocationView(APIView):
    permission_classes = [IsOwnerRole]

    def post(self, request, attempt_id):
        serializer = LocationSampleSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        row = get_object_or_404(CheckIn, owner=request.user, attempt_id=attempt_id)
        row = report_checkin_location(owner=request.user, checkin_id=row.pk, sample=serializer.validated_data)
        return Response(VenueCheckInSerializer(row, context={"request": request}).data)


class CheckInCancelView(APIView):
    permission_classes = [IsOwnerRole]

    def post(self, request, attempt_id):
        row = get_object_or_404(CheckIn, owner=request.user, attempt_id=attempt_id)
        row = cancel_checkin(owner=request.user, checkin_id=row.pk)
        return Response({"cancelled": True}) if row is None else Response(VenueCheckInSerializer(row, context={"request": request}).data)


class CheckInCollectionView(APIView):
    permission_classes = [IsOwnerRole]

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
