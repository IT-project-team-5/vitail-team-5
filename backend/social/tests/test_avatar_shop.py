from concurrent.futures import ThreadPoolExecutor
from datetime import timedelta
from threading import Barrier
from types import SimpleNamespace
from unittest import skipUnless
from unittest.mock import patch
from uuid import uuid4

from django.contrib.auth import get_user_model
from django.core.exceptions import ValidationError
from django.db import close_old_connections, connection
from django.db.models.deletion import ProtectedError
from django.test import TransactionTestCase
from django.utils import timezone
from rest_framework.test import APITestCase

from rewards.models import PointEntry
from rewards.services import InsufficientPointsError, credit_points, get_balance, spend_points
from social.models import AvatarPurchase, AvatarPurchaseRequest, AvatarWardrobe
from social.shop import AvatarShopError, avatar_outfit, purchase_product

User = get_user_model()
DEFAULT_OUTFIT = {"hat": "none", "bandana_style": "classic", "decoration": "none"}


class AvatarShopTests(APITestCase):
    def setUp(self):
        self.owner = User.objects.create_user(email="shop-owner@example.com", display_name="Owner")
        self.other = User.objects.create_user(email="shop-other@example.com", display_name="Other")
        self.cafe = User.objects.create_user(email="shop-cafe@example.com", display_name="Cafe", role="CAFE")
        self.client.force_authenticate(self.owner)

    def buy(self, product_code="baseballCap", request_id=None, **extra):
        return self.client.post("/api/social/avatar-shop/purchases", {
            "product_code": product_code, "request_id": str(request_id or uuid4()), **extra,
        }, format="json")

    def equip(self, category="hats", product_code="baseballCap"):
        return self.client.patch("/api/social/avatar-shop/outfit", {
            "category": category, "product_code": product_code,
        }, format="json")

    def test_get_uses_real_wallet_without_granting_or_exposing_audit_data(self):
        response = self.client.get("/api/social/avatar-shop")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(set(response.data), {"balance", "products", "owned", "outfit"})
        self.assertEqual(response.data["balance"], 0)
        self.assertEqual(response.data["owned"], [])
        self.assertEqual(response.data["outfit"], DEFAULT_OUTFIT)
        self.assertFalse(PointEntry.objects.exists())
        self.assertFalse(AvatarWardrobe.objects.exists())
        self.assertIn("no-store", response["Cache-Control"])
        catalogue = {product["code"]: (product["category"], product["price"]) for product in response.data["products"]}
        self.assertEqual(catalogue, {
            "baseballCap": ("hats", 60), "beanie": ("hats", 50), "sunHat": ("hats", 70),
            "stripedBandana": ("bandanas", 25), "polkaDotBandana": ("bandanas", 20),
            "roundGlasses": ("extras", 35), "starBadge": ("extras", 15),
        })
        for product in response.data["products"]:
            self.assertEqual(set(product), {"code", "title", "description", "category", "price"})

    def test_anonymous_cafe_admin_and_inactive_accounts_are_rejected(self):
        routes = (
            ("get", "/api/social/avatar-shop", None),
            ("post", "/api/social/avatar-shop/purchases", {"product_code": "starBadge", "request_id": str(uuid4())}),
            ("patch", "/api/social/avatar-shop/outfit", {"category": "extras", "product_code": None}),
        )
        inactive = User.objects.create_user(email="shop-inactive@example.com", display_name="Inactive", is_active=False)
        deleted = User.objects.create_user(email="shop-deleted@example.com", display_name="Deleted", deleted_at=timezone.now())
        admin = User.objects.create_user(email="shop-admin@example.com", display_name="Admin", role="ADMIN")
        for user, expected in ((None, 401), (self.cafe, 403), (admin, 403), (inactive, 403), (deleted, 403)):
            self.client.force_authenticate(user)
            for method, path, body in routes:
                with self.subTest(user=user, method=method):
                    response = getattr(self.client, method)(path, body, format="json")
                    self.assertEqual(response.status_code, expected)
                    self.assertIn("no-store", response["Cache-Control"])
        self.assertFalse(AvatarPurchase.objects.exists())
        self.assertFalse(PointEntry.objects.exists())

    def test_purchase_deducts_shared_wallet_once_and_does_not_equip(self):
        first_credit = credit_points(user=self.owner, amount=30, expires_at=timezone.now() + timedelta(days=1))
        second_credit = credit_points(user=self.owner, amount=70, expires_at=timezone.now() + timedelta(days=3))
        response = self.buy()
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.data["balance"], 40)
        self.assertEqual(response.data["owned"], ["baseballCap"])
        self.assertEqual(response.data["outfit"], DEFAULT_OUTFIT)
        self.assertFalse(AvatarWardrobe.objects.exists())
        purchase = AvatarPurchase.objects.get(owner=self.owner)
        self.assertEqual(purchase.point_cost_snapshot, 60)
        self.assertEqual((purchase.spend_entry.user_id, purchase.spend_entry.type, purchase.spend_entry.amount), (self.owner.pk, "SPEND", -60))
        first_credit.refresh_from_db()
        second_credit.refresh_from_db()
        self.assertEqual((first_credit.remaining_points, second_credit.remaining_points), (0, 40))
        self.assertEqual(self.client.get("/api/wallet").data["balance"], 40)

    def test_owner_role_and_activity_are_rechecked_after_the_transaction_lock(self):
        credit_points(user=self.owner, amount=100)
        for values in ({"is_active": False}, {"is_active": True, "role": "CAFE"}, {"role": "OWNER", "deleted_at": timezone.now()}):
            User.objects.filter(pk=self.owner.pk).update(**values)
            # Authentication may have loaded an earlier version of this user.
            for response in (self.client.get("/api/social/avatar-shop"), self.buy(), self.equip(product_code=None)):
                self.assertEqual((response.status_code, response.data["code"]), (403, "OWNER_REQUIRED"))
        self.assertEqual(get_balance(self.owner), 100)
        self.assertFalse(AvatarPurchase.objects.exists())
        self.assertFalse(AvatarWardrobe.objects.exists())

    def test_same_uuid_returns_current_state_without_repeated_spend_or_equip(self):
        credit_points(user=self.owner, amount=100)
        request_id = uuid4()
        self.assertEqual(self.buy(request_id=request_id).status_code, 200)
        self.assertEqual(self.equip().data["outfit"]["hat"], "baseballCap")
        credit_points(user=self.owner, amount=7)
        response = self.buy(request_id=request_id)
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.data["balance"], 47)
        self.assertEqual(response.data["outfit"]["hat"], "baseballCap")
        self.equip(product_code=None)
        self.assertEqual(self.buy(request_id=request_id).data["outfit"], DEFAULT_OUTFIT)
        self.assertEqual(AvatarPurchase.objects.count(), 1)
        self.assertEqual(AvatarPurchaseRequest.objects.count(), 1)
        self.assertEqual(PointEntry.objects.filter(type="SPEND").count(), 1)

    def test_new_uuid_owned_product_is_free_and_alias_conflicts_even_when_other_item_owned(self):
        credit_points(user=self.owner, amount=150)
        original = uuid4()
        alias = uuid4()
        self.buy(request_id=original)
        response = self.buy(request_id=alias)
        self.assertEqual(response.data["balance"], 90)
        self.buy("beanie")
        for request_id in (original, alias):
            response = self.buy("beanie", request_id=request_id)
            self.assertEqual(response.status_code, 409)
            self.assertEqual(response.data["code"], "IDEMPOTENCY_CONFLICT")
        self.assertEqual(get_balance(self.owner), 40)
        self.assertEqual(AvatarPurchase.objects.count(), 2)
        self.assertEqual(AvatarPurchaseRequest.objects.count(), 3)
        self.assertEqual(PointEntry.objects.filter(type="SPEND").count(), 2)

    def test_insufficient_points_and_expired_credits_do_not_create_ownership_or_spend(self):
        expired = credit_points(user=self.owner, amount=100, expires_at=timezone.now() - timedelta(seconds=1))
        valid = credit_points(user=self.owner, amount=59)
        response = self.buy()
        self.assertEqual(response.status_code, 400)
        self.assertEqual(response.data["code"], "INSUFFICIENT_POINTS")
        self.assertEqual(get_balance(self.owner), 59)
        self.assertFalse(AvatarPurchase.objects.exists())
        self.assertFalse(AvatarPurchaseRequest.objects.exists())
        self.assertFalse(PointEntry.objects.filter(type="SPEND").exists())
        expired.refresh_from_db()
        valid.refresh_from_db()
        self.assertEqual((expired.remaining_points, valid.remaining_points), (100, 59))

    def test_invalid_product_uuid_and_forged_price_or_owner_do_not_spend(self):
        credit_points(user=self.owner, amount=100)
        response = self.buy("fakeProduct")
        self.assertEqual((response.status_code, response.data["code"]), (400, "INVALID_PRODUCT"))
        for data in (
            {"product_code": "starBadge"},
            {"product_code": "starBadge", "request_id": "bad-uuid"},
            {"product_code": "starBadge", "request_id": 123},
            {"product_code": "starBadge", "request_id": str(uuid4()), "price": 0},
            {"product_code": "starBadge", "request_id": str(uuid4()), "owner": self.other.pk},
        ):
            response = self.client.post("/api/social/avatar-shop/purchases", data, format="json")
            self.assertEqual((response.status_code, response.data["code"]), (400, "INVALID_REQUEST"))
        self.assertEqual(get_balance(self.owner), 100)
        self.assertFalse(AvatarPurchase.objects.exists())
        self.assertFalse(PointEntry.objects.filter(type="SPEND").exists())

    def test_ownership_balance_uuid_and_outfit_are_isolated_by_owner(self):
        credit_points(user=self.owner, amount=100)
        credit_points(user=self.other, amount=100)
        request_id = uuid4()
        self.buy(request_id=request_id)
        self.equip()
        self.client.force_authenticate(self.other)
        state = self.client.get("/api/social/avatar-shop").data
        self.assertEqual((state["balance"], state["owned"], state["outfit"]), (100, [], DEFAULT_OUTFIT))
        self.assertEqual(self.equip().data["code"], "PRODUCT_NOT_OWNED")
        self.assertEqual(self.buy("beanie", request_id=request_id).status_code, 200)
        self.equip(product_code="beanie")
        self.assertEqual(avatar_outfit(self.owner)["hat"], "baseballCap")
        self.assertEqual(avatar_outfit(self.other)["hat"], "beanie")
        self.assertEqual(get_balance(self.owner), 40)
        self.assertEqual(get_balance(self.other), 50)

    def test_all_categories_can_equip_and_clear_purchased_items_without_charging(self):
        credit_points(user=self.owner, amount=300)
        cases = (
            ("hats", "baseballCap", "hat", "baseballCap"),
            ("hats", "beanie", "hat", "beanie"),
            ("hats", "sunHat", "hat", "sunHat"),
            ("bandanas", "stripedBandana", "bandana_style", "striped"),
            ("bandanas", "polkaDotBandana", "bandana_style", "polkaDot"),
            ("extras", "roundGlasses", "decoration", "roundGlasses"),
            ("extras", "starBadge", "decoration", "starBadge"),
        )
        for category, code, key, value in cases:
            self.assertEqual(self.buy(code).status_code, 200)
            response = self.equip(category, code)
            self.assertEqual(response.status_code, 200)
            self.assertEqual(response.data["outfit"][key], value)
        self.assertEqual(get_balance(self.owner), 25)
        for category in ("hats", "bandanas", "extras"):
            self.assertEqual(self.equip(category, None).status_code, 200)
        self.assertEqual(avatar_outfit(self.owner), DEFAULT_OUTFIT)
        self.assertEqual(get_balance(self.owner), 25)
        self.assertEqual(AvatarPurchase.objects.count(), 7)
        self.assertEqual(PointEntry.objects.filter(type="SPEND").count(), 7)

    def test_equipping_unowned_or_wrong_category_items_is_rejected(self):
        self.assertEqual(self.equip().data["code"], "PRODUCT_NOT_OWNED")
        self.assertEqual(self.equip("extras", "baseballCap").data["code"], "PRODUCT_CATEGORY_MISMATCH")
        self.assertEqual(self.equip("shoes", None).data["code"], "INVALID_CATEGORY")
        self.assertEqual(self.equip("hats", "fakeProduct").data["code"], "INVALID_PRODUCT")
        self.assertFalse(AvatarWardrobe.objects.exists())

    def test_clear_one_category_preserves_other_selections_and_privacy_preferences(self):
        self.owner.location_visibility = "FRIENDS"
        self.owner.net_matching_enabled = True
        self.owner.leaderboard_visible = True
        self.owner.bandana_color = "green"
        self.owner.notification_preferences = {"walk_reminders": False}
        self.owner.save()
        credit_points(user=self.owner, amount=100)
        self.buy("beanie")
        self.buy("polkaDotBandana")
        self.buy("starBadge")
        self.equip("hats", "beanie")
        self.equip("bandanas", "polkaDotBandana")
        self.equip("extras", "starBadge")
        response = self.equip("hats", None)
        self.assertEqual(response.data["outfit"], {"hat": "none", "bandana_style": "polkaDot", "decoration": "starBadge"})
        self.owner.refresh_from_db()
        self.assertEqual(self.owner.location_visibility, "FRIENDS")
        self.assertTrue(self.owner.net_matching_enabled)
        self.assertTrue(self.owner.leaderboard_visible)
        self.assertEqual(self.owner.bandana_color, "green")
        self.assertEqual(self.owner.notification_preferences, {"walk_reminders": False})
        self.assertIsNone(self.owner.active_walk_session_id)

    def test_public_outfit_helper_guards_unowned_unknown_and_wrong_category_state(self):
        AvatarWardrobe.objects.create(owner=self.owner, hat_product_code="beanie", bandana_product_code="stripedBandana", extra_product_code="starBadge")
        self.assertEqual(avatar_outfit(self.owner), DEFAULT_OUTFIT)
        credit_points(user=self.owner, amount=100)
        self.buy("beanie")
        self.assertEqual(avatar_outfit(self.owner), {"hat": "beanie", "bandana_style": "classic", "decoration": "none"})
        corrupt = SimpleNamespace(hat_product_code="starBadge", bandana_product_code="unknown", extra_product_code="beanie")
        with patch("social.shop.AvatarWardrobe.objects.filter") as rows:
            rows.return_value.first.return_value = corrupt
            self.assertEqual(avatar_outfit(self.owner), DEFAULT_OUTFIT)
        self.assertEqual(avatar_outfit(self.cafe), DEFAULT_OUTFIT)

    def test_spend_ownership_and_request_roll_back_together_after_late_failure(self):
        credit = credit_points(user=self.owner, amount=100)
        with patch("social.shop.AvatarPurchaseRequest.objects.create", side_effect=RuntimeError("simulated storage failure")):
            with self.assertRaises(RuntimeError):
                purchase_product(owner=self.owner, product_code="baseballCap", request_id=uuid4())
        credit.refresh_from_db()
        self.assertEqual(credit.remaining_points, 100)
        self.assertFalse(PointEntry.objects.filter(type="SPEND").exists())
        self.assertFalse(AvatarPurchase.objects.exists())
        self.assertFalse(AvatarPurchaseRequest.objects.exists())

    def test_purchase_snapshots_are_immutable_and_protect_wallet_audit_entry(self):
        credit_points(user=self.owner, amount=100)
        self.buy()
        purchase = AvatarPurchase.objects.get(owner=self.owner)
        purchase.point_cost_snapshot = 1
        with self.assertRaises(ValidationError):
            purchase.save()
        purchase.refresh_from_db()
        self.assertEqual(purchase.point_cost_snapshot, 60)
        with self.assertRaises(ProtectedError):
            purchase.spend_entry.delete()


@skipUnless(connection.vendor == "mysql", "Exercises real MySQL owner and wallet row locks")
class AvatarShopConcurrencyTests(TransactionTestCase):
    def setUp(self):
        self.owner = User.objects.create_user(email="shop-parallel@example.com", display_name="Parallel")

    def parallel(self, operation):
        barrier = Barrier(2)

        def worker(index):
            close_old_connections()
            try:
                barrier.wait(timeout=10)
                return operation(index)
            finally:
                close_old_connections()

        with ThreadPoolExecutor(max_workers=2) as pool:
            futures = [pool.submit(worker, index) for index in range(2)]
            return [future.result(timeout=20) for future in futures]

    def test_parallel_same_product_charges_once_with_both_uuids_recorded(self):
        credit_points(user=self.owner, amount=100)
        self.parallel(lambda index: purchase_product(owner=self.owner, product_code="baseballCap", request_id=uuid4()))
        self.assertEqual(get_balance(self.owner), 40)
        self.assertEqual(AvatarPurchase.objects.count(), 1)
        self.assertEqual(AvatarPurchaseRequest.objects.count(), 2)
        self.assertEqual(PointEntry.objects.filter(type="SPEND").count(), 1)

    def test_parallel_replayed_uuid_charges_once(self):
        credit_points(user=self.owner, amount=100)
        request_id = uuid4()
        self.parallel(lambda index: purchase_product(owner=self.owner, product_code="baseballCap", request_id=request_id))
        self.assertEqual(get_balance(self.owner), 40)
        self.assertEqual(AvatarPurchase.objects.count(), 1)
        self.assertEqual(AvatarPurchaseRequest.objects.count(), 1)
        self.assertEqual(PointEntry.objects.filter(type="SPEND").count(), 1)

    def test_parallel_uuid_reuse_for_different_products_conflicts(self):
        credit_points(user=self.owner, amount=150)
        request_id = uuid4()

        def buy(index):
            try:
                purchase_product(owner=self.owner, product_code=("baseballCap", "beanie")[index], request_id=request_id)
                return "purchased"
            except AvatarShopError as exc:
                return exc.code

        self.assertCountEqual(self.parallel(buy), ["purchased", "IDEMPOTENCY_CONFLICT"])
        self.assertEqual(AvatarPurchase.objects.count(), 1)
        self.assertEqual(PointEntry.objects.filter(type="SPEND").count(), 1)

    def test_shop_and_another_wallet_spend_cannot_overdraw_shared_credits(self):
        credit_points(user=self.owner, amount=60)

        def spend(index):
            try:
                if index:
                    spend_points(user=self.owner, amount=50, source_reference="shop-concurrency-other-wallet-spend")
                else:
                    purchase_product(owner=self.owner, product_code="baseballCap", request_id=uuid4())
                return "purchased"
            except (AvatarShopError, InsufficientPointsError):
                return "insufficient"

        self.assertCountEqual(self.parallel(spend), ["purchased", "insufficient"])
        self.assertIn(get_balance(self.owner), (0, 10))
        self.assertEqual(PointEntry.objects.filter(type="SPEND").count(), 1)
