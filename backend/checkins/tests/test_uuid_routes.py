from datetime import timedelta
from unittest.mock import patch
from uuid import UUID

from django.core.cache import cache
from django.test import TestCase
from rest_framework.test import APIClient

from checkins.models import CheckIn
from checkins.services import start_checkin
from checkins.tests.test_checkins import CheckInFixture
from rewards.models import PointEntry


class CheckInUUIDRouteTests(CheckInFixture, TestCase):
    """Swift UUID strings use uppercase letters; all receipt routes accept them."""

    identity = UUID("bf725cce-3319-4410-b4b1-2d679eba2c6c")

    def setUp(self):
        super().setUp()
        cache.clear()
        self.client = APIClient()
        self.client.force_authenticate(self.owner)

    def start(self):
        row = start_checkin(
            owner=self.owner,
            venue_id=self.venues["VET"].pk,
            walk_request_id=self.context.request_id,
            sample=self.sample(0),
            now=self.now,
        )
        row.attempt_id = self.identity
        row.save(update_fields=("attempt_id",))
        return row

    def sample(self, seconds):
        return {
            "sequence": seconds,
            "recorded_at": self.now + timedelta(seconds=seconds),
            "latitude": -37.8,
            "longitude": 144.9,
            "accuracy_m": 5,
            "is_simulated": False,
        }

    def post_location(self, identity, seconds, suffix=""):
        with patch("checkins.services.timezone.now", return_value=self.now + timedelta(seconds=seconds)):
            return self.client.post(
                f"/api/check-ins/{identity}/locations{suffix}", self.sample(seconds), format="json",
            )

    def test_uppercase_location_reports_accumulate_and_appear_in_progress(self):
        row = self.start()
        for seconds, suffix in ((60, ""), (120, "/"), (180, "")):
            response = self.post_location(str(row.attempt_id).upper(), seconds, suffix)
            self.assertEqual(response.status_code, 200)
            self.assertEqual(response.data["verified_seconds"], seconds)
        self.assertEqual(response.data["status"], "READY")
        progress = self.client.get("/api/check-ins", {"walk_request_id": str(self.context.request_id).upper()})
        self.assertEqual(progress.status_code, 200)
        self.assertEqual(progress.data["items"][0]["verified_seconds"], 180)
        self.assertFalse(PointEntry.objects.exists())

    def test_lowercase_and_mixed_case_location_routes_keep_working(self):
        row = self.start()
        for identity, seconds in ((str(row.attempt_id), 60), ("bF725cCe-3319-4410-b4B1-2D679eBa2c6C", 120)):
            response = self.post_location(identity, seconds, "/")
            self.assertEqual(response.status_code, 200)
            self.assertEqual(response.data["verified_seconds"], seconds)

    def test_pause_and_cancel_accept_both_cases_and_trailing_slashes(self):
        row = self.start()
        for action in ("pause", "cancel"):
            for identity in (str(row.attempt_id), str(row.attempt_id).upper()):
                for suffix in ("", "/"):
                    with self.subTest(action=action, identity=identity, suffix=suffix):
                        CheckIn.objects.filter(pk=row.pk).update(last_verified_at=self.now, verified_seconds=60)
                        response = self.client.post(f"/api/check-ins/{identity}/{action}{suffix}", {}, format="json")
                        self.assertEqual(response.status_code, 200)
                        row.refresh_from_db()
                        self.assertIsNone(row.last_verified_at)
                        self.assertEqual(row.verified_seconds, 60)

    def test_collect_accepts_uuid_case_and_replays_without_duplicate_credit(self):
        row = self.opportunity("VET", attempt_id=self.identity)
        self.settle()
        for identity in (str(row.attempt_id).upper(), str(row.attempt_id)):
            for suffix in ("", "/"):
                with self.subTest(identity=identity, suffix=suffix):
                    response = self.client.post(f"/api/check-ins/{identity}/collect{suffix}", {}, format="json")
                    self.assertEqual(response.status_code, 200)
                    self.assertEqual(response.data["awarded_points"], 12)
                    self.assertEqual(response.data["wallet_balance"], 12)
        self.assertEqual(PointEntry.objects.filter(earn_category="CHECK_IN").count(), 1)

    def test_uppercase_routes_remain_owner_scoped(self):
        row = self.start()
        self.client.force_authenticate(self.other)
        for action in ("locations", "pause", "cancel", "collect"):
            with self.subTest(action=action):
                body = self.sample(60) if action == "locations" else {}
                response = self.client.post(f"/api/check-ins/{str(row.attempt_id).upper()}/{action}", body, format="json")
                self.assertEqual(response.status_code, 404)
                self.assertEqual(response["Content-Type"], "application/json")
