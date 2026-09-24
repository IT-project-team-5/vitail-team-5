import base64
import io
import tempfile
from decimal import Decimal

from django.core.exceptions import ValidationError
from django.core.files.storage import default_storage
from django.db import connection, IntegrityError, transaction
from django.db.models.deletion import ProtectedError
from django.test import override_settings
from django.test.utils import CaptureQueriesContext
from PIL import Image
from rest_framework.test import APITestCase

from accounts.models import User
from rewards.models import Reward
from rewards.services import create_redemption, credit_points
from venues.models import Venue
from venues.services import venue_for


class VenueTests(APITestCase):
    @classmethod
    def setUpTestData(cls):
        cls.cafe = User.objects.create_user(email="venue-cafe@example.com", display_name="Manager", role="CAFE")
        cls.other = User.objects.create_user(email="venue-other@example.com", display_name="Other", role="CAFE")
        cls.owner = User.objects.create_user(email="venue-owner@example.com", display_name="Owner")
        cls.venue = Venue.objects.create(pk=cls.cafe.pk + 1000, manager_user=cls.cafe, name="Public café", is_partner=True)
        cls.reward = Reward.objects.create(venue=cls.venue, name="Coffee", point_cost=60)

    def setUp(self):
        self.client.force_authenticate(self.cafe)

    def test_one_managed_venue_per_account_and_unmanaged_place_is_supported(self):
        with CaptureQueriesContext(connection) as queries:
            self.assertEqual(venue_for(self.cafe).pk, self.venue.pk)
        self.assertEqual(len(queries), 1)
        self.assertNotIn("accounts_user", queries[0]["sql"])
        with self.assertRaises(IntegrityError), transaction.atomic():
            Venue.objects.create(manager_user=self.cafe, name="Duplicate")
        park = Venue.objects.create(kind=Venue.Kind.PARK, name="Park")
        self.assertIsNone(park.manager_user_id)
        self.assertFalse(park.checkin_enabled)
        self.assertIsNone(park.latitude)
        self.assertIsNone(park.longitude)
        with self.assertRaisesMessage(ValueError, "café accounts"):
            venue_for(self.owner)

    def test_database_rejects_invalid_coordinate_pairs_ranges_and_enabled_without_location(self):
        for values in ({"latitude": 0}, {"longitude": 0}, {"latitude": 91, "longitude": 0},
                       {"latitude": 0, "longitude": -181}, {"checkin_enabled": True}):
            with self.subTest(values=values), self.assertRaises(IntegrityError), transaction.atomic():
                Venue.objects.create(name="Invalid", **values)
        park = Venue.objects.create(name="Located park", kind="PARK", latitude=Decimal("-37.813600"), longitude=Decimal("144.963100"), checkin_enabled=True)
        self.assertTrue(park.checkin_enabled)

    def test_manager_validation_requires_active_cafe_but_an_unmanaged_place_is_valid(self):
        venue = Venue(name="Wrong manager", manager_user=self.owner)
        with self.assertRaises(ValidationError):
            venue.full_clean()
        self.other.is_active = False
        self.other.save(update_fields=["is_active"])
        venue.manager_user = self.other
        with self.assertRaises(ValidationError):
            venue.full_clean()
        Venue(name="Public park", kind="PARK").full_clean()

    def test_profile_and_personal_identity_are_independent_and_venue_id_cannot_be_injected(self):
        other_venue = venue_for(self.other)
        self.assertNotEqual(self.venue.pk, self.cafe.pk)
        response = self.client.patch("/api/cafe/profile", {"name": "New public name", "venue_id": other_venue.pk, "manager_user": self.other.pk}, format="json")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.data["venue_id"], self.venue.pk)
        self.venue.refresh_from_db()
        self.cafe.refresh_from_db()
        other_venue.refresh_from_db()
        self.assertEqual(self.venue.name, "New public name")
        self.assertEqual(self.cafe.display_name, "Manager")
        self.assertEqual(other_venue.name, "Other")
        self.client.patch("/api/auth/me", {"display_name": "New personal name"}, format="json")
        self.assertEqual(self.client.get("/api/cafe/profile").data["name"], "New public name")
        self.client.force_authenticate(self.owner)
        catalogue = self.client.get("/api/redemptions/rewards").data[0]
        self.assertEqual((catalogue["cafe_id"], catalogue["venue_id"], catalogue["cafe_name"]), (self.cafe.pk, self.venue.pk, "New public name"))

    def test_venue_and_personal_photo_replacements_never_remove_each_others_files(self):
        with tempfile.TemporaryDirectory() as media, override_settings(MEDIA_ROOT=media):
            output = io.BytesIO()
            Image.new("RGB", (24, 24), "red").save(output, format="JPEG")
            payload = {"image_base64": base64.b64encode(output.getvalue()).decode()}
            first_person = self.client.post("/api/auth/me/photo", payload, format="json")
            first_venue = self.client.post("/api/cafe/profile/photo", payload, format="json")
            self.assertEqual(first_person.status_code, 200)
            self.assertEqual(first_venue.status_code, 200)
            self.cafe.refresh_from_db()
            self.venue.refresh_from_db()
            personal_name, venue_name = self.cafe.photo.name, self.venue.photo.name
            self.assertNotEqual(personal_name, venue_name)
            with self.captureOnCommitCallbacks(execute=True):
                self.client.post("/api/auth/me/photo", payload, format="json")
            self.assertFalse(default_storage.exists(personal_name))
            self.assertTrue(default_storage.exists(venue_name))
            self.cafe.refresh_from_db()
            with self.captureOnCommitCallbacks(execute=True):
                self.client.post("/api/cafe/profile/photo", payload, format="json")
            self.assertFalse(default_storage.exists(venue_name))
            self.assertTrue(default_storage.exists(self.cafe.photo.name))

    def test_catalogue_and_purchase_hide_inactive_nonpartner_or_unmanaged_venues(self):
        credit_points(user=self.owner, amount=100)
        self.client.force_authenticate(self.owner)
        for field, value in (("is_active", False), ("is_partner", False), ("manager_user", None)):
            with self.subTest(field=field):
                original = getattr(self.venue, field)
                setattr(self.venue, field, value)
                self.venue.save(update_fields=[field])
                self.assertEqual(self.client.get("/api/redemptions/rewards").data, [])
                response = self.client.post("/api/redemptions", {"reward_id": self.reward.pk}, format="json")
                self.assertEqual(response.status_code, 400)
                self.assertEqual(response.data["code"], "REWARD_UNAVAILABLE")
                setattr(self.venue, field, original)
                self.venue.save(update_fields=[field])

    def test_order_history_keeps_venue_and_responsible_account_after_product_move(self):
        credit_points(user=self.owner, amount=100)
        order = create_redemption(owner=self.owner, reward_id=self.reward.pk)
        other_venue = venue_for(self.other)
        self.reward.venue = other_venue
        self.reward.save(update_fields=["venue"])
        self.client.force_authenticate(self.owner)
        result = self.client.get("/api/redemptions").data[0]
        self.assertEqual((result["cafe_id"], result["venue_id"], result["cafe_name_snapshot"]), (self.cafe.pk, self.venue.pk, "Public café"))
        self.assertEqual(order.cafe_user_id, self.cafe.pk)
        with self.assertRaises(ProtectedError):
            self.venue.delete()
        with self.assertRaises(ProtectedError):
            self.cafe.delete()

    def test_deleting_unused_manager_preserves_unmanaged_public_place(self):
        other_venue = venue_for(self.other)
        self.other.delete()
        other_venue.refresh_from_db()
        self.assertIsNone(other_venue.manager_user_id)
        self.assertEqual(other_venue.name, "Other")
