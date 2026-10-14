from datetime import timedelta
from unittest.mock import patch
from uuid import uuid4

from django.test import TestCase
from rest_framework.exceptions import ValidationError
from rest_framework.test import APIClient

from checkins.models import CheckIn, CheckInWalk
from checkins.services import cancel_checkin, collect_checkin, report_checkin_location, start_checkin, update_walk_context
from checkins.tests.test_checkins import CheckInFixture
from dogs.models import Breed, Dog
from quests.models import QuestDefinition
from rewards.models import PointEntry
from rewards.policy import CHECKIN_SECONDS, local_date
from venues.models import Venue
from walks.models import Walk
from walks.services import WalkConflictError


class LocationCheckInTests(CheckInFixture, TestCase):
    sample = {"sequence": 0, "latitude": -37.8, "longitude": 144.9, "accuracy_m": 5, "is_simulated": False}

    def start(self, kind="CAFE", *, context=None):
        return start_checkin(owner=self.owner, venue_id=self.venues[kind].pk,
                             walk_request_id=(context or self.context).request_id, sample={**self.sample, "recorded_at": self.now}, now=self.now)

    def report(self, row, seconds, **values):
        sample = {**self.sample, "recorded_at": self.now + timedelta(seconds=seconds), "sequence": seconds, **values}
        return report_checkin_location(owner=self.owner, checkin_id=row.pk, sample=sample,
                                      now=self.now + timedelta(seconds=seconds))

    def api_client(self, owner=None):
        client = APIClient()
        client.force_authenticate(owner or self.owner)
        return client

    def test_outside_then_reentry_accumulates_without_counting_outside_time(self):
        row = self.start()
        row = self.report(row, 60)
        self.assertEqual(row.verified_seconds, 60)
        row = self.report(row, 90, latitude=-37.7)
        self.assertEqual(row.verified_seconds, 60)
        self.assertFalse(row.is_accumulating)
        row = self.report(row, 120, latitude=-37.7)
        row = self.report(row, 180)
        self.assertEqual(row.verified_seconds, 60)
        row = self.report(row, 210)
        self.assertEqual(row.verified_seconds, 90)

    def test_missing_unreliable_and_simulated_samples_pause_without_reset(self):
        for invalid in ({"accuracy_m": 31}, {"is_simulated": True}):
            row = self.start("VET")
            row = self.report(row, 60)
            row = self.report(row, 90, **invalid)
            self.assertEqual(row.verified_seconds, 60)
            self.assertIsNone(row.last_verified_at)
            row = self.report(row, 120)
            self.assertEqual(row.verified_seconds, 60)
            row = self.report(row, 150)
            self.assertEqual(row.verified_seconds, 90)
            row.delete()
        row = self.start()
        row = self.report(row, 60)
        row = self.report(row, 200)
        self.assertEqual(row.verified_seconds, 60)
        row = self.report(row, 230)
        self.assertEqual(row.verified_seconds, 90)

    def test_duplicate_and_out_of_order_sequences_or_receipt_times_never_add_time(self):
        row = self.start()
        row = self.report(row, 60)
        row = self.report(row, 120, sequence=60, recorded_at=self.now + timedelta(seconds=60))
        self.assertEqual(row.verified_seconds, 60)
        self.assertEqual(row.last_recorded_at, self.now + timedelta(seconds=60))
        row = self.report(row, 90, sequence=59)
        self.assertEqual(row.verified_seconds, 60)
        row = self.report(row, 30, sequence=200)
        self.assertEqual(row.verified_seconds, 60)
        row = self.report(row, 120)
        self.assertEqual(row.verified_seconds, 60)

    def test_stale_or_conflicting_capture_pauses_the_interval(self):
        row = self.start()
        row = self.report(row, 60)
        row = self.report(row, 120, recorded_at=self.now + timedelta(seconds=60))
        self.assertEqual(row.verified_seconds, 60)
        self.assertIsNone(row.last_verified_at)
        row = self.report(row, 150)
        row = self.report(row, 180)
        self.assertEqual(row.verified_seconds, 90)
        row = self.report(row, 190, sequence=180, latitude=-37.7,
                          recorded_at=self.now + timedelta(seconds=180))
        self.assertIsNone(row.last_verified_at)
        self.assertEqual(row.verified_seconds, 90)

    def test_higher_sequences_cannot_replay_older_capture_intervals(self):
        row = self.start()
        row = self.report(row, 60)
        row = self.report(row, 75, sequence=100, recorded_at=self.now + timedelta(seconds=59))
        self.assertEqual(row.verified_seconds, 60)
        self.assertEqual(row.last_captured_at, self.now + timedelta(seconds=60))
        row = self.report(row, 80, sequence=101, recorded_at=self.now + timedelta(seconds=60))
        self.assertEqual(row.verified_seconds, 60)
        self.assertIsNone(row.last_verified_at)
        row = self.report(row, 90, sequence=110)
        self.assertEqual(row.verified_seconds, 60)
        row = self.report(row, 120)
        self.assertEqual(row.verified_seconds, 90)

    def test_queued_final_fix_ready_time_uses_capture_before_client_finish(self):
        row = self.start("VET")
        row = self.report(row, 60)
        row = self.report(row, 120)
        # Receipt is late, but the final GPS fix was captured before Finish.
        row = self.report(row, 195, recorded_at=self.now + timedelta(seconds=180))
        self.assertEqual(row.ready_at, self.now + timedelta(seconds=180))
        walk = self.completed_walk(ended_at=self.now + timedelta(seconds=185))
        from checkins.services import settle_walk_checkins
        settle_walk_checkins(walk, now=self.now + timedelta(seconds=200))
        row.refresh_from_db()
        self.assertEqual(row.point_entry.amount, 12)

    def test_ready_survives_departure_pause_finish_and_has_no_early_reward(self):
        row = self.start("VET")
        for seconds in (60, 120, 180):
            row = self.report(row, seconds)
        self.assertEqual((row.status, row.verified_seconds), ("READY", 180))
        row = self.report(row, 210, latitude=-37.7)
        cancel_checkin(owner=self.owner, checkin_id=row.pk)
        update_walk_context(owner=self.owner, walk_request_id=self.context.request_id,
                            started_at=self.context.started_at, state="FINISHED", now=self.now + timedelta(seconds=220))
        row.refresh_from_db()
        self.assertEqual(row.status, "READY")
        self.assertFalse(PointEntry.objects.exists())
        with self.assertRaises(ValidationError):
            collect_checkin(owner=self.owner, checkin_id=row.pk)
        walk = self.completed_walk(ended_at=self.now + timedelta(seconds=220))
        from checkins.services import settle_walk_checkins
        settle_walk_checkins(walk, now=self.now + timedelta(seconds=230))
        row.refresh_from_db()
        self.assertEqual(row.point_entry.amount, 12)

    def test_context_pause_clears_anchor_and_terminal_reports_cannot_resume(self):
        row = self.start()
        self.report(row, 60)
        update_walk_context(owner=self.owner, walk_request_id=self.context.request_id,
                            started_at=self.context.started_at, state="PAUSED", now=self.now + timedelta(seconds=70))
        row = self.report(row, 100)
        self.assertEqual(row.verified_seconds, 60)
        update_walk_context(owner=self.owner, walk_request_id=self.context.request_id,
                            started_at=self.context.started_at, state="RECORDING", now=self.now + timedelta(seconds=110))
        row = self.report(row, 120)
        self.assertEqual(row.verified_seconds, 60)
        row = self.report(row, 150)
        self.assertEqual(row.verified_seconds, 90)
        update_walk_context(owner=self.owner, walk_request_id=self.context.request_id,
                            started_at=self.context.started_at, state="FINISHED", now=self.now + timedelta(seconds=155))
        row = self.report(row, 180)
        self.assertEqual(row.verified_seconds, 90)
        with self.assertRaises(WalkConflictError):
            update_walk_context(owner=self.owner, walk_request_id=self.context.request_id,
                                started_at=self.context.started_at, state="RECORDING", now=self.now + timedelta(seconds=190))

    def test_new_walk_never_inherits_partial_progress(self):
        row = self.start()
        self.report(row, 60)
        new_id = uuid4()
        context = update_walk_context(owner=self.owner, walk_request_id=new_id, started_at=self.now,
                                      state="RECORDING", now=self.now)
        row = self.start(context=context)
        self.assertEqual(row.verified_seconds, 0)
        self.assertEqual(CheckIn.objects.count(), 2)
        self.context.refresh_from_db()
        self.assertEqual(self.context.state, "FINISHED")

    def test_new_walk_preserves_old_ready_visit_for_pending_upload(self):
        row = self.opportunity("VET")
        update_walk_context(owner=self.owner, walk_request_id=uuid4(), started_at=self.now,
                            state="RECORDING", now=self.now)
        self.context.refresh_from_db()
        self.assertEqual(self.context.state, "FINISHED")
        self.settle()
        row.refresh_from_db()
        self.assertEqual(row.point_entry.amount, 12)

    def test_superseding_context_accepts_allowed_client_clock_skew(self):
        future = update_walk_context(owner=self.owner, walk_request_id=uuid4(),
                                     started_at=self.now + timedelta(seconds=10),
                                     state="RECORDING", now=self.now)
        update_walk_context(owner=self.owner, walk_request_id=uuid4(), started_at=self.now,
                            state="RECORDING", now=self.now)
        future.refresh_from_db()
        self.assertEqual(future.state, "FINISHED")
        self.assertEqual(future.ended_at, future.started_at)

    def test_context_api_requires_initial_recording_and_immutable_identity(self):
        client = self.api_client()
        identity = uuid4()
        body = {"walk_request_id": str(identity), "started_at": self.now.isoformat(), "state": "FINISHED"}
        with patch("checkins.services.timezone.now", return_value=self.now):
            self.assertEqual(client.post("/api/check-ins/walk-context", body, format="json").status_code, 400)
            body["state"] = "RECORDING"
            self.assertEqual(client.post("/api/check-ins/walk-context", body, format="json").status_code, 200)
            body["started_at"] = (self.now - timedelta(seconds=1)).isoformat()
            self.assertEqual(client.post("/api/check-ins/walk-context", body, format="json").status_code, 409)

    def test_start_requires_recording_walk_and_reliable_in_radius_gps(self):
        for request_id, sample in ((uuid4(), self.sample), (self.context.request_id, {**self.sample, "accuracy_m": 31}),
                                   (self.context.request_id, {**self.sample, "is_simulated": True}),
                                   (self.context.request_id, {**self.sample, "latitude": -37.7})):
            with self.assertRaises(ValidationError):
                start_checkin(owner=self.owner, venue_id=self.venues["CAFE"].pk,
                              walk_request_id=request_id, sample={**sample, "recorded_at": self.now}, now=self.now)
        self.assertFalse(CheckIn.objects.exists())

    def test_scope_map_returns_independent_venue_progress_and_all_partner_receipts(self):
        second = Venue.objects.create(name="Second Cafe", kind="CAFE", latitude=-37.8, longitude=144.9,
                                      checkin_enabled=True, is_partner=True)
        row = self.start()
        query = f"?walk_request_id={self.context.request_id}"
        with patch("checkins.services.timezone.now", return_value=self.now):
            response = self.api_client().get("/api/venues" + query)
        records = {record["id"]: record for record in response.data}
        self.assertEqual(records[row.venue_id]["check_in"]["verified_seconds"], 0)
        self.assertEqual(records[second.pk]["checkin_status"], "AVAILABLE")
        self.assertIsNone(records[second.pk]["check_in"])
        CheckIn.objects.filter(pk=row.pk).update(verified_seconds=600, ready_at=self.now)
        self.settle()
        with patch("checkins.views.local_date", return_value=local_date(self.now)), patch("checkins.services.timezone.now", return_value=self.now):
            response = self.api_client().get("/api/venues" + query)
        for record in response.data:
            if record["kind"] == "CAFE":
                self.assertEqual(record["checkin_status"], "COLLECTED")

    def test_non_partner_businesses_are_excluded_and_cannot_start(self):
        client = self.api_client()
        Venue.objects.filter(kind__in=("CAFE", "RESTAURANT")).update(is_partner=False)
        with patch("checkins.services.timezone.now", return_value=self.now):
            self.assertEqual({row["kind"] for row in client.get("/api/venues").data}, {"VET", "PARK"})
            body = {**self.sample, "recorded_at": self.now.isoformat(), "walk_request_id": str(self.context.request_id)}
            for kind in ("CAFE", "RESTAURANT"):
                response = client.post(f"/api/venues/{self.venues[kind].pk}/check-ins", body, format="json")
                self.assertEqual(response.status_code, 404)
        self.assertFalse(CheckIn.objects.exists())

    def test_withdrawn_partnership_pauses_pending_venue_progress(self):
        row = self.start()
        row = self.report(row, 60)
        self.venues["CAFE"].is_partner = False
        self.venues["CAFE"].save(update_fields=("is_partner",))
        row = self.report(row, 90)
        self.assertEqual(row.verified_seconds, 60)
        self.assertIsNone(row.last_verified_at)

    def test_map_does_not_carry_yesterdays_collection_into_todays_status(self):
        row = self.opportunity("VET")
        self.settle()
        tomorrow = self.now + timedelta(days=1)
        with patch("checkins.views.local_date", return_value=local_date(tomorrow)), patch("checkins.services.timezone.now", return_value=tomorrow):
            client = self.api_client()
            response = client.get(f"/api/venues?walk_request_id={self.context.request_id}")
            venue = next(item for item in response.data if item["id"] == row.venue_id)
            self.assertEqual(venue["checkin_status"], "AVAILABLE")
            self.assertIsNone(venue["check_in"])
            self.assertEqual(client.get(f"/api/check-ins?walk_request_id={self.context.request_id}").data["items"], [])
        row.refresh_from_db()
        self.assertEqual(row.point_entry.amount, 12)

    def test_api_sequence_context_and_owner_scope(self):
        client = self.api_client()
        data = {**self.sample, "recorded_at": self.now.isoformat(), "walk_request_id": str(self.context.request_id)}
        with patch("checkins.services.timezone.now", return_value=self.now):
            response = client.post(f"/api/venues/{self.venues['VET'].pk}/check-ins", data, format="json")
        self.assertEqual(response.status_code, 201)
        self.assertEqual(response.data["walk_request_id"], str(self.context.request_id))
        attempt = response.data["id"]
        with patch("checkins.services.timezone.now", return_value=self.now + timedelta(seconds=60)):
            response = client.post(f"/api/check-ins/{attempt}/locations", {**self.sample, "sequence": 60, "recorded_at": (self.now + timedelta(seconds=60)).isoformat()}, format="json")
        self.assertEqual(response.data["verified_seconds"], 60)
        self.assertEqual(client.post(f"/api/check-ins/{attempt}/collect", {}).status_code, 400)
        other = self.api_client(self.other)
        for action in ("locations", "pause", "collect"):
            self.assertEqual(other.post(f"/api/check-ins/{attempt}/{action}", {**self.sample, "recorded_at": self.now.isoformat()}, format="json").status_code, 404)
        scoped = other.get(f"/api/check-ins?walk_request_id={self.context.request_id}")
        self.assertEqual(scoped.data["items"], [])
        self.assertEqual(client.get("/api/venues?walk_request_id=not-a-uuid").status_code, 400)

    def test_walk_post_settles_atomic_receipt_and_response_loss_retries(self):
        row = self.opportunity("VET")
        breed = Breed.objects.create(name="Test breed", energy_level="LOW", default_size="SMALL")
        dog = Dog.objects.create(owner=self.owner, name="Dog", breed=breed, age_months=12,
                                 size="SMALL", is_brachycephalic=False)
        data = {"request_id": str(self.context.request_id), "started_at": self.context.started_at.isoformat(),
                "ended_at": self.now.isoformat(), "dog_ids": [dog.pk], "samples": [
                    {"latitude": -37.8, "longitude": 144.9, "accuracy_m": 5,
                     "recorded_at": stamp.isoformat()} for stamp in (self.context.started_at, self.now)]}
        client = self.api_client()
        with patch("walks.services.timezone.now", return_value=self.now), patch("checkins.services.credit_points", side_effect=RuntimeError("simulated write failure")):
            with self.assertRaises(RuntimeError):
                client.post("/api/walks", data, format="json")
        self.assertFalse(Walk.objects.exists())
        self.assertFalse(PointEntry.objects.exists())
        with patch("walks.services.timezone.now", return_value=self.now):
            first = client.post("/api/walks", data, format="json")
        self.assertEqual(first.status_code, 201)
        self.assertEqual(first.data["points_awarded"], 0)
        self.assertEqual(first.data["check_in_points_awarded"], 12)
        self.assertEqual(first.data["total_points_awarded"], first.data["wallet_balance"])
        self.assertEqual(first.data["check_in_awards"][0]["venue_id"], row.venue_id)
        QuestDefinition.objects.filter(code="CHECK_IN").update(is_enabled=False)
        self.venues["VET"].is_active = False
        self.venues["VET"].save()
        replay = client.post("/api/walks", data, format="json")
        self.assertEqual(replay.data["check_in_awards"], first.data["check_in_awards"])
        self.assertEqual(PointEntry.objects.count(), 1)
        changed = {**data, "ended_at": (self.now + timedelta(seconds=1)).isoformat()}
        self.assertEqual(client.post("/api/walks", changed, format="json").status_code, 409)
