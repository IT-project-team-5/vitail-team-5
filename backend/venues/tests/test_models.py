from django.core.exceptions import ValidationError
from django.db import IntegrityError
from django.test import TestCase

from accounts.models import User
from redemptions.models import RedemptionOrder, RedemptionOrderItem
from venues.models import Venue, VenueOffer


class VenueModelTests(TestCase):
    def setUp(self):
        self.cafe = User.objects.create_user(
            email="cafe@example.com",
            password="StrongPass123!",
            display_name="Example Café",
            role=User.Role.CAFE,
        )
        self.owner = User.objects.create_user(
            email="owner@example.com",
            password="StrongPass123!",
            display_name="Dog Owner",
            role=User.Role.OWNER,
        )

    def test_venue_accepts_a_cafe_account(self):
        venue = Venue(name="Example Café", account=self.cafe)

        venue.full_clean()
        venue.save()

        self.assertEqual(self.cafe.managed_venue, venue)

    def test_venue_rejects_a_non_cafe_account(self):
        venue = Venue(name="Invalid Venue", account=self.owner)

        with self.assertRaisesMessage(
            ValidationError,
            "Only a café account can be attached to a venue.",
        ):
            venue.full_clean()

    def test_a_cafe_account_can_only_be_attached_to_one_venue(self):
        Venue.objects.create(name="First Café", account=self.cafe)

        with self.assertRaises(IntegrityError):
            Venue.objects.create(name="Second Café", account=self.cafe)

    def test_offer_point_price_must_be_positive(self):
        venue = Venue.objects.create(name="Example Café", account=self.cafe)
        offer = VenueOffer(venue=venue, name="Coffee", point_price=0)

        with self.assertRaises(ValidationError):
            offer.full_clean()

    def test_referenced_offer_cannot_move_to_another_venue(self):
        venue = Venue.objects.create(name="Example Café", account=self.cafe)
        other_venue = Venue.objects.create(name="Other Café")
        offer = VenueOffer.objects.create(
            venue=venue,
            name="Coffee",
            point_price=120,
        )
        order = RedemptionOrder.objects.create(
            owner=self.owner,
            venue=venue,
            total_points=120,
        )
        RedemptionOrderItem.objects.create(order=order, venue_offer=offer)
        offer.venue = other_venue

        with self.assertRaisesMessage(
            ValidationError,
            "An offer's venue cannot change after the offer appears in an order.",
        ):
            offer.save()

        offer.refresh_from_db()
        self.assertEqual(offer.venue_id, venue.id)
