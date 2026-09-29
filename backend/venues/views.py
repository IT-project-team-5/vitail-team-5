from django.utils import timezone
from rest_framework import status
from rest_framework.response import Response
from rest_framework.views import APIView

from rewards.permissions import IsOwnerRole

from .models import CheckIn, Venue
from .serializers import CheckInSerializer, LocationSampleSerializer, VenueSerializer
from .services import AlreadyCheckedInError, abandon_check_in, report_location, start_check_in


class VenueListView(APIView):
    permission_classes = [IsOwnerRole]

    def get(self, request):
        today = timezone.localdate()
        checked_in = set(CheckIn.objects.filter(
            owner=request.user, completed_local_date=today
        ).values_list("venue_id", flat=True))
        venues = Venue.objects.filter(is_active=True)
        return Response(VenueSerializer(
            venues, many=True, context={"checked_in_venue_ids": checked_in}
        ).data)


class VenueCheckInView(APIView):
    permission_classes = [IsOwnerRole]

    def post(self, request, venue_id):
        sample = LocationSampleSerializer(data=request.data)
        sample.is_valid(raise_exception=True)
        try:
            check_in = start_check_in(
                owner=request.user, venue_id=venue_id, sample=sample.validated_data
            )
        except AlreadyCheckedInError as exc:
            return Response({"code": "ALREADY_CHECKED_IN", "message": str(exc)}, status=409)
        return Response(CheckInSerializer(check_in).data, status=status.HTTP_201_CREATED)


class CheckInLocationView(APIView):
    permission_classes = [IsOwnerRole]

    def post(self, request, check_in_id):
        sample = LocationSampleSerializer(data=request.data)
        sample.is_valid(raise_exception=True)
        check_in = report_location(
            owner=request.user, check_in_id=check_in_id, sample=sample.validated_data
        )
        return Response(CheckInSerializer(check_in).data)


class CheckInAbandonView(APIView):
    permission_classes = [IsOwnerRole]

    def post(self, request, check_in_id):
        check_in = abandon_check_in(owner=request.user, check_in_id=check_in_id)
        return Response(CheckInSerializer(check_in).data)
