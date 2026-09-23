from django.contrib.auth import get_user_model
from rest_framework.test import APITestCase
from rest_framework_simplejwt.tokens import AccessToken

from rewards.models import Redemption, Reward
from rewards.services import create_redemption, credit_points, get_balance


User = get_user_model()


class CafeProductsApiTests(APITestCase):
    url = "/api/cafe/products"

    @classmethod
    def setUpTestData(cls):
        cls.cafe = User.objects.create_user(
            email="menu-cafe@example.com", display_name="Corner Café", role="CAFE"
        )
        cls.other_cafe = User.objects.create_user(
            email="other-menu-cafe@example.com", display_name="Other Café", role="CAFE"
        )
        cls.owner = User.objects.create_user(
            email="menu-owner@example.com", display_name="Dog Owner"
        )
        cls.admin = User.objects.create_superuser(
            email="menu-admin@example.com", password="StrongAdmin123!", display_name="Admin"
        )
        cls.product = Reward.objects.create(
            cafe_user=cls.cafe, name="Flat white", description="Double espresso and milk", point_cost=40
        )
        cls.unavailable = Reward.objects.create(
            cafe_user=cls.cafe, name="Croissant", point_cost=50, is_available=False
        )
        cls.other_product = Reward.objects.create(
            cafe_user=cls.other_cafe, name="Other coffee", point_cost=30
        )

    def setUp(self):
        self.client.force_authenticate(self.cafe)

    def update(self, data, product=None):
        return self.client.patch(f"{self.url}/{(product or self.product).pk}", data, format="json")

    def test_list_includes_only_own_products_including_unavailable(self):
        response = self.client.get(self.url)
        self.assertEqual(response.status_code, 200)
        self.assertEqual({row["id"] for row in response.data}, {self.product.pk, self.unavailable.pk})
        self.assertEqual(response.data[0], {
            "id": self.product.pk, "name": "Flat white", "description": "Double espresso and milk",
            "point_cost": 40, "is_available": True,
        })

    def test_empty_menu_returns_an_empty_array(self):
        Reward.objects.filter(cafe_user=self.other_cafe).delete()
        self.client.force_authenticate(self.other_cafe)
        response = self.client.get(self.url)
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.data, [])

    def test_create_assigns_signed_in_cafe_and_defaults_then_appears_in_owner_catalogue(self):
        response = self.client.post(self.url, {"name": "  Iced latte  ", "point_cost": 60}, format="json")
        self.assertEqual(response.status_code, 201)
        product = Reward.objects.get(pk=response.data["id"])
        self.assertEqual(product.cafe_user_id, self.cafe.pk)
        self.assertEqual(response.data, {
            "id": product.pk, "name": "Iced latte", "description": "", "point_cost": 60,
            "is_available": True,
        })
        self.client.force_authenticate(self.owner)
        catalogue = self.client.get("/api/redemptions/rewards").data
        self.assertIn(product.pk, {row["id"] for row in catalogue})

    def test_create_unavailable_product_stays_out_of_owner_catalogue(self):
        response = self.client.post(self.url, {
            "name": "Coming soon", "description": "Seasonal special", "point_cost": 65,
            "is_available": False,
        }, format="json")
        self.assertEqual(response.status_code, 201)
        self.assertFalse(response.data["is_available"])
        self.client.force_authenticate(self.owner)
        self.assertNotIn(response.data["id"], {
            row["id"] for row in self.client.get("/api/redemptions/rewards").data
        })

    def test_partial_update_preserves_other_fields_and_can_clear_description(self):
        response = self.update({"name": "  Oat flat white  ", "point_cost": 55})
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.data["name"], "Oat flat white")
        self.assertEqual(response.data["point_cost"], 55)
        self.assertEqual(response.data["description"], self.product.description)
        self.assertTrue(response.data["is_available"])
        self.assertEqual(self.update({"description": ""}).data["description"], "")
        self.product.refresh_from_db()
        self.assertEqual(self.product.cafe_user_id, self.cafe.pk)

    def test_unlisting_prevents_new_orders_and_relisting_restores_catalogue(self):
        self.assertEqual(self.update({"is_available": False}).status_code, 200)
        self.client.force_authenticate(self.owner)
        credit_points(user=self.owner, amount=100)
        self.assertNotIn(self.product.pk, {
            row["id"] for row in self.client.get("/api/redemptions/rewards").data
        })
        response = self.client.post("/api/redemptions", {"reward_id": self.product.pk}, format="json")
        self.assertEqual(response.status_code, 400)
        self.assertEqual(response.data["code"], "REWARD_UNAVAILABLE")
        self.assertEqual(get_balance(self.owner), 100)
        self.assertFalse(Redemption.objects.exists())
        self.client.force_authenticate(self.cafe)
        self.assertEqual(self.update({"is_available": True}).status_code, 200)
        self.client.force_authenticate(self.owner)
        self.assertIn(self.product.pk, {
            row["id"] for row in self.client.get("/api/redemptions/rewards").data
        })

    def test_edit_and_unlist_preserve_existing_order_snapshots_feed_history_and_collection(self):
        credit_points(user=self.owner, amount=100)
        order = create_redemption(owner=self.owner, reward_id=self.product.pk)
        response = self.update({"name": "New menu item", "point_cost": 90, "is_available": False})
        self.assertEqual(response.status_code, 200)
        order.refresh_from_db()
        self.assertEqual((order.reward_name_snapshot, order.point_cost_snapshot), ("Flat white", 40))
        self.assertEqual((order.cafe_user_id, order.cafe_name_snapshot), (self.cafe.pk, "Corner Café"))
        feed = self.client.get("/api/cafe/orders").data["upserts"]
        self.assertEqual(feed[0]["items"], [{"name": "Flat white", "quantity": 1}])
        self.client.force_authenticate(self.owner)
        history = self.client.get("/api/redemptions").data
        self.assertEqual(history[0]["reward_name_snapshot"], "Flat white")
        self.assertEqual(history[0]["point_cost_snapshot"], 40)
        self.assertEqual(self.client.post(f"/api/redemptions/{order.pk}/collect").status_code, 200)
        self.assertEqual(get_balance(self.owner), 60)

    def test_other_cafe_and_missing_product_ids_return_404_without_changes(self):
        for product_id in (self.other_product.pk, 999999):
            with self.subTest(product_id=product_id):
                response = self.client.patch(f"{self.url}/{product_id}", {"name": "Taken over"}, format="json")
                self.assertEqual(response.status_code, 404)
        self.other_product.refresh_from_db()
        self.assertEqual(self.other_product.name, "Other coffee")

    def test_owner_and_admin_roles_cannot_use_cafe_product_api(self):
        for user in (self.owner, self.admin):
            with self.subTest(role=user.role):
                self.client.force_authenticate(user)
                self.assertEqual(self.client.get(self.url).status_code, 403)
                self.assertEqual(self.client.post(self.url, {"name": "Invalid", "point_cost": 1}).status_code, 403)
                self.assertEqual(self.update({"point_cost": 1}).status_code, 403)
        self.assertEqual(Reward.objects.count(), 3)

    def test_unauthenticated_requests_and_inactive_cafe_tokens_are_rejected(self):
        self.client.force_authenticate(None)
        for inactive in (False, True):
            with self.subTest(inactive=inactive):
                if inactive:
                    token = str(AccessToken.for_user(self.cafe))
                    User.objects.filter(pk=self.cafe.pk).update(is_active=False)
                    self.client.credentials(HTTP_AUTHORIZATION=f"Bearer {token}")
                self.assertEqual(self.client.get(self.url).status_code, 401)
                self.assertEqual(self.client.post(self.url, {"name": "Invalid", "point_cost": 1}).status_code, 401)
                self.assertEqual(self.update({"point_cost": 1}).status_code, 401)

    def test_create_and_update_reject_ownership_id_and_unknown_field_injection(self):
        for field, value in (
            ("id", self.other_product.pk), ("cafe_user", self.other_cafe.pk),
            ("cafe_user_id", self.other_cafe.pk), ("owner_user", self.owner.pk),
            ("created_at", "2020-01-01T00:00:00Z"), ("unexpected", "value"),
        ):
            with self.subTest(field=field):
                created = self.client.post(self.url, {"name": "Invalid", "point_cost": 1, field: value}, format="json")
                self.assertEqual(created.status_code, 400)
                self.assertIn(field, created.data)
                edited = self.update({"name": "Invalid", field: value})
                self.assertEqual(edited.status_code, 400)
                self.assertIn(field, edited.data)
        self.product.refresh_from_db()
        self.assertEqual((self.product.cafe_user_id, self.product.name), (self.cafe.pk, "Flat white"))
        self.assertEqual(Reward.objects.count(), 3)

    def test_create_requires_name_and_price(self):
        response = self.client.post(self.url, {}, format="json")
        self.assertEqual(response.status_code, 400)
        self.assertEqual(set(response.data), {"name", "point_cost"})

    def test_invalid_product_fields_reject_whole_create_and_update(self):
        for field, values in {
            "name": ("", "   ", "x" * 101, None),
            "description": ("x" * 2001, None),
            "point_cost": (0, -1, 1.5, 2147483648, None, "many", True),
            "is_available": (None, "maybe"),
        }.items():
            for value in values:
                with self.subTest(field=field, value=repr(value)[:40]):
                    created = self.client.post(self.url, {"name": "Invalid", "point_cost": 5, field: value}, format="json")
                    self.assertEqual(created.status_code, 400)
                    self.assertIn(field, created.data)
                    edited = self.update({"name": "Invalid", field: value})
                    self.assertEqual(edited.status_code, 400)
                    self.assertIn(field, edited.data)
        self.product.refresh_from_db()
        self.assertEqual((self.product.name, self.product.point_cost), ("Flat white", 40))
        self.assertEqual(Reward.objects.count(), 3)

    def test_field_limits_are_accepted(self):
        response = self.client.post(self.url, {
            "name": "x" * 100, "description": "x" * 2000, "point_cost": 2147483647,
        }, format="json")
        self.assertEqual(response.status_code, 201)
        self.assertEqual(response.data["point_cost"], 2147483647)

    def test_optional_trailing_slash_and_no_destructive_delete(self):
        self.assertEqual(self.client.get(self.url + "/").status_code, 200)
        self.assertEqual(self.client.post(self.url + "/", {"name": "Tea", "point_cost": 30}).status_code, 201)
        self.assertEqual(self.client.patch(f"{self.url}/{self.product.pk}/", {"point_cost": 45}).status_code, 200)
        self.assertEqual(self.client.delete(f"{self.url}/{self.product.pk}").status_code, 405)
        self.assertTrue(Reward.objects.filter(pk=self.product.pk).exists())
