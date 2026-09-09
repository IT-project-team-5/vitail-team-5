from django.db import connection
from django.db.migrations.executor import MigrationExecutor
from django.test import TransactionTestCase
from rest_framework.test import APIClient, APITestCase

from accounts.models import CafeProfile, User
from rewards.models import Reward
from rewards.services import create_redemption, credit_points


class CafeProfileApiTests(APITestCase):
    @classmethod
    def setUpTestData(cls):
        cls.cafe = User.objects.create_user(email="profile-cafe@example.com", display_name="Original Café", role="CAFE")
        cls.other_cafe = User.objects.create_user(email="other-profile-cafe@example.com", display_name="Other Café", role="CAFE")
        cls.owner = User.objects.create_user(email="profile-owner@example.com", display_name="Owner")

    def setUp(self):
        self.client.force_authenticate(self.cafe)

    def test_existing_cafe_gets_empty_profile_without_recreating_account(self):
        response = self.client.get("/api/cafe/profile")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.data, {
            "name": "Original Café", "email": self.cafe.email,
            "address": "", "description": "", "opening_hours": "",
        })
        self.assertEqual(CafeProfile.objects.filter(user=self.cafe).count(), 1)
        self.assertEqual(self.client.get("/api/cafe/profile/").status_code, 200)

    def test_editing_own_details_and_partial_updates(self):
        response = self.client.patch("/api/cafe/profile", {
            "name": " New Café ", "address": "12 Coffee Lane",
            "description": "Dog friendly", "opening_hours": "Mon–Fri 8–4",
        }, format="json")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.data["name"], "New Café")
        self.cafe.refresh_from_db()
        self.assertEqual(self.cafe.display_name, "New Café")
        cleared = self.client.patch("/api/cafe/profile", {"description": ""}, format="json")
        self.assertEqual(cleared.status_code, 200)
        self.assertEqual(cleared.data["description"], "")
        self.assertEqual(cleared.data["address"], "12 Coffee Lane")
        self.assertEqual(self.client.get("/api/auth/me").data["display_name"], "New Café")

    def test_profile_cannot_change_email_role_another_user_or_offer_price(self):
        reward = Reward.objects.create(cafe_user=self.cafe, name="Coffee", point_cost=40)
        response = self.client.patch("/api/cafe/profile", {
            "email": "stolen@example.com", "role": "ADMIN", "user_id": self.other_cafe.pk,
            "point_cost": 0, "name": "My Café",
        }, format="json")
        self.assertEqual(response.status_code, 200)
        self.cafe.refresh_from_db()
        self.other_cafe.refresh_from_db()
        reward.refresh_from_db()
        self.assertEqual((self.cafe.email, self.cafe.role), ("profile-cafe@example.com", "CAFE"))
        self.assertEqual(self.other_cafe.display_name, "Other Café")
        self.assertEqual(reward.point_cost, 40)

    def test_profile_is_role_restricted_and_not_puttable(self):
        self.assertEqual(self.client.put("/api/cafe/profile", {}, format="json").status_code, 405)
        self.client.force_authenticate(self.owner)
        self.assertEqual(self.client.get("/api/cafe/profile").status_code, 403)
        self.assertEqual(self.client.patch("/api/cafe/profile", {}, format="json").status_code, 403)
        self.client.force_authenticate(None)
        self.assertEqual(self.client.get("/api/cafe/profile").status_code, 401)

    def test_name_required_if_sent_and_fields_have_simple_length_limits(self):
        for field, value in (("name", "  "), ("name", "a" * 101), ("address", "a" * 256), ("description", "a" * 2001), ("opening_hours", "a" * 501)):
            with self.subTest(field=field):
                response = self.client.patch("/api/cafe/profile", {field: value}, format="json")
                self.assertEqual(response.status_code, 400)
                self.assertIn(field, response.data)
        self.cafe.refresh_from_db()
        self.assertEqual(self.cafe.display_name, "Original Café")

    def test_new_cafe_name_updates_catalogue_but_not_existing_order_snapshot(self):
        reward = Reward.objects.create(cafe_user=self.cafe, name="Coffee", point_cost=40)
        credit_points(user=self.owner, amount=100)
        order = create_redemption(owner=self.owner, reward_id=reward.pk)
        self.client.patch("/api/cafe/profile", {"name": "New Café"}, format="json")
        self.client.force_authenticate(self.owner)
        self.assertEqual(self.client.get("/api/redemptions/rewards").data[0]["cafe_name"], "New Café")
        order.refresh_from_db()
        self.assertEqual(order.cafe_name_snapshot, "Original Café")

    def test_cafes_can_only_read_and_update_their_own_profile(self):
        self.client.patch("/api/cafe/profile", {"address": "First address"}, format="json")
        self.client.force_authenticate(self.other_cafe)
        self.assertEqual(self.client.get("/api/cafe/profile").data["address"], "")
        self.client.patch("/api/cafe/profile", {"address": "Second address"}, format="json")
        self.assertEqual(CafeProfile.objects.get(user=self.cafe).address, "First address")


class CafeProfileMigrationTests(TransactionTestCase):
    def test_forward_migration_preserves_existing_account_and_adds_optional_profile(self):
        executor = MigrationExecutor(connection)
        latest = executor.loader.graph.leaf_nodes()
        old_target = [("accounts", "0001_initial")]
        try:
            executor.migrate(old_target)
            OldUser = executor.loader.project_state(old_target).apps.get_model("accounts", "User")
            old = OldUser.objects.create(email="legacy-cafe-profile@example.com", display_name="Legacy Café", role="CAFE")
            MigrationExecutor(connection).migrate(latest)
            user = User.objects.get(pk=old.pk)
            self.assertEqual((user.email, user.display_name, user.role), (old.email, old.display_name, old.role))
            client = APIClient()
            client.force_authenticate(user)
            self.assertEqual(client.get("/api/cafe/profile").data["name"], "Legacy Café")
            self.assertEqual(CafeProfile.objects.get(user=user).address, "")
        finally:
            MigrationExecutor(connection).migrate(latest)
