from datetime import timedelta

from django.contrib.auth import get_user_model
from django.utils import timezone
from rest_framework import status
from rest_framework.test import APITestCase

from redemptions.models import RedemptionOrder
from venues.models import Venue, VenueOffer
from wallets.models import PointLot

User = get_user_model()


class RedemptionOrderApiTests(APITestCase):
    orders_url = "/api/redemptions/orders"

    def setUp(self):
        self.owner = User.objects.create_user(
            email="owner@example.com", password="StrongPass123!", display_name="Dog Owner"
        )
        self.other_owner = User.objects.create_user(
            email="other@example.com", password="StrongPass123!", display_name="Other Owner"
        )
        self.client.force_authenticate(self.owner)

        self.venue = Venue.objects.create(
            name="Corner Café",
            venue_type=Venue.VenueType.CAFE,
            latitude="-37.8136",
            longitude="144.9631",
        )
        self.other_venue = Venue.objects.create(
            name="Second Venue",
            venue_type=Venue.VenueType.CAFE,
            latitude="-37.8136",
            longitude="144.9631",
        )
        self.coffee = VenueOffer.objects.create(venue=self.venue, name="Small Coffee", point_price=40)
        self.pastry = VenueOffer.objects.create(venue=self.venue, name="Pastry", point_price=25)

    def grant(self, owner, amount, days_until_expiry=300):
        return PointLot.objects.create(
            owner=owner,
            source=PointLot.Source.ADMIN_GRANT,
            amount_earned=amount,
            amount_remaining=amount,
            expires_at=timezone.now() + timedelta(days=days_until_expiry),
        )

    def create_order(self, venue_id=None, items=None):
        return self.client.post(
            self.orders_url,
            {
                "venue_id": venue_id or self.venue.id,
                "items": items or [{"offer_id": self.coffee.id, "quantity": 1}],
            },
            format="json",
        )

    def test_creating_an_order_deducts_points_and_issues_a_reference_number(self):
        self.grant(self.owner, 100)

        response = self.create_order(items=[{"offer_id": self.coffee.id, "quantity": 2}])

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(response.data["status"], RedemptionOrder.Status.PENDING)
        self.assertEqual(response.data["total_points"], 80)
        self.assertTrue(response.data["reference_number"])

        order = RedemptionOrder.objects.get(id=response.data["id"])
        self.assertEqual(order.owner, self.owner)
        self.assertEqual(order.items.count(), 1)
        self.assertEqual(self.client.get("/api/wallet/").data["balance"], 20)

    def test_creating_an_order_with_insufficient_points_is_rejected_and_nothing_is_deducted(self):
        self.grant(self.owner, 10)

        response = self.create_order()

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(response.data["code"], "INSUFFICIENT_POINTS")
        self.assertEqual(RedemptionOrder.objects.count(), 0)
        self.assertEqual(self.client.get("/api/wallet/").data["balance"], 10)

    def test_an_offer_from_another_venue_is_rejected(self):
        self.grant(self.owner, 100)
        foreign_offer = VenueOffer.objects.create(venue=self.other_venue, name="Tea", point_price=10)

        response = self.create_order(items=[{"offer_id": foreign_offer.id, "quantity": 1}])

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(RedemptionOrder.objects.count(), 0)

    def test_owner_can_collect_a_pending_order(self):
        self.grant(self.owner, 100)
        order_id = self.create_order().data["id"]

        response = self.client.post(f"{self.orders_url}/{order_id}/collect")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["status"], RedemptionOrder.Status.COLLECTED)
        self.assertIsNotNone(RedemptionOrder.objects.get(id=order_id).collected_at)

    def test_collecting_an_already_collected_order_is_idempotent(self):
        self.grant(self.owner, 100)
        order_id = self.create_order().data["id"]
        self.client.post(f"{self.orders_url}/{order_id}/collect")

        response = self.client.post(f"{self.orders_url}/{order_id}/collect")

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["status"], RedemptionOrder.Status.COLLECTED)

    def test_owner_cannot_collect_another_owners_order(self):
        self.grant(self.owner, 100)
        order_id = self.create_order().data["id"]
        self.client.force_authenticate(self.other_owner)

        response = self.client.post(f"{self.orders_url}/{order_id}/collect")

        self.assertEqual(response.status_code, status.HTTP_404_NOT_FOUND)
        self.assertEqual(
            RedemptionOrder.objects.get(id=order_id).status, RedemptionOrder.Status.PENDING
        )

    def test_order_history_only_returns_the_signed_in_owners_orders(self):
        self.grant(self.owner, 100)
        self.create_order()
        self.grant(self.other_owner, 100)
        self.client.force_authenticate(self.other_owner)
        self.create_order()

        self.client.force_authenticate(self.owner)
        response = self.client.get(self.orders_url)

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(len(response.data), 1)
