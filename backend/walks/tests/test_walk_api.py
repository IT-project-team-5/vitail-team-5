import copy
import math
from datetime import datetime, timedelta
from unittest.mock import patch
from uuid import uuid4
from zoneinfo import ZoneInfo

from django.contrib.auth import get_user_model
from rest_framework import status
from rest_framework.test import APIClient, APITestCase

from dogs.models import Breed, Dog
from rewards.models import PointEntry, Redemption, Reward
from walks.models import Walk


User = get_user_model()


class WalkApiTests(APITestCase):
    url = "/api/walks"

    @classmethod
    def setUpTestData(cls):
        cls.owner = User.objects.create_user(
            email="walker@example.com", password="WalkingTest572!", display_name="Walker"
        )
        cls.other_owner = User.objects.create_user(
            email="other-walker@example.com", password="WalkingTest572!", display_name="Other"
        )
        cls.cafe = User.objects.create_user(
            email="walking-cafe@example.com", password="WalkingTest572!",
            display_name="Walking Café", role=User.Role.CAFE,
        )
        breed = Breed.objects.create(
            name="Walking Test Breed", energy_level="MODERATE", default_size="SMALL"
        )
        cls.dog = Dog.objects.create(
            owner=cls.owner, breed=breed, name="Milo", age_months=24, size="SMALL", is_brachycephalic=False
        )
        cls.second_dog = Dog.objects.create(
            owner=cls.owner, breed=breed, name="Pip", age_months=24, size="SMALL", is_brachycephalic=False
        )
        cls.other_dog = Dog.objects.create(
            owner=cls.other_owner, breed=breed, name="Other Dog", age_months=24, size="SMALL", is_brachycephalic=False
        )

    def setUp(self):
        self.now = datetime(2026, 9, 9, 12, tzinfo=ZoneInfo("Australia/Melbourne"))
        clock = patch("walks.services.timezone.now", return_value=self.now)
        clock.start()
        self.addCleanup(clock.stop)
        self.client.force_authenticate(self.owner)

    def payload(self, distance_m=1001, start_seconds=-3600):
        started_at = self.now + timedelta(seconds=start_seconds)
        duration = max(10, distance_m / 2)
        count = max(1, math.ceil(duration / 10))
        # Equatorial eastward movement has a known haversine length. Sample at
        # 2 m/s, safely below the implementation walking-speed threshold.
        return {
            "request_id": str(uuid4()),
            "started_at": started_at.isoformat(),
            "ended_at": (started_at + timedelta(seconds=duration)).isoformat(),
            "dog_ids": [self.dog.pk],
            "samples": [
                {
                    "latitude": 0,
                    "longitude": math.degrees(distance_m * index / count / 6_371_000),
                    "recorded_at": (started_at + timedelta(seconds=duration * index / count)).isoformat(),
                    "accuracy_m": 5,
                    "is_simulated": False,
                }
                for index in range(count + 1)
            ],
        }

    def submit(self, payload):
        return self.client.post(self.url, payload, format="json")

    def assert_wallet(self, points):
        response = self.client.get("/api/wallet")
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["balance"], points)

    def test_server_distance_credits_wallet_and_ignores_forged_totals(self):
        payload = self.payload()
        payload.update({"distance_m": 50000, "points_awarded": 9999})
        payload["dog_ids"].append(self.second_dog.pk)

        response = self.submit(payload)

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        self.assertAlmostEqual(response.data["distance_m"], 1001, delta=0.02)
        self.assertEqual(response.data["points_awarded"], 8)
        self.assertEqual(response.data["point_date"], "2026-09-09")
        self.assertEqual(set(response.data["dog_ids"]), {self.dog.pk, self.second_dog.pk})
        self.assert_wallet(8)
        entry = PointEntry.objects.get(user=self.owner, type=PointEntry.Type.EARN)
        self.assertEqual(entry.source_reference, f"walk:{response.data['id']}")
        self.assertEqual(entry.amount, 8)
        self.assertEqual(entry.remaining_points, 8)
        self.assertEqual(entry.expires_at.year, self.now.year + 1)
        self.assertNotIn("samples", response.data)
        self.assertNotIn("samples", [field.name for field in Walk._meta.fields])

    def test_daily_fractional_distance_is_carried_forward_and_capped_at_40(self):
        first = self.submit(self.payload(distance_m=80, start_seconds=-25000))
        second = self.submit(self.payload(distance_m=80, start_seconds=-24000))
        long_walk = self.submit(self.payload(distance_m=5001, start_seconds=-22000))
        extra = self.submit(self.payload(distance_m=1001, start_seconds=-10000))

        for response in (first, second, long_walk, extra):
            self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(
            [response.data["points_awarded"] for response in (first, second, long_walk, extra)],
            [0, 1, 39, 0],
        )
        self.assert_wallet(40)
        self.assertEqual(PointEntry.objects.filter(type=PointEntry.Type.EARN).count(), 2)

    def test_daily_cap_resets_using_melbourne_end_date_even_across_midnight(self):
        self.now = self.now.replace(hour=0, minute=15)
        with patch("walks.services.timezone.now", return_value=self.now):
            yesterday = self.submit(self.payload(distance_m=5001, start_seconds=-5000))
            across_midnight = self.submit(self.payload(distance_m=1001, start_seconds=-1100))

            self.assertEqual(yesterday.status_code, status.HTTP_201_CREATED)
            self.assertEqual(across_midnight.status_code, status.HTTP_201_CREATED)
            self.assertEqual(yesterday.data["point_date"], "2026-09-08")
            self.assertEqual(yesterday.data["points_awarded"], 40)
            self.assertEqual(across_midnight.data["point_date"], "2026-09-09")
            self.assertEqual(across_midnight.data["points_awarded"], 8)
            self.assert_wallet(48)

    def test_retries_are_idempotent_and_changed_payload_conflicts(self):
        payload = self.payload()
        first = self.submit(payload)
        repeated = self.submit(payload)
        self.assertEqual(first.status_code, status.HTTP_201_CREATED)
        self.assertEqual(repeated.status_code, status.HTTP_201_CREATED)
        self.assertEqual(first.data["id"], repeated.data["id"])
        changed = copy.deepcopy(payload)
        changed["dog_ids"].append(self.second_dog.pk)
        conflict = self.submit(changed)
        self.assertEqual(conflict.status_code, status.HTTP_409_CONFLICT)
        self.assertEqual(conflict.data["code"], "IDEMPOTENCY_CONFLICT")
        self.assertEqual(Walk.objects.count(), 1)
        self.assertEqual(PointEntry.objects.filter(type=PointEntry.Type.EARN).count(), 1)
        self.assert_wallet(8)

    def test_same_time_window_with_a_new_request_id_cannot_award_twice(self):
        payload = self.payload()
        self.assertEqual(self.submit(payload).status_code, status.HTTP_201_CREATED)
        payload["request_id"] = str(uuid4())

        rejected = self.submit(payload)

        self.assertEqual(rejected.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(Walk.objects.count(), 1)
        self.assert_wallet(8)

    def test_only_owner_can_submit_own_dogs_and_read_own_history(self):
        bad_dog = self.payload()
        bad_dog["dog_ids"] = [self.other_dog.pk]
        self.assertEqual(self.submit(bad_dog).status_code, status.HTTP_400_BAD_REQUEST)
        self.assertFalse(Walk.objects.exists())
        self.assertEqual(self.submit(self.payload()).status_code, status.HTTP_201_CREATED)
        self.client.force_authenticate(self.other_owner)
        self.assertEqual(self.client.get(self.url).data, [])
        self.client.force_authenticate(self.cafe)
        self.assertEqual(self.client.get(self.url).status_code, status.HTTP_403_FORBIDDEN)
        self.assertEqual(self.submit(self.payload()).status_code, status.HTTP_403_FORBIDDEN)
        public = APIClient()
        for suffix in ("", "/"):
            self.assertEqual(public.get(self.url + suffix).status_code, status.HTTP_401_UNAUTHORIZED)

    def test_simulated_samples_and_invalid_times_leave_no_walk_or_points(self):
        original = self.payload(distance_m=20)
        cases = []
        simulated = copy.deepcopy(original)
        simulated["samples"][0]["is_simulated"] = True
        cases.append(simulated)
        reversed_walk = copy.deepcopy(original)
        reversed_walk["ended_at"] = reversed_walk["started_at"]
        cases.append(reversed_walk)
        future = self.payload(distance_m=20, start_seconds=300)
        cases.append(future)
        stale = self.payload(distance_m=20, start_seconds=-13 * 3600)
        cases.append(stale)
        out_of_bounds = copy.deepcopy(original)
        out_of_bounds["samples"][0]["recorded_at"] = (self.now - timedelta(days=1)).isoformat()
        cases.append(out_of_bounds)
        duplicate_time = copy.deepcopy(original)
        duplicate_time["samples"][1]["recorded_at"] = duplicate_time["samples"][0]["recorded_at"]
        cases.append(duplicate_time)
        invalid_coordinate = copy.deepcopy(original)
        invalid_coordinate["samples"][0]["latitude"] = 91
        cases.append(invalid_coordinate)
        for payload in cases:
            with self.subTest(payload=payload):
                response = self.submit(payload)
                self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(self.submit(simulated).data["code"], "SIMULATED_LOCATION")
        self.assertFalse(Walk.objects.exists())
        self.assertFalse(PointEntry.objects.filter(user=self.owner).exists())

    def test_low_accuracy_is_discarded_without_bridging_its_gap(self):
        payload = self.payload(distance_m=200)
        for sample in payload["samples"][1:-1]:
            sample["accuracy_m"] = 100

        response = self.submit(payload)

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(response.data["distance_m"], 0)
        self.assertEqual(response.data["points_awarded"], 0)
        self.assert_wallet(0)

    def test_driving_segment_is_discarded_without_losing_valid_walking(self):
        payload = self.payload(distance_m=200)
        # Shift the later route 1 km: the jump is rejected, subsequent 2 m/s
        # walking remains valid instead of bridging back to the prior anchor.
        for sample in payload["samples"][5:]:
            sample["longitude"] += math.degrees(1000 / 6_371_000)

        response = self.submit(payload)

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        self.assertAlmostEqual(response.data["distance_m"], 180, delta=0.02)
        self.assertEqual(response.data["points_awarded"], 1)

    def test_signal_gap_and_five_minute_inactivity_do_not_bridge_distance(self):
        payload = self.payload(distance_m=200)
        first_time = datetime.fromisoformat(payload["samples"][0]["recorded_at"])
        for index, sample in enumerate(payload["samples"]):
            sample["recorded_at"] = (first_time + timedelta(seconds=index * 301)).isoformat()
        payload["ended_at"] = payload["samples"][-1]["recorded_at"]

        response = self.submit(payload)

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(response.data["distance_m"], 0)
        self.assert_wallet(0)

    def test_earned_walk_points_can_buy_the_cafes_canonical_reward(self):
        reward = Reward.objects.create(cafe_user=self.cafe, name="Walk coffee", point_cost=8)
        walked = self.submit(self.payload())
        self.assertEqual(walked.status_code, status.HTTP_201_CREATED)

        order = self.client.post(
            "/api/redemptions", {"reward_id": reward.pk, "request_id": str(uuid4())}, format="json"
        )

        self.assertEqual(order.status_code, status.HTTP_201_CREATED)
        self.assert_wallet(0)
        self.client.force_authenticate(self.cafe)
        feed = self.client.get("/api/cafe/orders")
        self.assertEqual(feed.status_code, status.HTTP_200_OK)
        self.assertEqual([item["id"] for item in feed.data["upserts"]], [order.data["id"]])
        self.client.force_authenticate(self.owner)
        collected = self.client.post(f"/api/redemptions/{order.data['id']}/collect")
        self.assertEqual(collected.status_code, status.HTTP_200_OK)
        self.assertEqual(collected.data["status"], Redemption.Status.COLLECTED)
        self.client.force_authenticate(self.cafe)
        removed = self.client.get("/api/cafe/orders", {"since": feed.data["cursor"]})
        self.assertEqual(removed.data["removed_ids"], [order.data["id"]])
