from concurrent.futures import ThreadPoolExecutor
from threading import Barrier
from io import StringIO
from unittest.mock import patch
from uuid import uuid4

from django.core.management import call_command
from django.core.management.base import CommandError
from django.db import close_old_connections
from django.test import TestCase, TransactionTestCase, override_settings, skipUnlessDBFeature
from rest_framework.test import APIClient

from accounts.models import User
from dogs.models import Breed, Dog
from quests.models import QuestDefinition
from rewards.catalogue import DEMO_REWARD_EMAIL
from rewards.models import PointEntry, Redemption, Reward
from rewards.services import create_redemption, credit_points, get_balance


@override_settings(DEBUG=True)
class DemoRedemptionEligibilityTests(TestCase):
    def setUp(self):
        self.configure()
        self.reward = Reward.objects.get(venue__manager_user__email=DEMO_REWARD_EMAIL)
        self.owner = User.objects.create_user(email="eligibility@vitail.test", display_name="Owner")
        breed = Breed.objects.create(name="Test breed", energy_level="LOW", default_size="SMALL")
        self.dog = Dog.objects.create(owner=self.owner, breed=breed, name="Milo", age_months=12,
                                      size="SMALL", is_brachycephalic=False)
        self.client = APIClient()
        self.client.force_authenticate(self.owner)

    def configure(self, state="available", **kwargs):
        call_command("demo_reward", state=state, stdout=StringIO(), **kwargs)

    def register(self):
        response = self.client.post("/api/quests/documents", {
            "request_id": str(uuid4()), "dog_id": self.dog.pk,
            "kind": "MICROCHIP_REGISTRATION", "registration_number": "012345678901234",
        }, format="json")
        self.assertEqual(response.status_code, 201, response.data)

    def purchase(self, request_id=None):
        return self.client.post("/api/redemptions/", {
            "reward_id": self.reward.pk, "request_id": str(request_id or uuid4()),
        }, format="json")

    def assert_uncharged(self, balance):
        self.assertEqual(get_balance(self.owner), balance)
        self.assertFalse(Redemption.objects.exists())
        self.assertFalse(PointEntry.objects.filter(type="SPEND").exists())

    def test_incomplete_registration_blocks_even_with_enough_points(self):
        credit_points(user=self.owner, amount=10)
        response = self.purchase()
        self.assertEqual(response.status_code, 403)
        self.assertEqual(response.data["code"], "MICROCHIP_REGISTRATION_REQUIRED")
        self.assertEqual(response.data["incomplete_dogs"], [{"id": self.dog.pk, "name": "Milo"}])
        self.assert_uncharged(10)

    def test_second_unregistered_dog_also_blocks(self):
        self.register()
        Dog.objects.create(owner=self.owner, breed=self.dog.breed, name="Pip", age_months=12,
                           size="SMALL", is_brachycephalic=False)
        credit_points(user=self.owner, amount=10)
        self.assertEqual(self.purchase().status_code, 403)
        self.assert_uncharged(10)

    def test_no_current_reward_blocks_and_catalogue_is_empty(self):
        self.register()
        credit_points(user=self.owner, amount=10)
        self.configure("unavailable", exclusive=True)
        self.assertEqual(self.client.get("/api/redemptions/rewards").data, [])
        response = self.purchase()
        self.assertEqual(response.data["code"], "REWARD_UNAVAILABLE")
        self.assert_uncharged(10)
        self.configure()
        self.assertEqual(len(self.client.get("/api/redemptions/rewards").data), 1)

    def test_zero_and_below_five_points_block_without_partial_records(self):
        self.register()
        for balance in (0, 4):
            if balance:
                credit_points(user=self.owner, amount=balance)
            response = self.purchase()
            self.assertEqual(response.data["code"], "INSUFFICIENT_POINTS")
            self.assert_uncharged(balance)

    def test_exactly_five_points_creates_one_order_and_deducts_five(self):
        self.register()
        credit_points(user=self.owner, amount=5)
        self.assertEqual(self.purchase().status_code, 201)
        self.assertEqual(get_balance(self.owner), 0)
        order = Redemption.objects.get()
        self.assertEqual(order.point_cost_snapshot, 5)
        self.assertEqual(order.spend_entry.amount, -5)
        self.assertIn("DUMMY", order.reward_name_snapshot)
        self.assertIn("no real redemption value", order.terms_snapshot)

    def test_above_five_and_repeated_request_only_charge_once(self):
        self.register()
        credit_points(user=self.owner, amount=12)
        key = uuid4()
        first = self.purchase(key)
        self.assertEqual(first.status_code, 201)
        # Replay must recover the receipt even if the reward was subsequently hidden.
        self.configure("unavailable")
        for _ in range(3):
            self.assertEqual(self.purchase(key).data["id"], first.data["id"])
        self.assertEqual(get_balance(self.owner), 7)
        self.assertEqual(Redemption.objects.count(), 1)
        self.assertEqual(PointEntry.objects.filter(type="SPEND").count(), 1)

    def test_failure_after_debit_rolls_back_and_same_request_can_retry(self):
        self.register()
        credit_points(user=self.owner, amount=5)
        key = uuid4()
        with patch("rewards.services._publish_order", side_effect=RuntimeError("Simulated failure")):
            with self.assertRaises(RuntimeError):
                create_redemption(owner=self.owner, reward_id=self.reward.pk, request_id=key)
        self.assert_uncharged(5)
        self.assertEqual(self.purchase(key).status_code, 201)
        self.assertEqual(get_balance(self.owner), 0)

    def test_demo_command_is_idempotent_and_does_not_grant_points(self):
        self.configure()
        self.configure()
        self.assertEqual(Reward.objects.count(), 1)
        self.assertEqual(self.reward.point_cost, 5)
        self.assertFalse(PointEntry.objects.exists())
        self.assertFalse(self.reward.venue.manager_user.has_usable_password())

    @override_settings(DEBUG=False)
    def test_production_cannot_seed_list_or_purchase_dummy_reward(self):
        with self.assertRaises(CommandError):
            self.configure()
        self.register()
        credit_points(user=self.owner, amount=5)
        self.assertEqual(self.client.get("/api/redemptions/rewards").data, [])
        self.assertEqual(self.purchase().data["code"], "REWARD_UNAVAILABLE")
        self.assert_uncharged(5)


# SQLite cannot prove row-lock behavior; these run against isolated MySQL.


@override_settings(DEBUG=True)
@skipUnlessDBFeature("has_select_for_update")
class FivePointConcurrencyTests(TransactionTestCase):
    def test_simultaneous_same_request_charges_once(self):
        key = uuid4()
        self.check_purchases([key, key], [201, 201])

    def test_simultaneous_different_requests_cannot_overdraw(self):
        self.check_purchases([uuid4(), uuid4()], [201, 400])

    def check_purchases(self, keys, expected):
        QuestDefinition.objects.update_or_create(code="DOCUMENTS", defaults={"title": "Documents", "is_enabled": True})
        call_command("demo_reward", stdout=StringIO())
        reward = Reward.objects.get(venue__manager_user__email=DEMO_REWARD_EMAIL)
        owner = User.objects.create_user(email="concurrent-demo@vitail.test", display_name="Owner")
        breed = Breed.objects.create(name="Test breed", energy_level="LOW", default_size="SMALL")
        dog = Dog.objects.create(owner=owner, breed=breed, name="Milo", age_months=12,
                                 size="SMALL", is_brachycephalic=False)
        client = APIClient()
        client.force_authenticate(owner)
        registered = client.post("/api/quests/documents", {
            "request_id": str(uuid4()), "dog_id": dog.pk,
            "kind": "MICROCHIP_REGISTRATION", "registration_number": "012345678901234",
        }, format="json")
        self.assertEqual(registered.status_code, 201)
        credit_points(user=owner, amount=5)
        barrier = Barrier(2)

        def buy(key):
            close_old_connections()
            try:
                client = APIClient()
                client.force_authenticate(owner)
                barrier.wait(timeout=10)
                return client.post("/api/redemptions/", {
                    "reward_id": reward.pk, "request_id": str(key),
                }, format="json").status_code
            finally:
                close_old_connections()

        with ThreadPoolExecutor(max_workers=2) as pool:
            codes = list(pool.map(buy, keys, timeout=30))
        self.assertEqual(sorted(codes), expected)
        self.assertEqual(get_balance(owner), 0)
        self.assertEqual(Redemption.objects.count(), 1)
        self.assertEqual(list(PointEntry.objects.filter(type="SPEND").values_list("amount", flat=True)), [-5])
