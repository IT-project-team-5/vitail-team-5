from rest_framework.generics import ListAPIView, RetrieveAPIView
from rest_framework.response import Response
from rest_framework.views import APIView

from .models import Venue
from .serializers import VenueDetailSerializer, VenueOfferSerializer, VenueSerializer


class VenueListView(ListAPIView):
    """GET /api/venues — active partner venues an owner can browse."""

    serializer_class = VenueSerializer
    queryset = Venue.objects.filter(is_active=True)


class VenueDetailView(RetrieveAPIView):
    """GET /api/venues/{id} — a single venue, with its available offers."""

    serializer_class = VenueDetailSerializer
    queryset = Venue.objects.filter(is_active=True)


class VenueOffersView(APIView):
    """GET /api/venues/{id}/offers — offers redeemable at this venue."""

    def get(self, request, venue_id):
        venue = Venue.objects.filter(id=venue_id, is_active=True).first()
        if venue is None:
            return Response(status=404)

        offers = venue.offers.filter(is_available=True).order_by("name")
        return Response(VenueOfferSerializer(offers, many=True).data)
