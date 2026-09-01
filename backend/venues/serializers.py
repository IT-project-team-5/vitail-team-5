from rest_framework import serializers

from .models import Venue, VenueOffer


class VenueOfferSerializer(serializers.ModelSerializer):
    class Meta:
        model = VenueOffer
        fields = ("id", "name", "description", "photo", "point_price", "is_available")
        read_only_fields = fields


class VenueSerializer(serializers.ModelSerializer):
    class Meta:
        model = Venue
        fields = (
            "id",
            "name",
            "venue_type",
            "description",
            "address",
            "latitude",
            "longitude",
            "opening_hours",
            "photo",
            "is_active",
        )
        read_only_fields = fields


class VenueDetailSerializer(VenueSerializer):
    offers = serializers.SerializerMethodField()

    class Meta(VenueSerializer.Meta):
        fields = VenueSerializer.Meta.fields + ("offers",)

    def get_offers(self, venue):
        available_offers = venue.offers.filter(is_available=True).order_by("name")
        return VenueOfferSerializer(available_offers, many=True).data
