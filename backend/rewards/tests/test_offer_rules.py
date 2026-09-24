from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone as datetime_timezone
from threading import Barrier
from unittest.mock import patch
from uuid import uuid4

from django.db import close_old_connections, IntegrityError, transaction
from django.test import TestCase, TransactionTestCase, override_settings, skipUnlessDBFeature
from django.utils import timezone
from rest_framework.test import APIClient

from accounts.models import User
from rewards.catalogue import available_rewards, purchase_fingerprint
from rewards.models import PointEntry, Redemption, Reward
from rewards.services import (
    IdempotencyConflictError, RewardUnavailableError, cancel_redemption, collect_redemption,
    create_redemption, credit_points, expire_redemptions, get_balance,
)
from venues.services import venue_for


class OfferRuleTests(TestCase):
    @classmethod
    def setUpTestData(cls):
        cls.cafe = User.objects.create_user(email="offer-cafe@example.com", display_name="Café", role="CAFE")
        cls.owner = User.objects.create_user(email="offer-owner@example.com", display_name="Owner")
        cls.other = User.objects.create_user(email="offer-other@example.com", display_name="Other owner")
        cls.reward = Reward.objects.create(venue=venue_for(cls.cafe), name="Coffee", point_cost=60)

    def setUp(self):
        self.client = APIClient()
        self.client.force_authenticate(self.cafe)
        for owner in (self.owner, self.other):
            credit_points(user=owner, amount=1000)

    def test_cafe_can_manage_optional_offer_rules_and_invalid_partial_windows_are_atomic(self):
        now = timezone.now()
        url = f"/api/cafe/products/{self.reward.pk}"
        response = self.client.patch(url, {"starts_at": now.isoformat(), "ends_at": (now + timedelta(hours=2)).isoformat(),
            "daily_quantity_limit": 3, "terms": "One coffee with a food purchase.", "requires_store_purchase": True}, format="json")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.data["daily_quantity_limit"], 3)
        self.assertTrue(response.data["requires_store_purchase"])
        self.assertEqual(response.data["terms"], "One coffee with a food purchase.")
        for data in ({"ends_at": now.isoformat()}, {"starts_at": (now + timedelta(days=1)).isoformat()},
                     {"daily_quantity_limit": 0}, {"daily_quantity_limit": -1}, {"daily_quantity_limit": True},
                     {"daily_quantity_limit": 1.5}, {"terms": "x" * 2001}):
            with self.subTest(data=data):
                self.assertEqual(self.client.patch(url, data, format="json").status_code, 400)
        self.reward.refresh_from_db()
        self.assertEqual(self.reward.daily_quantity_limit, 3)
        self.assertEqual(self.reward.ends_at, now + timedelta(hours=2))
        cleared = self.client.patch(url, {"starts_at": None, "ends_at": None, "daily_quantity_limit": None, "terms": "", "requires_store_purchase": False}, format="json")
        self.assertEqual(cleared.status_code, 200)
        self.assertIsNone(cleared.data["daily_quantity_limit"])
        self.assertEqual(cleared.data["terms"], "")

    def test_database_rejects_nonpositive_daily_limit_and_invalid_window(self):
        now = timezone.now()
        for updates in ({"daily_quantity_limit": 0}, {"starts_at": now, "ends_at": now}, {"starts_at": now, "ends_at": now - timedelta(seconds=1)}):
            with self.subTest(updates=updates), self.assertRaises(IntegrityError), transaction.atomic():
                Reward.objects.filter(pk=self.reward.pk).update(**updates)

    def test_sale_window_is_consistent_in_catalogue_and_purchase(self):
        now = timezone.now()
        self.client.force_authenticate(self.owner)
        for updates in ({"starts_at": now + timedelta(days=1)}, {"starts_at": None, "ends_at": now - timedelta(seconds=1)}):
            Reward.objects.filter(pk=self.reward.pk).update(**updates)
            self.assertEqual(self.client.get("/api/redemptions/rewards").data, [])
            self.assertEqual(self.client.post("/api/redemptions", {"reward_id": self.reward.pk}, format="json").data["code"], "REWARD_UNAVAILABLE")
        self.assertFalse(Redemption.objects.exists())
        Reward.objects.filter(pk=self.reward.pk).update(starts_at=now, ends_at=now + timedelta(hours=1))
        self.assertTrue(available_rewards(now=now).filter(pk=self.reward.pk).exists())
        self.assertFalse(available_rewards(now=now + timedelta(hours=1)).filter(pk=self.reward.pk).exists())

    def test_sale_that_closes_while_waiting_for_product_lock_does_not_charge(self):
        now = timezone.now()
        closes = now + timedelta(seconds=1)
        Reward.objects.filter(pk=self.reward.pk).update(ends_at=closes)
        with patch("django.utils.timezone.now", side_effect=[now, closes]):
            with self.assertRaises(RewardUnavailableError):
                create_redemption(owner=self.owner, reward_id=self.reward.pk)
        self.assertFalse(Redemption.objects.exists())
        self.assertEqual(get_balance(self.owner), 1000)

    def test_daily_quantity_reserves_pending_and_collected_orders_and_releases_cancellation(self):
        Reward.objects.filter(pk=self.reward.pk).update(daily_quantity_limit=1)
        first = create_redemption(owner=self.owner, reward_id=self.reward.pk)
        self.assertFalse(available_rewards().exists())
        with self.assertRaises(RewardUnavailableError):
            create_redemption(owner=self.other, reward_id=self.reward.pk)
        self.assertEqual(get_balance(self.other), 1000)
        self.assertTrue(cancel_redemption(redemption_id=first.pk))
        self.assertTrue(available_rewards().exists())
        second = create_redemption(owner=self.other, reward_id=self.reward.pk)
        collect_redemption(owner=self.other, redemption_id=second.pk)
        self.assertFalse(available_rewards().exists())
        with self.assertRaises(RewardUnavailableError):
            create_redemption(owner=self.owner, reward_id=self.reward.pk)

    def test_expired_pending_reservation_does_not_block_catalogue_or_next_customer(self):
        Reward.objects.filter(pk=self.reward.pk).update(daily_quantity_limit=1)
        order = create_redemption(owner=self.owner, reward_id=self.reward.pk)
        Redemption.objects.filter(pk=order.pk).update(expires_at=timezone.now() - timedelta(seconds=1))
        self.assertTrue(available_rewards().exists())
        next_order = create_redemption(owner=self.other, reward_id=self.reward.pk)
        self.assertEqual(next_order.point_cost_snapshot, 60)
        expire_redemptions(owner=self.owner)
        order.refresh_from_db()
        self.assertEqual(order.refund_entry.amount, 60)
        self.assertEqual(get_balance(self.owner), 1000)

    def test_request_replay_preserves_terms_and_debit_after_product_changes(self):
        Reward.objects.filter(pk=self.reward.pk).update(terms="Original conditions", requires_store_purchase=True)
        request_id = uuid4()
        order = create_redemption(owner=self.owner, reward_id=self.reward.pk, request_id=request_id)
        self.assertEqual(order.request_fingerprint, purchase_fingerprint(self.reward.pk))
        self.assertEqual(order.terms_snapshot, "Original conditions")
        self.assertEqual(order.eligibility_snapshot, {})
        self.assertEqual((order.spend_entry.type, order.spend_entry.user_id, order.spend_entry.amount), ("SPEND", self.owner.pk, -60))
        Reward.objects.filter(pk=self.reward.pk).update(terms="New conditions", is_available=False, point_cost=90)
        retry = create_redemption(owner=self.owner, reward_id=self.reward.pk, request_id=request_id)
        self.assertEqual((retry.pk, retry.terms_snapshot, retry.point_cost_snapshot, retry.spend_entry_id), (order.pk, "Original conditions", 60, order.spend_entry_id))
        with self.assertRaises(IdempotencyConflictError):
            create_redemption(owner=self.owner, reward_id=self.reward.pk + 1, request_id=request_id)
        self.assertEqual(PointEntry.objects.filter(type="SPEND").count(), 1)
        cancel_redemption(redemption_id=order.pk)
        cancel_redemption(redemption_id=order.pk)
        order.refresh_from_db()
        self.assertEqual((order.refund_entry.type, order.refund_entry.amount, order.refund_entry.user_id), ("REFUND", 60, self.owner.pk))
        self.assertEqual(PointEntry.objects.filter(type="REFUND").count(), 1)

    @override_settings(TIME_ZONE="UTC")
    def test_daily_limit_and_order_date_use_melbourne_across_midnight(self):
        # Dates are intentionally independent of the server's configured zone.
        before = datetime(2026, 9, 24, 13, 55, tzinfo=datetime_timezone.utc)
        after = before + timedelta(minutes=10)
        Reward.objects.filter(pk=self.reward.pk).update(daily_quantity_limit=1)
        with patch("django.utils.timezone.now", return_value=before):
            # Test grants must be valid at the fixed historical instant.
            PointEntry.objects.filter(user__in=[self.owner, self.other]).update(expires_at=after + timedelta(days=1))
            first = create_redemption(owner=self.owner, reward_id=self.reward.pk)
            collect_redemption(owner=self.owner, redemption_id=first.pk)
            self.assertEqual(first.order_date.isoformat(), "2026-09-24")
        with patch("django.utils.timezone.now", return_value=after):
            self.assertTrue(available_rewards().exists())
            second = create_redemption(owner=self.other, reward_id=self.reward.pk)
            self.assertEqual(second.order_date.isoformat(), "2026-09-25")


@skipUnlessDBFeature("has_select_for_update")
class DailyOfferConcurrencyTests(TransactionTestCase):
    def test_two_owners_cannot_purchase_the_last_daily_item_twice(self):
        cafe = User.objects.create_user(email="quota-cafe@example.com", display_name="Café", role="CAFE")
        reward = Reward.objects.create(venue=venue_for(cafe), name="Last coffee", point_cost=60, daily_quantity_limit=1)
        owners = [User.objects.create_user(email=f"quota-owner-{i}@example.com", display_name=f"Owner {i}") for i in range(2)]
        for owner in owners:
            credit_points(user=owner, amount=100)
        barrier = Barrier(2)

        def buy(owner):
            close_old_connections()
            try:
                barrier.wait(timeout=10)
                try:
                    return create_redemption(owner=owner, reward_id=reward.pk, request_id=uuid4()).pk
                except RewardUnavailableError:
                    return None
            finally:
                close_old_connections()

        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(buy, owners, timeout=30))
        self.assertEqual(sum(result is not None for result in results), 1)
        self.assertEqual(Redemption.objects.count(), 1)
        self.assertEqual(PointEntry.objects.filter(type="SPEND").count(), 1)
        self.assertEqual(sorted(get_balance(owner) for owner in owners), [40, 100])
