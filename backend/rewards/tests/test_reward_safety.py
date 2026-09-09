from concurrent.futures import ThreadPoolExecutor
from datetime import timedelta
from io import StringIO
from threading import Barrier
from uuid import uuid4

from django.contrib import admin
from django.contrib.auth import get_user_model
from django.core.management import call_command
from django.db import close_old_connections
from django.db.models.deletion import ProtectedError
from django.test import RequestFactory, TestCase, TransactionTestCase, skipUnlessDBFeature
from django.utils import timezone
from rest_framework.test import APIClient

from accounts.forms import AdminUserChangeForm
from rewards.admin import PointEntryAdmin, PointGrantForm, RedemptionAdmin
from rewards.models import PointEntry, Redemption, Reward
from rewards.services import (
    IdempotencyConflictError, RedemptionNotCollectibleError, cancel_redemption, collect_redemption,
    create_redemption, credit_points, expire_points, expire_redemptions,
    get_balance, spend_points,
)


User = get_user_model()


class RewardSafetyTests(TestCase):
    @classmethod
    def setUpTestData(cls):
        cls.owner = User.objects.create_user(email="safety-owner@example.com", display_name="Owner")
        cls.cafe = User.objects.create_user(email="safety-cafe@example.com", display_name="Café", role="CAFE")
        cls.other_cafe = User.objects.create_user(email="safety-other-cafe@example.com", display_name="Other Café", role="CAFE")
        cls.staff = User.objects.create_superuser(email="safety-admin@example.com", password="TestAdmin572!", display_name="Admin")
        cls.reward = Reward.objects.create(cafe_user=cls.cafe, name="Coffee", point_cost=40)

    def setUp(self):
        self.api = APIClient()
        self.api.force_authenticate(self.owner)
        credit_points(user=self.owner, amount=100)

    def order(self):
        return create_redemption(owner=self.owner, reward_id=self.reward.pk)

    def test_nearest_expiry_spent_first_with_stable_tie_order(self):
        original = PointEntry.objects.get(user=self.owner)
        soon = credit_points(user=self.owner, amount=30, expires_at=timezone.now() + timedelta(days=1))
        self.order()
        original.refresh_from_db()
        soon.refresh_from_db()
        self.assertEqual(soon.remaining_points, 0)
        self.assertEqual(original.remaining_points, 90)

    def test_repeated_credit_and_spend_events_do_not_change_balance_twice(self):
        grant = dict(user=self.owner, amount=10, source_reference="grant:safe-repeat")
        self.assertEqual(credit_points(**grant).pk, credit_points(**grant).pk)
        debit = dict(user=self.owner, amount=20, source_reference="spend:safe-repeat")
        self.assertEqual(spend_points(**debit).pk, spend_points(**debit).pk)
        self.assertEqual(get_balance(self.owner), 90)
        with self.assertRaises(IdempotencyConflictError):
            credit_points(**{**grant, "amount": 11})

    def test_admin_cancel_refunds_once_and_removes_from_feed(self):
        order = self.order()
        self.api.force_authenticate(self.cafe)
        initial = self.api.get("/api/cafe/orders")
        self.assertTrue(cancel_redemption(redemption_id=order.pk))
        self.assertFalse(cancel_redemption(redemption_id=order.pk))
        self.assertEqual(get_balance(self.owner), 100)
        order.refresh_from_db()
        self.assertEqual(order.status, Redemption.Status.CANCELLED)
        self.assertEqual(PointEntry.objects.filter(type="REFUND").count(), 1)
        removed = self.api.get("/api/cafe/orders", {"since": initial.data["cursor"]})
        self.assertEqual(removed.data["removed_ids"], [order.pk])

    def test_collected_order_cannot_be_cancelled_or_refunded(self):
        order = self.order()
        collect_redemption(owner=self.owner, redemption_id=order.pk)
        self.assertFalse(cancel_redemption(redemption_id=order.pk))
        self.assertEqual(get_balance(self.owner), 60)
        self.assertFalse(PointEntry.objects.filter(type="REFUND").exists())

    def test_scheduled_expiry_is_idempotent_for_orders_and_points(self):
        order = self.order()
        Redemption.objects.filter(pk=order.pk).update(expires_at=timezone.now() - timedelta(seconds=1))
        credit_points(user=self.owner, amount=5, expires_at=timezone.now() - timedelta(days=1))
        for _ in range(2):
            call_command("expire_rewards", stdout=StringIO())
        self.assertEqual(get_balance(self.owner), 100)
        self.assertEqual(PointEntry.objects.filter(type="REFUND").count(), 1)
        self.assertEqual(list(PointEntry.objects.filter(type="EXPIRE").values_list("amount", flat=True)), [-5])
        self.assertEqual(expire_redemptions(), 0)
        self.assertEqual(expire_points(), 0)

    def test_cafe_edits_do_not_reroute_existing_order_or_rename_snapshots(self):
        order = self.order()
        Reward.objects.filter(pk=self.reward.pk).update(cafe_user=self.other_cafe, name="New item", point_cost=80)
        User.objects.filter(pk=self.owner.pk).update(display_name="New owner name")
        User.objects.filter(pk=self.cafe.pk).update(display_name="New café name")
        order.refresh_from_db()
        self.assertEqual(order.cafe_user_id, self.cafe.pk)
        self.assertEqual(order.owner_name_snapshot, "Owner")
        self.assertEqual(order.cafe_name_snapshot, "Café")
        self.assertEqual(order.reward_name_snapshot, "Coffee")
        self.assertEqual(order.point_cost_snapshot, 40)
        self.api.force_authenticate(self.cafe)
        self.assertEqual([item["id"] for item in self.api.get("/api/cafe/orders").data["upserts"]], [order.pk])
        self.api.force_authenticate(self.other_cafe)
        self.assertEqual(self.api.get("/api/cafe/orders").data["upserts"], [])

    def test_catalogue_excludes_disabled_or_wrong_role_cafes_and_creation_fails(self):
        for changes in ({"is_active": False}, {"is_active": True, "role": "OWNER"}):
            User.objects.filter(pk=self.cafe.pk).update(**changes)
            self.assertEqual(self.api.get("/api/redemptions/rewards").data, [])
            response = self.api.post("/api/redemptions", {"reward_id": self.reward.pk}, format="json")
            self.assertEqual(response.status_code, 400)
            self.assertEqual(response.data["code"], "REWARD_UNAVAILABLE")
        self.assertEqual(get_balance(self.owner), 100)

    def test_replay_still_resolves_order_after_offer_is_disabled(self):
        request_id = uuid4()
        order = create_redemption(owner=self.owner, reward_id=self.reward.pk, request_id=request_id)
        Reward.objects.filter(pk=self.reward.pk).update(is_available=False)
        replay = create_redemption(owner=self.owner, reward_id=self.reward.pk, request_id=request_id)
        self.assertEqual(replay.pk, order.pk)
        self.assertEqual(get_balance(self.owner), 60)

    def test_malformed_cafe_cursor_is_rejected_and_other_cafe_changes_do_not_advance_it(self):
        self.api.force_authenticate(self.other_cafe)
        initial = self.api.get("/api/cafe/orders")
        self.order()
        self.assertEqual(self.api.get("/api/cafe/orders", {"since": initial.data["cursor"]}).status_code, 304)
        for value in ("", "-1", "abc", "1.5", "9" * 20, "1&since=1"):
            self.assertEqual(self.api.get(f"/api/cafe/orders?since={value}").status_code, 400)
        self.assertEqual(self.api.get("/api/cafe/orders?since=1").status_code, 400)

    def test_urls_accept_both_slash_styles_and_unauthenticated_is_401(self):
        for path in ("/api/wallet", "/api/wallet/ledger", "/api/redemptions", "/api/redemptions/rewards"):
            for url in (path, path + "/"):
                self.assertEqual(self.api.get(url).status_code, 200)
        self.api.force_authenticate(None)
        for path in ("/api/wallet", "/api/redemptions", "/api/cafe/orders"):
            self.assertEqual(self.api.get(path).status_code, 401)

    def test_point_grant_form_rejects_negative_amount_and_cafe_user(self):
        data = {"user": self.owner.pk, "amount": -40, "expires_at": timezone.now() + timedelta(days=30)}
        form = PointGrantForm(data)
        self.assertFalse(form.is_valid())
        self.assertIn("amount", form.errors)
        cafe_form = PointGrantForm({**data, "amount": 10, "user": self.cafe.pk})
        self.assertFalse(cafe_form.is_valid())
        self.assertIn("user", cafe_form.errors)

    def test_admin_grant_ignores_tampered_type_and_remaining_points(self):
        self.client.force_login(self.staff)
        expiry = timezone.localtime() + timedelta(days=30)
        response = self.client.post("/admin/rewards/pointentry/add/", {
            "user": self.owner.pk, "amount": "10", "type": "SPEND", "remaining_points": "999",
            "expires_at_0": expiry.strftime("%Y-%m-%d"), "expires_at_1": expiry.strftime("%H:%M:%S"),
            "_save": "Save",
        })
        self.assertEqual(response.status_code, 302)
        entry = PointEntry.objects.latest("pk")
        self.assertEqual((entry.amount, entry.remaining_points, entry.type), (10, 10, "ADMIN"))
        self.assertEqual(get_balance(self.owner), 110)

    def test_admin_cannot_delete_audit_records_and_users_are_protected(self):
        order = self.order()
        request = RequestFactory().get("/admin/")
        request.user = self.staff
        self.assertFalse(PointEntryAdmin(PointEntry, admin.site).has_delete_permission(request))
        self.assertFalse(RedemptionAdmin(Redemption, admin.site).has_delete_permission(request))
        with self.assertRaises(ProtectedError):
            self.owner.delete()
        with self.assertRaises(ProtectedError):
            self.cafe.delete()

    def test_reading_feed_without_rewards_is_valid_empty_state(self):
        self.api.force_authenticate(self.other_cafe)
        response = self.api.get("/api/cafe/orders")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.data, {"cursor": 0, "upserts": [], "removed_ids": [], "reset": True})

    def test_admin_cannot_change_roles_and_strand_existing_points(self):
        form = AdminUserChangeForm({
            "email": self.owner.email, "display_name": self.owner.display_name,
            "role": "CAFE", "password": self.owner.password,
        }, instance=self.owner)
        self.assertFalse(form.is_valid())
        self.assertIn("role", form.errors)


@skipUnlessDBFeature("has_select_for_update")
class RefundConcurrencyTests(TransactionTestCase):
    def setUp(self):
        self.owner = User.objects.create_user(email="refund-owner@example.com", display_name="Owner")
        cafe = User.objects.create_user(email="refund-cafe@example.com", display_name="Café", role="CAFE")
        reward = Reward.objects.create(cafe_user=cafe, name="Coffee", point_cost=40)
        credit_points(user=self.owner, amount=100)
        self.order = create_redemption(owner=self.owner, reward_id=reward.pk)

    def run_concurrently(self, first, second):
        barrier = Barrier(2)

        def run(action):
            close_old_connections()
            try:
                barrier.wait(timeout=10)
                return action()
            finally:
                close_old_connections()

        with ThreadPoolExecutor(max_workers=2) as pool:
            futures = [pool.submit(run, action) for action in (first, second)]
            return [future.result(timeout=30) for future in futures]

    def collect(self):
        try:
            return collect_redemption(owner=self.owner, redemption_id=self.order.pk).status
        except RedemptionNotCollectibleError:
            return "NOT_COLLECTIBLE"

    def test_expiry_and_expired_collection_refund_only_once(self):
        Redemption.objects.filter(pk=self.order.pk).update(expires_at=timezone.now() - timedelta(seconds=1))
        self.run_concurrently(expire_redemptions, self.collect)
        self.order.refresh_from_db()
        self.assertEqual(self.order.status, Redemption.Status.EXPIRED)
        self.assertEqual(get_balance(self.owner), 100)
        self.assertEqual(PointEntry.objects.filter(type="REFUND").count(), 1)

    def test_cancel_racing_collection_has_one_consistent_terminal_state(self):
        self.run_concurrently(
            lambda: cancel_redemption(redemption_id=self.order.pk), self.collect
        )
        self.order.refresh_from_db()
        if self.order.status == Redemption.Status.COLLECTED:
            self.assertEqual(get_balance(self.owner), 60)
            self.assertFalse(PointEntry.objects.filter(type="REFUND").exists())
        else:
            self.assertEqual(self.order.status, Redemption.Status.CANCELLED)
            self.assertEqual(get_balance(self.owner), 100)
            self.assertEqual(PointEntry.objects.filter(type="REFUND").count(), 1)
