from datetime import timedelta
from unittest.mock import patch
from uuid import uuid4

from django.test import TestCase
from rest_framework.exceptions import ValidationError
from rest_framework.test import APIClient, APIRequestFactory

from checkins.models import CheckIn
from checkins.services import cancel_checkin, collect_checkin, report_checkin_location, start_checkin
from checkins.tests.test_checkins import CheckInFixture
from checkins.views import (
    CheckInCancelThrottle,
    CheckInCollectThrottle,
    CheckInLocationThrottle,
    CheckInStartThrottle,
)
from rewards.models import PointEntry
from rewards.policy import CHECKIN_SECONDS, local_date


class LocationCheckInTests(CheckInFixture, TestCase):
    sample = {"latitude": -37.8, "longitude": 144.9, "accuracy_m": 5, "is_simulated": False}

    def test_action_throttles_are_per_user_and_use_independent_buckets(self):
        request = APIRequestFactory().post("/api/check-ins/example/locations")
        request.user = self.owner
        throttles = (
            CheckInStartThrottle, CheckInLocationThrottle,
            CheckInCollectThrottle, CheckInCancelThrottle,
        )
        owner_keys = {throttle().get_cache_key(request, None) for throttle in throttles}
        self.assertEqual(len(owner_keys), 4)
        request.user = self.other
        other_keys = {throttle().get_cache_key(request, None) for throttle in throttles}
        self.assertTrue(owner_keys.isdisjoint(other_keys))
        self.assertEqual(CheckInLocationThrottle.rate, "12/min")

    def test_map_does_not_restore_disabled_venue_with_missing_coordinates(self):
        venue = self.venues["CAFE"]
        start_checkin(owner=self.owner, venue_id=venue.pk, sample=self.sample, now=self.now)
        venue.checkin_enabled = False
        venue.latitude = venue.longitude = None
        venue.save()
        client = APIClient()
        client.force_authenticate(self.owner)
        with patch("checkins.views.local_date", return_value=local_date(self.now)):
            response = client.get("/api/venues")
        self.assertEqual(response.status_code, 200)
        self.assertNotIn(venue.pk, [row["id"] for row in response.data])


    def test_server_times_continuous_dwell_then_requires_collection(self):
        row = start_checkin(owner=self.owner, venue_id=self.venues["CAFE"].pk, sample=self.sample, now=self.now)
        self.assertEqual((row.verified_seconds, row.status), (0, "IN_PROGRESS"))
        for seconds in range(60, CHECKIN_SECONDS["CAFE"] + 1, 60):
            row = report_checkin_location(owner=self.owner, checkin_id=row.pk, sample=self.sample,
                                          now=self.now + timedelta(seconds=seconds))
        self.assertEqual(row.status, "READY")
        self.assertEqual(row.verified_seconds, CHECKIN_SECONDS["CAFE"])
        self.assertFalse(PointEntry.objects.exists(), "Location verification never credits directly.")
        receipt = collect_checkin(owner=self.owner, checkin_id=row.pk, now=self.now + timedelta(seconds=601))
        self.assertEqual(receipt["awarded_points"], 12)
        self.assertEqual(PointEntry.objects.get().earn_category, "CHECK_IN")

    def test_outside_or_missed_report_resets_continuous_dwell(self):
        row = start_checkin(owner=self.owner, venue_id=self.venues["CAFE"].pk, sample=self.sample, now=self.now)
        row = report_checkin_location(owner=self.owner, checkin_id=row.pk, sample=self.sample,
                                      now=self.now + timedelta(seconds=60))
        self.assertEqual(row.verified_seconds, 60)
        outside = dict(self.sample, latitude=-37.7)
        row = report_checkin_location(owner=self.owner, checkin_id=row.pk, sample=outside,
                                      now=self.now + timedelta(seconds=90))
        self.assertEqual(row.verified_seconds, 0)
        row = report_checkin_location(owner=self.owner, checkin_id=row.pk, sample=self.sample,
                                      now=self.now + timedelta(seconds=200))
        self.assertEqual(row.verified_seconds, 0)

    def test_cancel_removes_only_unready_attempt_and_reopens_slot(self):
        row = start_checkin(owner=self.owner, venue_id=self.venues["CAFE"].pk, sample=self.sample, now=self.now)
        self.assertIsNone(cancel_checkin(owner=self.owner, checkin_id=row.pk))
        self.assertFalse(CheckIn.objects.filter(pk=row.pk).exists())
        restarted = start_checkin(owner=self.owner, venue_id=self.venues["CAFE"].pk, sample=self.sample, now=self.now)
        self.assertTrue(CheckIn.objects.filter(pk=restarted.pk).exists())

    def test_reentry_starts_a_fresh_dwell_window(self):
        row = start_checkin(owner=self.owner, venue_id=self.venues["CAFE"].pk, sample=self.sample, now=self.now)
        outside = dict(self.sample, latitude=-37.7)
        report_checkin_location(owner=self.owner, checkin_id=row.pk, sample=outside,
                                now=self.now + timedelta(seconds=30))
        row = report_checkin_location(owner=self.owner, checkin_id=row.pk, sample=self.sample,
                                      now=self.now + timedelta(seconds=60))
        self.assertEqual(row.verified_seconds, 0)
        row = report_checkin_location(owner=self.owner, checkin_id=row.pk, sample=self.sample,
                                      now=self.now + timedelta(seconds=90))
        self.assertEqual(row.verified_seconds, 30)

    def test_start_respects_goal_points_in_shared_daily_cap(self):
        self.credit(61, category="DAILY_GOAL")
        with self.assertRaises(ValidationError):
            start_checkin(owner=self.owner, venue_id=self.venues["CAFE"].pk, sample=self.sample, now=self.now)
        self.assertFalse(CheckIn.objects.exists())

    def test_api_uuid_lifecycle_and_cross_surface_collection_are_idempotent(self):
        client = APIClient()
        client.force_authenticate(self.owner)
        with patch("checkins.services.timezone.now", return_value=self.now):
            started = client.post(f"/api/venues/{self.venues['CAFE'].pk}/check-ins", self.sample, format="json")
        self.assertEqual(started.status_code, 201)
        attempt_id = started.data["id"]
        for seconds in range(60, CHECKIN_SECONDS["CAFE"] + 1, 60):
            with patch("checkins.services.timezone.now", return_value=self.now + timedelta(seconds=seconds)):
                reported = client.post(f"/api/check-ins/{attempt_id}/locations", self.sample, format="json")
            self.assertEqual(reported.status_code, 200)
        self.assertEqual(reported.data["status"], "READY")
        with patch("checkins.services.timezone.now", return_value=self.now + timedelta(seconds=601)):
            first = client.post(f"/api/check-ins/{attempt_id}/collect", {}, format="json")
            replay = client.post(f"/api/check-ins/{attempt_id}/collect/", {"request_id": str(uuid4())}, format="json")
            cancelled = client.post(f"/api/check-ins/{attempt_id}/cancel", {}, format="json")
        self.assertEqual(first.status_code, 200)
        self.assertEqual(replay.status_code, 200)
        self.assertEqual(first.data, replay.data)
        self.assertEqual(cancelled.data["status"], "COLLECTED")
        self.assertEqual(PointEntry.objects.filter(earn_category="CHECK_IN").count(), 1)
        self.assertFalse(PointEntry.objects.filter(earn_category="DAILY_GOAL").exists())

    def test_api_uuid_location_and_cancel_are_owner_scoped(self):
        row = start_checkin(owner=self.owner, venue_id=self.venues["CAFE"].pk, sample=self.sample, now=self.now)
        client = APIClient()
        client.force_authenticate(self.other)
        for action in ("locations", "cancel", "collect"):
            response = client.post(f"/api/check-ins/{row.attempt_id}/{action}", self.sample if action == "locations" else {}, format="json")
            self.assertEqual(response.status_code, 404)
        self.assertTrue(CheckIn.objects.filter(pk=row.pk).exists())
        client.force_authenticate(self.owner)
        response = client.post(f"/api/check-ins/{row.attempt_id}/cancel/", {}, format="json")
        self.assertEqual(response.status_code, 200)
        self.assertFalse(CheckIn.objects.filter(pk=row.pk).exists())

    def test_start_rejects_forged_or_imprecise_locations(self):
        for sample in (dict(self.sample, is_simulated=True), dict(self.sample, accuracy_m=31), dict(self.sample, latitude=-37.7)):
            with self.subTest(sample=sample), self.assertRaises(ValidationError):
                start_checkin(owner=self.owner, venue_id=self.venues["CAFE"].pk, sample=sample, now=self.now)
        self.assertFalse(CheckIn.objects.exists())

    def test_progress_and_venue_api_are_owner_scoped(self):
        client = APIClient()
        client.force_authenticate(self.owner)
        response = client.get("/api/venues")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(len(response.data), 4)
        for venue in response.json():
            self.assertIsInstance(venue["latitude"], (int, float))
            self.assertIsInstance(venue["longitude"], (int, float))
        started = client.post(f"/api/venues/{self.venues['CAFE'].pk}/check-ins", self.sample, format="json")
        self.assertEqual(started.status_code, 201)
        self.assertEqual(started.data["status"], "IN_PROGRESS")
        progress = client.get("/api/check-ins")
        self.assertEqual(progress.status_code, 200)
        self.assertEqual(progress.data["items"][0]["id"], started.data["id"])
        self.assertEqual(progress.data["local_date"], local_date())
