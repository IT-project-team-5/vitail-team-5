from django.contrib.auth import get_user_model
from rest_framework import status
from rest_framework.test import APITestCase

from venues.models import Venue, VenueOffer

User = get_user_model()


class VenueApiTests(APITestCase):
    def setUp(self):
        self.owner = User.objects.create_user(
            email="owner@example.com", password="StrongPass123!", display_name="Dog Owner"
        )
        self.client.force_authenticate(self.owner)

        self.active_venue = Venue.objects.create(
            name="Corner Café",
            venue_type=Venue.VenueType.CAFE,
            latitude="-37.8136",
            longitude="144.9631",
        )
        self.inactive_venue = Venue.objects.create(
            name="Closed Café",
            venue_type=Venue.VenueType.CAFE,
            latitude="-37.8136",
            longitude="144.9631",
            is_active=False,
        )
        self.available_offer = VenueOffer.objects.create(
            venue=self.active_venue, name="Small Coffee", point_price=40
        )
        self.unavailable_offer = VenueOffer.objects.create(
            venue=self.active_venue, name="Retired Item", point_price=10, is_available=False
        )

    def test_venue_list_returns_only_active_venues(self):
        response = self.client.get("/api/venues/")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        names = {venue["name"] for venue in response.data}
        self.assertIn("Corner Café", names)
        self.assertNotIn("Closed Café", names)

    def test_venue_detail_includes_only_available_offers(self):
        response = self.client.get(f"/api/venues/{self.active_venue.id}")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        offer_names = {offer["name"] for offer in response.data["offers"]}
        self.assertEqual(offer_names, {"Small Coffee"})

    def test_venue_offers_endpoint_matches_detail(self):
        response = self.client.get(f"/api/venues/{self.active_venue.id}/offers")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(len(response.data), 1)
        self.assertEqual(response.data[0]["name"], "Small Coffee")

    def test_browsing_venues_requires_authentication(self):
        self.client.force_authenticate(None)

        response = self.client.get("/api/venues/")

        self.assertEqual(response.status_code, status.HTTP_401_UNAUTHORIZED)
