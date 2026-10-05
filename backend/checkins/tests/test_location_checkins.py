from datetime import timedelta

from django.test import TestCase
from rest_framework.exceptions import ValidationError
from rest_framework.test import APIClient

from checkins.models import CheckIn
from checkins.services import cancel_checkin, collect_checkin, report_checkin_location, start_checkin
from checkins.tests.test_checkins import CheckInFixture
from rewards.models import PointEntry
from rewards.policy import CHECKIN_SECONDS, local_date


class LocationCheckInTests(CheckInFixture, TestCase):
    sample = {"latitude": -37.8, "longitude": 144.9, "accuracy_m": 5, "is_simulated": False}

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
        started = client.post(f"/api/venues/{self.venues['CAFE'].pk}/check-ins", self.sample, format="json")
        self.assertEqual(started.status_code, 201)
        self.assertEqual(started.data["status"], "IN_PROGRESS")
        progress = client.get("/api/check-ins")
        self.assertEqual(progress.status_code, 200)
        self.assertEqual(progress.data["items"][0]["id"], started.data["id"])
        self.assertEqual(progress.data["local_date"], local_date())
