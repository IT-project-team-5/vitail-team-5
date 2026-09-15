"""Cross-feature regressions for the owner → wallet → café order MVP.

These requests use real login tokens, so they also catch API routing and role
integration errors that isolated model tests cannot detect.
"""

from concurrent.futures import ThreadPoolExecutor
from datetime import timedelta
from threading import Barrier
from uuid import uuid4

from django.contrib.auth import get_user_model
from django.db import close_old_connections, connection
from django.db.migrations.executor import MigrationExecutor
from django.test import TransactionTestCase, skipUnlessDBFeature
from django.utils import timezone
from rest_framework import status
from rest_framework.test import APIClient, APITestCase

from dogs.models import Breed, Dog
from rewards.models import PointEntry, Redemption, Reward
from rewards.services import credit_points


User = get_user_model()


class ConnectedRedemptionFlowTests(APITestCase):
    password = "ConnectedTest572!"
    orders_url = "/api/redemptions"
    feed_url = "/api/cafe/orders"

    @classmethod
    def setUpTestData(cls):
        cls.cafe = User.objects.create_user(
            email="connected-cafe@example.com",
            password=cls.password,
            display_name="Connected Café",
            role=User.Role.CAFE,
        )
        cls.other_cafe = User.objects.create_user(
            email="other-cafe@example.com",
            password=cls.password,
            display_name="Other Café",
            role=User.Role.CAFE,
        )
        cls.other_owner = User.objects.create_user(
            email="other-owner@example.com",
            password=cls.password,
            display_name="Other Owner",
            role=User.Role.OWNER,
        )
        cls.reward = Reward.objects.create(
            cafe_user=cls.cafe,
            name="Flat white",
            point_cost=40,
        )

    def setUp(self):
        registered = self.client.post(
            "/api/auth/register",
            {
                "email": "connected-owner@example.com",
                "password": self.password,
                "display_name": "Connected Owner",
            },
            format="json",
        )
        self.assertEqual(registered.status_code, status.HTTP_201_CREATED)
        self.assertEqual(registered.data["user"]["role"], User.Role.OWNER)
        self.owner = User.objects.get(pk=registered.data["user"]["id"])
        self.owner_client = self.login(self.owner)
        self.cafe_client = self.login(self.cafe)
        credit_points(
            user=self.owner,
            amount=100,
            source_reference=f"connected-test-grant:{self.owner.pk}",
        )

    def login(self, user):
        client = APIClient()
        response = client.post(
            "/api/auth/login",
            {"email": user.email, "password": self.password},
            format="json",
        )
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["user"]["role"], user.role)
        client.credentials(HTTP_AUTHORIZATION=f"Bearer {response.data['access']}")
        return client

    def create_order(self, *, reward=None, request_id=None):
        return self.owner_client.post(
            self.orders_url,
            {
                "reward_id": (reward or self.reward).pk,
                "request_id": str(request_id or uuid4()),
            },
            format="json",
        )

    def assert_balance(self, amount):
        response = self.owner_client.get("/api/wallet")
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["balance"], amount)

    def make_overdue(self, order_id):
        # Simulate a pending order crossing midnight without sleeping or
        # changing the system clock used to validate the login tokens.
        Redemption.objects.filter(pk=order_id).update(
            expires_at=timezone.now() - timedelta(seconds=1)
        )

    def test_owner_order_reaches_same_cafe_then_collect_removes_it(self):
        catalogue = self.owner_client.get("/api/redemptions/rewards")
        self.assertEqual(catalogue.status_code, status.HTTP_200_OK)
        self.assertIn(self.reward.pk, [item["id"] for item in catalogue.data])
        initial_feed = self.cafe_client.get(self.feed_url)
        self.assertEqual(initial_feed.status_code, status.HTTP_200_OK)
        self.assertEqual(initial_feed.data["upserts"], [])

        created = self.create_order()
        self.assertEqual(created.status_code, status.HTTP_201_CREATED)
        order_id = created.data["id"]
        self.assertEqual(created.data["status"], Redemption.Status.PENDING)
        self.assertEqual(Redemption.objects.get(pk=order_id).owner_user, self.owner)
        self.assert_balance(60)

        feed = self.cafe_client.get(
            self.feed_url, {"since": initial_feed.data["cursor"]}
        )
        self.assertEqual(feed.status_code, status.HTTP_200_OK)
        self.assertEqual([item["id"] for item in feed.data["upserts"]], [order_id])
        cafe_order = feed.data["upserts"][0]
        self.assertEqual(cafe_order["reference_number"], created.data["reference_number"])
        self.assertEqual(cafe_order["owner_name"], "Connected Owner")
        self.assertEqual(cafe_order["items"], [{"name": "Flat white", "quantity": 1}])
        self.assertEqual(feed.data["removed_ids"], [])
        self.assertFalse(feed.data["reset"])
        self.assertEqual(feed["X-Cafe-Orders-Cursor"], str(feed.data["cursor"]))

        unchanged = self.cafe_client.get(self.feed_url, {"since": feed.data["cursor"]})
        self.assertEqual(unchanged.status_code, status.HTTP_304_NOT_MODIFIED)
        self.assertEqual(unchanged.content, b"")

        collect_url = f"{self.orders_url}/{order_id}/collect"
        collected = self.owner_client.post(collect_url)
        repeated = self.owner_client.post(collect_url)
        self.assertEqual(collected.status_code, status.HTTP_200_OK)
        self.assertEqual(repeated.status_code, status.HTTP_200_OK)
        self.assertEqual(collected.data["status"], Redemption.Status.COLLECTED)
        self.assertEqual(repeated.data["collected_at"], collected.data["collected_at"])
        self.assert_balance(60)
        self.assertEqual(PointEntry.objects.filter(type=PointEntry.Type.SPEND).count(), 1)

        removed = self.cafe_client.get(self.feed_url, {"since": feed.data["cursor"]})
        self.assertEqual(removed.status_code, status.HTTP_200_OK)
        self.assertEqual(removed.data["upserts"], [])
        self.assertEqual(removed.data["removed_ids"], [order_id])
        self.assertEqual(
            self.cafe_client.get(self.feed_url, {"since": removed.data["cursor"]}).status_code,
            status.HTTP_304_NOT_MODIFIED,
        )
        history = self.owner_client.get(self.orders_url)
        self.assertEqual(history.status_code, status.HTTP_200_OK)
        self.assertEqual([item["id"] for item in history.data], [order_id])
        self.assertEqual(history.data[0]["status"], Redemption.Status.COLLECTED)

    def test_cafe_poll_expires_order_removes_it_and_refunds_only_once(self):
        created = self.create_order()
        self.assertEqual(created.status_code, status.HTTP_201_CREATED)
        order_id = created.data["id"]
        feed = self.cafe_client.get(self.feed_url)
        self.make_overdue(order_id)

        expired_feed = self.cafe_client.get(self.feed_url, {"since": feed.data["cursor"]})
        self.assertEqual(expired_feed.status_code, status.HTTP_200_OK)
        self.assertEqual(expired_feed.data["upserts"], [])
        self.assertEqual(expired_feed.data["removed_ids"], [order_id])
        self.assert_balance(100)

        for _ in range(2):
            refused = self.owner_client.post(f"{self.orders_url}/{order_id}/collect")
            self.assertEqual(refused.status_code, status.HTTP_409_CONFLICT)
            self.owner_client.get(self.orders_url)
            self.assert_balance(100)
            unchanged = self.cafe_client.get(
                self.feed_url, {"since": expired_feed.data["cursor"]}
            )
            self.assertEqual(unchanged.status_code, status.HTTP_304_NOT_MODIFIED)

        order = Redemption.objects.get(pk=order_id)
        self.assertEqual(order.status, Redemption.Status.EXPIRED)
        self.assertIsNone(order.collected_at)
        refunds = PointEntry.objects.filter(user=self.owner, type=PointEntry.Type.REFUND)
        self.assertEqual(list(refunds.values_list("amount", flat=True)), [40])

    def test_expired_collect_commits_refund_even_when_response_is_conflict(self):
        created = self.create_order()
        self.assertEqual(created.status_code, status.HTTP_201_CREATED)
        order_id = created.data["id"]
        self.make_overdue(order_id)

        refused = self.owner_client.post(f"{self.orders_url}/{order_id}/collect")

        self.assertEqual(refused.status_code, status.HTTP_409_CONFLICT)
        self.assertEqual(Redemption.objects.get(pk=order_id).status, Redemption.Status.EXPIRED)
        # Check persisted refund before another GET can run expiry cleanup.
        refunds = PointEntry.objects.filter(user=self.owner, type=PointEntry.Type.REFUND)
        self.assertEqual(list(refunds.values_list("amount", flat=True)), [40])
        self.assert_balance(100)

    def test_order_retry_is_idempotent_but_cannot_change_reward(self):
        request_id = uuid4()
        first = self.create_order(request_id=request_id)
        repeated = self.create_order(request_id=request_id)
        self.assertEqual(first.status_code, status.HTTP_201_CREATED)
        self.assertEqual(repeated.status_code, status.HTTP_201_CREATED)
        self.assertEqual(repeated.data["id"], first.data["id"])
        self.assertEqual(Redemption.objects.count(), 1)
        self.assertEqual(PointEntry.objects.filter(type=PointEntry.Type.SPEND).count(), 1)
        self.assert_balance(60)

        another_reward = Reward.objects.create(
            cafe_user=self.cafe, name="Tea", point_cost=20
        )
        conflict = self.create_order(reward=another_reward, request_id=request_id)
        self.assertEqual(conflict.status_code, status.HTTP_409_CONFLICT)
        self.assertEqual(Redemption.objects.count(), 1)
        self.assert_balance(60)
        self.assertEqual(len(self.cafe_client.get(self.feed_url).data["upserts"]), 1)

    def test_insufficient_points_never_creates_a_cafe_order_or_debit(self):
        expensive = Reward.objects.create(
            cafe_user=self.cafe, name="Too expensive", point_cost=101
        )
        before = self.cafe_client.get(self.feed_url)

        rejected = self.create_order(reward=expensive)

        self.assertEqual(rejected.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(rejected.data["code"], "INSUFFICIENT_POINTS")
        self.assertEqual(Redemption.objects.count(), 0)
        self.assertFalse(PointEntry.objects.filter(type=PointEntry.Type.SPEND).exists())
        self.assert_balance(100)
        self.assertEqual(
            self.cafe_client.get(self.feed_url, {"since": before.data["cursor"]}).status_code,
            status.HTTP_304_NOT_MODIFIED,
        )

    def test_order_is_private_to_its_owner_and_cafe_feed_is_read_only(self):
        created = self.create_order()
        self.assertEqual(created.status_code, status.HTTP_201_CREATED)
        order_id = created.data["id"]
        other_owner_client = self.login(self.other_owner)
        other_cafe_client = self.login(self.other_cafe)

        other_history = other_owner_client.get(self.orders_url)
        self.assertEqual(other_history.status_code, status.HTTP_200_OK)
        self.assertEqual(other_history.data, [])
        other_ledger = other_owner_client.get("/api/wallet/ledger")
        self.assertEqual(other_ledger.status_code, status.HTTP_200_OK)
        self.assertEqual(other_ledger.data, [])
        self.assertEqual(
            other_owner_client.post(f"{self.orders_url}/{order_id}/collect").status_code,
            status.HTTP_404_NOT_FOUND,
        )
        other_feed = other_cafe_client.get(self.feed_url)
        self.assertEqual(other_feed.status_code, status.HTTP_200_OK)
        self.assertEqual(other_feed.data["upserts"], [])
        self.assertEqual(
            self.owner_client.get(self.feed_url).status_code, status.HTTP_403_FORBIDDEN
        )
        self.assertEqual(
            self.cafe_client.post(f"{self.orders_url}/{order_id}/collect").status_code,
            status.HTTP_403_FORBIDDEN,
        )
        self.assertEqual(
            self.cafe_client.post(self.feed_url, {"order_id": order_id}).status_code,
            status.HTTP_405_METHOD_NOT_ALLOWED,
        )
        self.assertEqual(Redemption.objects.get(pk=order_id).status, Redemption.Status.PENDING)

    def test_existing_profile_and_dog_crud_survive_redemption_integration(self):
        breed = Breed.objects.create(
            name="Connected Test Terrier",
            energy_level=Breed.EnergyLevel.MODERATE,
            default_size=Breed.Size.SMALL,
        )
        dog_response = self.owner_client.post(
            "/api/dogs",
            {
                "name": "Milo",
                "breed_id": breed.pk,
                "age_months": 0,
                "size": Dog.Size.SMALL,
                "is_brachycephalic": False,
            },
            format="json",
        )
        self.assertEqual(dog_response.status_code, status.HTTP_201_CREATED)
        dog_id = dog_response.data["id"]
        created = self.create_order()
        self.assertEqual(created.status_code, status.HTTP_201_CREATED)

        profile = self.owner_client.patch(
            "/api/auth/me", {"display_name": "Renamed Owner"}, format="json"
        )
        self.assertEqual(profile.status_code, status.HTTP_200_OK)
        self.assertEqual(profile.data["display_name"], "Renamed Owner")
        renamed_dog = self.owner_client.patch(
            f"/api/dogs/{dog_id}", {"name": "New Milo"}, format="json"
        )
        self.assertEqual(renamed_dog.status_code, status.HTTP_200_OK)
        dogs = self.owner_client.get("/api/dogs")
        self.assertEqual(dogs.status_code, status.HTTP_200_OK)
        self.assertEqual(dogs.data[0]["name"], "New Milo")
        self.assertEqual(dogs.data[0]["age_months"], 0)
        self.assert_balance(60)

        # Order-time customer/item data must not change with profile/catalog edits.
        self.reward.name = "Renamed coffee"
        self.reward.point_cost = 50
        self.reward.cafe_user = self.other_cafe
        self.reward.save(update_fields=["name", "point_cost", "cafe_user"])
        feed = self.cafe_client.get(self.feed_url)
        self.assertEqual(feed.data["upserts"][0]["owner_name"], "Connected Owner")
        self.assertEqual(feed.data["upserts"][0]["items"], [{"name": "Flat white", "quantity": 1}])
        self.assertEqual(self.login(self.other_cafe).get(self.feed_url).data["upserts"], [])
        self.assertEqual(
            self.owner_client.delete(f"/api/dogs/{dog_id}").status_code,
            status.HTTP_204_NO_CONTENT,
        )
        self.assertFalse(Dog.objects.filter(pk=dog_id).exists())
        self.assertEqual(Redemption.objects.count(), 1)

    def test_new_routes_require_authentication_without_redirects(self):
        public = APIClient()
        for path in (
            "/api/wallet",
            "/api/wallet/ledger",
            "/api/redemptions/rewards",
            self.orders_url,
            self.feed_url,
        ):
            for suffix in ("", "/"):
                with self.subTest(path=path + suffix):
                    self.assertEqual(
                        public.get(path + suffix).status_code,
                        status.HTTP_401_UNAUTHORIZED,
                    )


class ConnectedRewardsMigrationTests(TransactionTestCase):
    def test_upgrade_preserves_existing_points_and_orders_and_backfills_cafe_feed(self):
        executor = MigrationExecutor(connection)
        latest_targets = executor.loader.graph.leaf_nodes()
        old_target = [("rewards", "0001_initial")]
        rewards_target = executor.loader.graph.leaf_nodes("rewards")
        self.assertNotEqual(rewards_target, old_target)

        try:
            executor.migrate(old_target)
            old_apps = executor.loader.project_state(old_target).apps
            OldUser = old_apps.get_model("accounts", "User")
            OldReward = old_apps.get_model("rewards", "Reward")
            OldRedemption = old_apps.get_model("rewards", "Redemption")
            OldPointEntry = old_apps.get_model("rewards", "PointEntry")
            owner = OldUser.objects.create(
                email="legacy-owner@example.com", display_name="Legacy Owner", role="OWNER"
            )
            cafe = OldUser.objects.create(
                email="legacy-cafe@example.com", display_name="Legacy Café", role="CAFE"
            )
            reward = OldReward.objects.create(
                cafe_user_id=cafe.pk, name="Legacy Coffee", point_cost=40
            )
            credit = OldPointEntry.objects.create(
                user_id=owner.pk,
                amount=100,
                remaining_points=60,
                type="ADMIN",
                source_reference="legacy-grant",
                expires_at=timezone.now() + timedelta(days=300),
            )
            order = OldRedemption.objects.create(
                owner_user_id=owner.pk,
                reward_id=reward.pk,
                reference_number="RDM-LEGACY000001",
                reward_name_snapshot="Original Coffee",
                point_cost_snapshot=40,
                expires_at=timezone.now() + timedelta(hours=3),
            )
            spend = OldPointEntry.objects.create(
                user_id=owner.pk,
                amount=-40,
                remaining_points=0,
                type="SPEND",
                source_reference=f"redemption:{order.reference_number}",
            )

            MigrationExecutor(connection).migrate(rewards_target)

            upgraded = Redemption.objects.get(pk=order.pk)
            self.assertEqual(upgraded.owner_user_id, owner.pk)
            self.assertEqual(upgraded.reward_id, reward.pk)
            self.assertEqual(upgraded.reference_number, "RDM-LEGACY000001")
            self.assertEqual(upgraded.reward_name_snapshot, "Original Coffee")
            self.assertEqual(upgraded.point_cost_snapshot, 40)
            self.assertEqual(upgraded.status, Redemption.Status.PENDING)
            self.assertEqual(upgraded.cafe_user_id, cafe.pk)
            self.assertEqual(upgraded.owner_name_snapshot, "Legacy Owner")
            self.assertEqual(upgraded.cafe_name_snapshot, "Legacy Café")
            self.assertIsNone(upgraded.request_id)
            self.assertGreater(upgraded.feed_cursor, 0)
            upgraded_credit = PointEntry.objects.get(pk=credit.pk)
            self.assertEqual(upgraded_credit.amount, 100)
            self.assertEqual(upgraded_credit.remaining_points, 60)
            self.assertEqual(upgraded_credit.source_reference, "legacy-grant")
            self.assertEqual(PointEntry.objects.get(pk=spend.pk).amount, -40)
            self.assertEqual(PointEntry.objects.filter(user_id=owner.pk).count(), 2)

            client = APIClient()
            client.force_authenticate(User.objects.get(pk=cafe.pk))
            feed = client.get("/api/cafe/orders")
            self.assertEqual(feed.status_code, status.HTTP_200_OK)
            self.assertEqual([item["id"] for item in feed.data["upserts"]], [order.pk])
            self.assertEqual(feed.data["upserts"][0]["reference_number"], order.reference_number)
            self.assertEqual(
                feed.data["upserts"][0]["items"], [{"name": "Original Coffee", "quantity": 1}]
            )
            client.force_authenticate(User.objects.get(pk=owner.pk))
            wallet = client.get("/api/wallet")
            self.assertEqual(wallet.status_code, status.HTTP_200_OK)
            self.assertEqual(wallet.data["balance"], 60)
        finally:
            # Always restore the full schema before TransactionTestCase flushes
            # it, including when a migration assertion fails.
            MigrationExecutor(connection).migrate(latest_targets)


@skipUnlessDBFeature("has_select_for_update")
class ConnectedRedemptionConcurrencyTests(TransactionTestCase):
    """Exercise real row locking on MySQL; SQLite cannot prove these cases."""

    def setUp(self):
        password = "ConcurrentTest572!"
        self.owner = User.objects.create_user(
            email="concurrent-owner@example.com",
            password=password,
            display_name="Concurrent Owner",
        )
        cafe = User.objects.create_user(
            email="concurrent-cafe@example.com",
            password=password,
            display_name="Concurrent Café",
            role=User.Role.CAFE,
        )
        self.reward = Reward.objects.create(cafe_user=cafe, name="Coffee", point_cost=40)
        credit_points(user=self.owner, amount=40)
        login = APIClient().post(
            "/api/auth/login",
            {"email": self.owner.email, "password": password},
            format="json",
        )
        self.assertEqual(login.status_code, status.HTTP_200_OK)
        self.access = login.data["access"]

    def concurrent_orders(self, request_ids):
        barrier = Barrier(2)

        def post_order(request_id):
            close_old_connections()
            try:
                client = APIClient()
                client.credentials(HTTP_AUTHORIZATION=f"Bearer {self.access}")
                barrier.wait(timeout=10)
                response = client.post(
                    "/api/redemptions",
                    {"reward_id": self.reward.pk, "request_id": str(request_id)},
                    format="json",
                )
                return response.status_code, response.data
            finally:
                close_old_connections()

        with ThreadPoolExecutor(max_workers=2) as pool:
            futures = [pool.submit(post_order, request_id) for request_id in request_ids]
            return [future.result(timeout=30) for future in futures]

    def assert_one_spend(self):
        self.assertEqual(Redemption.objects.filter(owner_user=self.owner).count(), 1)
        spends = PointEntry.objects.filter(user=self.owner, type=PointEntry.Type.SPEND)
        self.assertEqual(list(spends.values_list("amount", flat=True)), [-40])
        client = APIClient()
        client.credentials(HTTP_AUTHORIZATION=f"Bearer {self.access}")
        wallet = client.get("/api/wallet")
        self.assertEqual(wallet.status_code, status.HTTP_200_OK)
        self.assertEqual(wallet.data["balance"], 0)

    def test_concurrent_orders_cannot_spend_the_same_balance_twice(self):
        responses = self.concurrent_orders([uuid4(), uuid4()])

        self.assertEqual(
            sorted(code for code, _ in responses),
            [status.HTTP_201_CREATED, status.HTTP_400_BAD_REQUEST],
        )
        rejected = next(data for code, data in responses if code == status.HTTP_400_BAD_REQUEST)
        self.assertEqual(rejected["code"], "INSUFFICIENT_POINTS")
        self.assert_one_spend()

    def test_concurrent_retries_create_one_order_and_one_spend(self):
        request_id = uuid4()
        responses = self.concurrent_orders([request_id, request_id])

        self.assertEqual([code for code, _ in responses], [201, 201])
        self.assertEqual(responses[0][1]["id"], responses[1][1]["id"])
        self.assert_one_spend()
