from datetime import datetime, timedelta, timezone as datetime_timezone
from uuid import uuid4

from django.contrib.auth import get_user_model
from django.db import IntegrityError, transaction
from django.http import Http404
from django.test import TestCase
from django.utils import timezone
from rest_framework.exceptions import ValidationError
from rest_framework.test import APIClient

from checkins.models import CheckIn
from checkins.services import collect_checkin, current_progress, daily_activity_points
from quests.models import QuestDefinition
from rewards.models import PointEntry
from rewards.policy import CHECKIN_SECONDS, MELBOURNE, local_date, next_midnight
from rewards.services import credit_points, spend_points
from venues.models import Venue


class CheckInFixture:
    def setUp(self):
        self.now = datetime(2026, 9, 25, 12, tzinfo=MELBOURNE)
        User = get_user_model()
        self.owner = User.objects.create_user(email="checkin-owner@example.com", display_name="Owner")
        self.other = User.objects.create_user(email="checkin-other@example.com", display_name="Other")
        self.cafe = User.objects.create_user(email="checkin-cafe@example.com", display_name="Café", role="CAFE")
        QuestDefinition.objects.update_or_create(code="CHECK_IN", defaults={"title": "Check-in", "is_enabled": True})
        self.venues = {
            kind: Venue.objects.create(name=f"Test {kind}", kind=kind, latitude=-37.8, longitude=144.9, checkin_enabled=True)
            for kind in Venue.Kind.values
        }

    def opportunity(self, kind="CAFE", *, ready=True, now=None, **overrides):
        now = now or self.now
        duration = CHECKIN_SECONDS[kind]
        values = dict(owner=self.owner, venue=self.venues[kind], venue_name_snapshot=f"Test {kind}",
                      local_date=local_date(now), category_slot=kind, required_seconds=duration,
                      center_latitude=-37.8, center_longitude=144.9,
                      started_at=now - timedelta(seconds=duration + 60), expires_at=next_midnight(now),
                      verified_seconds=duration if ready else 0, ready_at=now - timedelta(seconds=10) if ready else None)
        values.update(overrides)
        return CheckIn.objects.create(**values)

    def credit(self, amount, *, category="WALK", owner=None, day=None, type="EARN"):
        metadata = {"earn_category": category, "earned_on": day or local_date(self.now), "rules_version": "test-only"} if type == "EARN" else {}
        return credit_points(user=owner or self.owner, amount=amount, type=type, source_reference=f"test:{uuid4()}", **metadata)


class CheckInServiceTests(CheckInFixture, TestCase):
    def test_cap_counts_only_walk_and_checkin_earned_on_the_business_day(self):
        self.credit(20)
        self.credit(12, category="CHECK_IN")
        for category in ("NET_WALK", "DAILY_GOAL", "STREAK", "BIRTHDAY", "DOCUMENT"):
            self.credit(60, category=category)
        self.credit(100, type="ADMIN")
        self.credit(100, type="REFUND")
        self.credit(40, day=local_date(self.now) - timedelta(days=1))
        self.credit(40, owner=self.other)
        spend_points(user=self.owner, amount=30, source_reference="test-spend")
        self.assertEqual(daily_activity_points(self.owner, local_date(self.now)), 32)

    def test_collect_is_idempotent_and_remains_replayable_after_disable_and_midnight(self):
        row = self.opportunity()
        first = collect_checkin(owner=self.owner, checkin_id=row.pk, now=self.now)
        self.assertEqual(first["awarded_points"], 12)
        self.assertEqual(first["daily_earned_points"], 12)
        self.assertEqual(first["wallet_balance"], 12)
        entry = PointEntry.objects.get(source_reference=f"checkin:{row.pk}")
        self.assertEqual((entry.user_id, entry.earn_category, entry.earned_on), (self.owner.pk, "CHECK_IN", local_date(self.now)))
        QuestDefinition.objects.filter(code="CHECK_IN").update(is_enabled=False)
        self.venues["CAFE"].is_active = False
        self.venues["CAFE"].save(update_fields=("is_active",))
        replay = collect_checkin(owner=self.owner, checkin_id=row.pk, now=self.now + timedelta(days=1))
        self.assertEqual(replay["check_in"].point_entry_id, entry.pk)
        self.assertEqual(replay["check_in"].collected_at, self.now)
        self.assertEqual(PointEntry.objects.filter(user=self.owner).count(), 1)

    def test_other_owner_cafe_inactive_and_unknown_id_are_not_collectible(self):
        row = self.opportunity()
        for owner, identity in ((self.other, row.pk), (self.cafe, row.pk), (self.owner, row.pk + 9999)):
            with self.subTest(owner=owner.pk, identity=identity), self.assertRaises(Http404):
                collect_checkin(owner=owner, checkin_id=identity, now=self.now)
        self.owner.is_active = False
        self.owner.save(update_fields=("is_active",))
        with self.assertRaises(Http404):
            collect_checkin(owner=self.owner, checkin_id=row.pk, now=self.now)
        self.assertFalse(PointEntry.objects.exists())

    def test_only_verified_ready_state_can_collect_and_client_payload_cannot_supply_progress(self):
        row = self.opportunity(ready=False)
        with self.assertRaises(ValidationError):
            collect_checkin(owner=self.owner, checkin_id=row.pk, now=self.now)
        with self.assertRaises(TypeError):
            collect_checkin(owner=self.owner, checkin_id=row.pk, now=self.now, verified_seconds=600)
        client = APIClient()
        client.force_authenticate(self.owner)
        response = client.post("/api/quests", {"check_in_id": row.pk, "verified_seconds": 600, "ready_at": self.now.isoformat()}, format="json")
        self.assertIn(response.status_code, (404, 405))
        row.refresh_from_db()
        self.assertEqual(row.verified_seconds, 0)
        self.assertFalse(PointEntry.objects.exists())

    def test_disabled_catalogue_or_venue_blocks_uncollected_rows(self):
        row = self.opportunity()
        QuestDefinition.objects.filter(code="CHECK_IN").update(is_enabled=False)
        with self.assertRaises(ValidationError):
            collect_checkin(owner=self.owner, checkin_id=row.pk, now=self.now)
        self.assertEqual(current_progress(owner=self.owner, now=self.now)["items"], [])
        QuestDefinition.objects.filter(code="CHECK_IN").update(is_enabled=True)
        for field in ("is_active", "checkin_enabled"):
            with self.subTest(field=field):
                Venue.objects.filter(pk=row.venue_id).update(**{field: False})
                with self.assertRaises(ValidationError):
                    collect_checkin(owner=self.owner, checkin_id=row.pk, now=self.now)
                self.assertEqual(current_progress(owner=self.owner, now=self.now)["items"], [])
                Venue.objects.filter(pk=row.venue_id).update(**{field: True})
        self.assertFalse(PointEntry.objects.exists())

    def test_expiry_day_and_future_readiness_prevent_awards(self):
        row = self.opportunity(ready_at=self.now + timedelta(seconds=1))
        with self.assertRaises(ValidationError):
            collect_checkin(owner=self.owner, checkin_id=row.pk, now=self.now)
        CheckIn.objects.filter(pk=row.pk).update(ready_at=self.now - timedelta(seconds=10))
        with self.assertRaises(ValidationError):
            collect_checkin(owner=self.owner, checkin_id=row.pk, now=next_midnight(self.now))
        with self.assertRaises(ValidationError):
            collect_checkin(owner=self.owner, checkin_id=row.pk, now=self.now - timedelta(days=1))
        self.assertFalse(PointEntry.objects.exists())

    def test_partial_collect_is_disabled_without_consuming_qualification(self):
        row = self.opportunity()
        self.credit(40)
        self.credit(24, category="CHECK_IN")
        with self.assertRaises(ValidationError):
            collect_checkin(owner=self.owner, checkin_id=row.pk, now=self.now)
        row.refresh_from_db()
        self.assertIsNone(row.point_entry_id)
        self.assertIsNone(row.collected_at)
        self.assertEqual(daily_activity_points(self.owner, local_date(self.now)), 64)
        self.assertEqual([item.pk for item in current_progress(owner=self.owner, now=self.now)["items"]], [row.pk])

    def test_exact_cap_collect_hides_uncollected_but_keeps_today_collected(self):
        ready = self.opportunity()
        other = self.opportunity("PARK", ready=False)
        self.credit(36)
        self.credit(24, category="CHECK_IN")
        self.assertEqual({item.pk for item in current_progress(owner=self.owner, now=self.now)["items"]}, {ready.pk, other.pk})
        collect_checkin(owner=self.owner, checkin_id=ready.pk, now=self.now)
        visible = current_progress(owner=self.owner, now=self.now)
        self.assertEqual(visible["earned_points_today"], 72)
        self.assertEqual([item.pk for item in visible["items"]], [ready.pk])
        Venue.objects.filter(pk=ready.venue_id).update(is_active=False)
        self.assertEqual([item.pk for item in current_progress(owner=self.owner, now=self.now)["items"]], [ready.pk])
        self.assertEqual(current_progress(owner=self.owner, now=next_midnight(self.now))["items"], [])
        self.assertTrue(CheckIn.objects.filter(pk=ready.pk, point_entry__isnull=False).exists())

    def test_progress_is_owner_scoped_and_does_not_manufacture_slots(self):
        self.assertEqual(current_progress(owner=self.owner, now=self.now)["items"], [])
        self.assertFalse(CheckIn.objects.exists())
        self.opportunity(owner=self.other)
        self.opportunity("PARK", ready=False, venue=None, started_at=None, center_latitude=None, center_longitude=None)
        self.assertEqual(current_progress(owner=self.owner, now=self.now)["items"], [])
        self.assertEqual(CheckIn.objects.count(), 2)

    def test_melbourne_date_and_midnight_respect_both_dst_transitions(self):
        for year, month, day, expected_hours in ((2026, 10, 4, 23), (2027, 4, 4, 25)):
            start = datetime(year, month, day, tzinfo=MELBOURNE)
            midnight = next_midnight(start)
            length = midnight.astimezone(datetime_timezone.utc) - start.astimezone(datetime_timezone.utc)
            self.assertEqual(length.total_seconds(), expected_hours * 3600)
            now = start.replace(hour=12)
            row = self.opportunity(now=now)
            with timezone.override("Pacific/Honolulu"):
                result = collect_checkin(owner=self.owner, checkin_id=row.pk, now=now)
                self.assertEqual(result["local_date"], start.date())
                self.assertEqual([item.pk for item in current_progress(owner=self.owner, now=midnight - timedelta(microseconds=1))["items"]], [row.pk])
                self.assertEqual(current_progress(owner=self.owner, now=midnight)["items"], [])


class CheckInConstraintTests(CheckInFixture, TestCase):
    def test_exactly_four_distinct_category_slots_per_owner_date(self):
        for kind in Venue.Kind.values:
            self.opportunity(kind)
        self.assertEqual(CheckIn.objects.filter(owner=self.owner, local_date=local_date(self.now)).count(), 4)
        with self.assertRaises(IntegrityError), transaction.atomic():
            self.opportunity()
        with self.assertRaises(IntegrityError), transaction.atomic():
            self.opportunity(category_slot="BEACH")
        self.opportunity(owner=self.other)
        self.opportunity(now=self.now + timedelta(days=1))
        self.assertEqual(CheckIn.objects.count(), 6)

    def test_database_rejects_incomplete_or_inconsistent_state_shapes(self):
        cases = (
            {"required_seconds": 0}, {"radius_m": 0}, {"promised_points": 0},
            {"verified_seconds": 601}, {"started_at": None}, {"venue": None},
            {"center_latitude": None}, {"center_latitude": 91}, {"center_longitude": -181},
            {"ready_at": self.now - timedelta(days=1)}, {"ready_at": next_midnight(self.now) + timedelta(seconds=1)},
            {"collected_at": self.now},
        )
        for overrides in cases:
            with self.subTest(overrides=overrides), self.assertRaises(IntegrityError), transaction.atomic():
                self.opportunity(**overrides)

    def test_collection_timestamp_cannot_precede_readiness_or_reach_expiry(self):
        entry = self.credit(12, category="CHECK_IN")
        for collected_at in (self.now - timedelta(seconds=11), next_midnight(self.now)):
            with self.subTest(collected_at=collected_at), self.assertRaises(IntegrityError), transaction.atomic():
                self.opportunity(point_entry=entry, collected_at=collected_at)

    def test_one_ledger_entry_cannot_back_two_checkins(self):
        entry = self.credit(12, category="CHECK_IN")
        self.opportunity(point_entry=entry, collected_at=self.now)
        with self.assertRaises(IntegrityError), transaction.atomic():
            self.opportunity("PARK", point_entry=entry, collected_at=self.now)

    def test_point_metadata_cannot_be_partially_classified(self):
        for metadata in (
            {"earn_category": None, "earned_on": local_date(self.now), "rules_version": "test-only"},
            {"earn_category": "CHECK_IN", "earned_on": None, "rules_version": "test-only"},
            {"earn_category": "CHECK_IN", "earned_on": local_date(self.now), "rules_version": None},
        ):
            with self.subTest(metadata=metadata), self.assertRaises(IntegrityError), transaction.atomic():
                PointEntry.objects.create(user=self.owner, amount=12, remaining_points=12, type="EARN",
                                          expires_at=self.now + timedelta(days=365), **metadata)
