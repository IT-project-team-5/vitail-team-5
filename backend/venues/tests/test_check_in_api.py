from datetime import datetime, timedelta
from unittest.mock import patch
from zoneinfo import ZoneInfo

from django.contrib.auth import get_user_model
from rest_framework.test import APITestCase

from rewards.models import PointEntry
from rewards.services import get_balance
from venues.models import CheckIn, Venue
from walks.models import Walk


User = get_user_model()
MELBOURNE = ZoneInfo("Australia/Melbourne")
# 0.001 degrees of latitude is about 111 m, so offsets below are easy to reason about.
CAFE_LAT, CAFE_LON = -37.8136, 144.9631


def sample(lat_offset=0.0, accuracy=5, simulated=False):
    return {
        "latitude": CAFE_LAT + lat_offset, "longitude": CAFE_LON,
        "accuracy_m": accuracy, "is_simulated": simulated,
    }


class CheckInApiTests(APITestCase):
    @classmethod
    def setUpTestData(cls):
        cls.owner = User.objects.create_user(
            email="checkin@example.com", password="CheckInTest572!", display_name="Walker")
        cls.other = User.objects.create_user(
            email="other-checkin@example.com", password="CheckInTest572!", display_name="Other")
        cls.cafe_staff = User.objects.create_user(
            email="checkin-cafe@example.com", password="CheckInTest572!",
            display_name="Cafe", role=User.Role.CAFE)
        cls.cafe = Venue.objects.create(
            name="Test Café", venue_type=Venue.VenueType.CAFE,
            latitude=CAFE_LAT, longitude=CAFE_LON, checkin_radius_m=100)
        cls.park = Venue.objects.create(
            name="Test Park", venue_type=Venue.VenueType.DOG_PARK,
            latitude=CAFE_LAT + 0.01, longitude=CAFE_LON)
        cls.closed = Venue.objects.create(
            name="Closed", venue_type=Venue.VenueType.VET, latitude=CAFE_LAT,
            longitude=CAFE_LON, is_active=False)

    def setUp(self):
        self.now = datetime(2026, 9, 9, 12, tzinfo=MELBOURNE)
        clock = patch("venues.services.timezone.now", side_effect=lambda: self.now)
        clock.start()
        self.addCleanup(clock.stop)
        self.client.force_authenticate(self.owner)

    def start(self, venue=None, **kwargs):
        return self.client.post(f"/api/venues/{(venue or self.cafe).pk}/check-ins", sample(**kwargs), format="json")

    def report(self, check_in_id, **kwargs):
        return self.client.post(f"/api/check-ins/{check_in_id}/locations", sample(**kwargs), format="json")

    def advance(self, seconds):
        self.now += timedelta(seconds=seconds)

    def dwell(self, check_in_id, total_seconds, step=30, **kwargs):
        response = None
        for _ in range(total_seconds // step):
            self.advance(step)
            response = self.report(check_in_id, **kwargs)
        return response

    def test_venue_list_shows_active_venues_with_dwell_defaults(self):
        response = self.client.get("/api/venues")
        self.assertEqual(response.status_code, 200)
        by_name = {venue["name"]: venue for venue in response.json()}
        self.assertEqual(set(by_name), {"Test Café", "Test Park"})
        self.assertEqual(by_name["Test Café"]["required_dwell_s"], 600)
        self.assertEqual(by_name["Test Park"]["required_dwell_s"], 300)
        self.assertFalse(by_name["Test Café"]["checked_in_today"])

    def test_completed_dwell_awards_twelve_points_once(self):
        started = self.start()
        self.assertEqual(started.status_code, 201)
        self.assertEqual(started.json()["status"], "IN_PROGRESS")
        response = self.dwell(started.json()["id"], 600)
        self.assertEqual(response.json()["status"], "COMPLETED")
        self.assertEqual(response.json()["awarded_points"], 12)
        self.assertEqual(get_balance(self.owner), 12)
        entry = PointEntry.objects.get(user=self.owner)
        self.assertEqual((entry.type, entry.amount), ("EARN", 12))
        # Late duplicate reports never pay twice.
        self.advance(30)
        self.assertEqual(self.report(started.json()["id"]).json()["status"], "COMPLETED")
        self.assertEqual(get_balance(self.owner), 12)
        venues = {venue["name"]: venue for venue in self.client.get("/api/venues").json()}
        self.assertTrue(venues["Test Café"]["checked_in_today"])

    def test_no_points_before_dwell_is_met(self):
        started = self.start().json()
        response = self.dwell(started["id"], 570)
        self.assertEqual(response.json()["status"], "IN_PROGRESS")
        self.assertEqual(response.json()["verified_seconds"], 570)
        self.assertEqual(get_balance(self.owner), 0)

    def test_client_clock_and_self_reported_completion_are_ignored(self):
        started = self.start().json()
        self.advance(30)
        payload = {**sample(), "recorded_at": "2030-01-01T00:00:00Z", "status": "COMPLETED"}
        response = self.client.post(f"/api/check-ins/{started['id']}/locations", payload, format="json")
        self.assertEqual(response.json()["status"], "IN_PROGRESS")

    def test_cannot_start_outside_radius_or_with_poor_accuracy(self):
        outside = self.start(lat_offset=0.002)  # ~222 m
        self.assertEqual(outside.status_code, 400)
        self.assertEqual(outside.json()["code"], "OUTSIDE_RADIUS")
        poor = self.start(accuracy=80)
        self.assertEqual(poor.json()["code"], "LOW_ACCURACY")
        self.assertFalse(CheckIn.objects.exists())

    def test_simulated_location_cannot_start_or_continue(self):
        self.assertEqual(self.start(simulated=True).json()["code"], "SIMULATED_LOCATION")
        started = self.start().json()
        self.advance(30)
        response = self.report(started["id"], simulated=True)
        self.assertEqual(response.json()["status"], "ABANDONED")
        self.assertEqual(response.json()["abandon_reason"], "SIMULATED")

    def test_leaving_the_radius_abandons_without_penalty_and_retry_works(self):
        started = self.start().json()
        self.dwell(started["id"], 120)
        self.advance(30)
        left = self.report(started["id"], lat_offset=0.005)
        self.assertEqual(left.json()["status"], "ABANDONED")
        self.assertEqual(left.json()["abandon_reason"], "LEFT_RADIUS")
        self.assertEqual(get_balance(self.owner), 0)
        retry = self.start()
        self.assertEqual(retry.status_code, 201)
        self.assertNotEqual(retry.json()["id"], started["id"])

    def test_missed_reports_abandon_instead_of_granting_free_dwell(self):
        started = self.start().json()
        self.advance(700)  # phone off, well past the dwell time and the report gap
        response = self.report(started["id"])
        self.assertEqual(response.json()["status"], "ABANDONED")
        self.assertEqual(response.json()["abandon_reason"], "SIGNAL_LOST")
        self.assertEqual(get_balance(self.owner), 0)

    def test_inaccurate_reports_do_not_extend_the_session(self):
        started = self.start().json()
        for _ in range(4):
            self.advance(30)
            self.report(started["id"], accuracy=80)
        self.advance(30)
        self.assertEqual(self.report(started["id"]).json()["abandon_reason"], "SIGNAL_LOST")

    def test_once_per_venue_per_day_but_other_venues_and_days_are_fine(self):
        first = self.start().json()
        self.dwell(first["id"], 600)
        again = self.start()
        self.assertEqual(again.status_code, 409)
        self.assertEqual(again.json()["code"], "ALREADY_CHECKED_IN")
        park = self.client.post(
            f"/api/venues/{self.park.pk}/check-ins", sample(lat_offset=0.01), format="json")
        self.assertEqual(park.status_code, 201)
        self.now += timedelta(days=1)
        self.assertEqual(self.start().status_code, 201)

    def test_starting_a_new_check_in_replaces_the_open_one(self):
        first = self.start().json()
        self.advance(30)
        park = self.client.post(
            f"/api/venues/{self.park.pk}/check-ins", sample(lat_offset=0.01), format="json")
        self.assertEqual(park.status_code, 201)
        old = CheckIn.objects.get(pk=first["id"])
        self.assertEqual((old.status, old.abandon_reason), ("ABANDONED", "REPLACED"))

    def test_owner_can_abandon(self):
        started = self.start().json()
        response = self.client.post(f"/api/check-ins/{started['id']}/abandon")
        self.assertEqual(response.json()["abandon_reason"], "CANCELLED")

    def test_inactive_and_unknown_venues_are_not_found(self):
        self.assertEqual(self.start(self.closed).status_code, 404)
        self.assertEqual(self.client.post("/api/venues/9999/check-ins", sample(), format="json").status_code, 404)

    def test_check_ins_are_owner_scoped(self):
        started = self.start().json()
        self.client.force_authenticate(self.other)
        self.assertEqual(self.report(started["id"]).status_code, 404)
        self.assertEqual(self.client.post(f"/api/check-ins/{started['id']}/abandon").status_code, 404)

    def test_only_owner_accounts_can_use_check_ins(self):
        self.client.force_authenticate(self.cafe_staff)
        self.assertEqual(self.client.get("/api/venues").status_code, 403)
        self.assertEqual(self.start().status_code, 403)
        self.client.force_authenticate(None)
        self.assertEqual(self.client.get("/api/venues").status_code, 401)

    def test_daily_cap_of_72_limits_check_in_points(self):
        Walk.objects.create(
            owner=self.owner, request_id="00000000-0000-0000-0000-000000000001",
            request_fingerprint="x", started_at=self.now - timedelta(hours=3),
            ended_at=self.now - timedelta(hours=2), point_date=self.now.date(),
            distance_m=5000, points_awarded=40)
        CheckIn.objects.create(
            owner=self.owner, venue=self.park, status="COMPLETED", entered_at=self.now,
            last_report_at=self.now, dwell_completed_at=self.now,
            completed_local_date=self.now.date(), awarded_points=12)
        other_park = Venue.objects.create(
            name="Second Park", venue_type=Venue.VenueType.DOG_PARK,
            latitude=CAFE_LAT, longitude=CAFE_LON + 0.02)
        for venue, expected in ((self.cafe, 12), (other_park, 8)):
            started = self.client.post(
                f"/api/venues/{venue.pk}/check-ins",
                {**sample(), "longitude": venue.longitude}, format="json").json()
            for _ in range(venue.dwell_seconds // 30):
                self.advance(30)
                result = self.client.post(
                    f"/api/check-ins/{started['id']}/locations",
                    {**sample(), "longitude": venue.longitude}, format="json")
            self.assertEqual(result.json()["awarded_points"], expected)
