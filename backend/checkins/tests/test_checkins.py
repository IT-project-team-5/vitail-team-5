from datetime import datetime, timedelta, timezone as datetime_timezone
from uuid import uuid4

from django.contrib.auth import get_user_model
from django.db import IntegrityError, transaction
from django.http import Http404
from django.test import TestCase, override_settings
from django.utils import timezone
from rest_framework.exceptions import ValidationError
from rest_framework.test import APIClient

from checkins.models import CheckIn, CheckInWalk
from checkins.services import collect_checkin, current_progress, daily_activity_points, settle_walk_checkins
from quests.models import QuestDefinition
from rewards.models import PointEntry
from rewards.policy import CHECKIN_SECONDS, MELBOURNE, local_date, next_midnight
from rewards.services import credit_points, get_balance, spend_points
from venues.models import Venue
from walks.models import Walk


class CheckInFixture:
    def setUp(self):
        self.now = timezone.now().replace(microsecond=0)
        User = get_user_model()
        self.owner = User.objects.create_user(email="checkin-owner@example.com", display_name="Owner")
        self.other = User.objects.create_user(email="checkin-other@example.com", display_name="Other")
        self.cafe = User.objects.create_user(email="checkin-cafe@example.com", display_name="Cafe", role="CAFE")
        QuestDefinition.objects.update_or_create(code="CHECK_IN", defaults={"title": "Check-in", "is_enabled": True})
        self.venues = {kind: Venue.objects.create(name=f"Test {kind}", kind=kind, latitude=-37.8,
                       longitude=144.9, checkin_enabled=True,
                       is_partner=kind in ("CAFE", "RESTAURANT")) for kind in Venue.Kind.values}
        self.context = self.walk_context()

    def walk_context(self, *, owner=None, started_at=None, state="RECORDING", **overrides):
        values = dict(owner=owner or self.owner, request_id=uuid4(),
                      started_at=started_at or self.now - timedelta(hours=1), state=state)
        values.update(overrides)
        return CheckInWalk.objects.create(**values)

    def opportunity(self, kind="CAFE", *, ready=True, now=None, **overrides):
        now = now or self.now
        duration = CHECKIN_SECONDS[kind]
        owner = overrides.get("owner", self.owner)
        context = overrides.pop("walk_context", self.context if owner.pk == self.owner.pk else self.walk_context(owner=owner))
        values = dict(owner=owner, walk_context=context, venue=self.venues[kind], venue_name_snapshot=f"Test {kind}",
                      local_date=local_date(now), category_slot=kind, required_seconds=duration,
                      center_latitude=-37.8, center_longitude=144.9,
                      started_at=now - timedelta(seconds=duration + 60), expires_at=now + timedelta(hours=10),
                      verified_seconds=duration if ready else 0, ready_at=now - timedelta(seconds=10) if ready else None)
        values.update(overrides)
        return CheckIn.objects.create(**values)

    def completed_walk(self, *, context=None, ended_at=None):
        context = context or self.context
        return Walk.objects.create(owner=context.owner, request_id=context.request_id, request_fingerprint="x" * 64,
                                   started_at=context.started_at, ended_at=ended_at or self.now,
                                   point_date=local_date(ended_at or self.now), distance_m=0, points_awarded=0)

    def settle(self, *, context=None, now=None):
        context = context or self.context
        walk = context.walk if context.walk_id else self.completed_walk(context=context)
        settle_walk_checkins(walk, now=now or self.now)
        context.refresh_from_db()
        return walk

    def credit(self, amount, *, category="WALK", owner=None, day=None, type="EARN"):
        metadata = {"earn_category": category, "earned_on": day or local_date(self.now), "rules_version": "test-only"} if type == "EARN" else {}
        return credit_points(user=owner or self.owner, amount=amount, type=type, source_reference=f"test:{uuid4()}", **metadata)


class CheckInServiceTests(CheckInFixture, TestCase):
    def test_cap_counts_all_capped_sources_and_excludes_spending_special_rewards(self):
        for points, category in ((20, "WALK"), (12, "CHECK_IN"), (20, "DAILY_GOAL"), (10, "NET_WALK")):
            self.credit(points, category=category)
        for category in ("STREAK", "BIRTHDAY", "DOCUMENT"):
            self.credit(60, category=category)
        self.credit(100, type="ADMIN")
        self.credit(100, type="REFUND")
        self.credit(40, day=local_date(self.now) - timedelta(days=1))
        spend_points(user=self.owner, amount=30, source_reference="test-spend")
        self.assertEqual(daily_activity_points(self.owner, local_date(self.now)), 62)

    def test_standalone_collection_cannot_credit_ready_or_legacy_rows(self):
        for context in (self.context, None):
            row = self.opportunity(walk_context=context, venue=self.venues["PARK"] if context is None else self.venues["CAFE"])
            with self.assertRaises(ValidationError) as exc:
                collect_checkin(owner=self.owner, checkin_id=row.pk, now=self.now)
            self.assertEqual(str(exc.exception.detail["code"]), "FINISH_WALK_REQUIRED")
        self.assertFalse(PointEntry.objects.exists())

    def test_owner_scoped_receipt_and_inactive_accounts(self):
        row = self.opportunity()
        self.settle()
        for owner, identity in ((self.other, row.pk), (self.cafe, row.pk), (self.owner, row.pk + 9999)):
            with self.assertRaises(Http404):
                collect_checkin(owner=owner, checkin_id=identity)
        self.owner.is_active = False
        self.owner.save(update_fields=("is_active",))
        with self.assertRaises(Http404):
            collect_checkin(owner=self.owner, checkin_id=row.pk)

    def test_settlement_receipt_replays_after_disable_midnight_and_venue_removal(self):
        row = self.opportunity()
        walk = self.settle()
        original = collect_checkin(owner=self.owner, checkin_id=row.pk)
        self.assertEqual((original["awarded_points"], original["wallet_balance"]), (12, 12))
        QuestDefinition.objects.filter(code="CHECK_IN").update(is_enabled=False)
        self.venues["CAFE"].is_active = False
        self.venues["CAFE"].save()
        settle_walk_checkins(walk, now=self.now + timedelta(days=1))
        replay = collect_checkin(owner=self.owner, checkin_id=row.pk, now=self.now + timedelta(days=1))
        self.assertEqual(replay["awarded_points"], 12)
        self.assertEqual(PointEntry.objects.filter(earn_category="CHECK_IN").count(), 1)

    def test_only_complete_rows_awarded_and_cafe_restaurant_keep_separate_quotas(self):
        cafe = self.opportunity()
        restaurant = self.opportunity("RESTAURANT")
        vet = self.opportunity("VET")
        park = self.opportunity("PARK", ready=False)
        self.settle()
        for row in (cafe, restaurant, vet, park):
            row.refresh_from_db()
        self.assertEqual(sum(bool(row.point_entry_id) for row in (cafe, restaurant)), 2)
        self.assertIsNotNone(vet.point_entry_id)
        self.assertIsNone(park.point_entry_id)
        self.assertEqual(get_balance(self.owner), 36)
        other = self.walk_context()
        repeated = self.opportunity("CAFE", walk_context=other)
        self.settle(context=other)
        repeated.refresh_from_db()
        self.assertIsNone(repeated.point_entry_id)

    def test_full_reward_rule_at_cap_and_snapshot_blocked_result_on_retry(self):
        row = self.opportunity()
        self.credit(61)
        walk = self.settle()
        row.refresh_from_db()
        self.assertIsNone(row.point_entry_id)
        self.assertEqual(get_balance(self.owner), 61)
        # Even a later policy change cannot backfill a settled blocked row.
        PointEntry.objects.filter(user=self.owner).delete()
        settle_walk_checkins(walk)
        self.assertFalse(PointEntry.objects.exists())

    def test_40_walk_20_goal_awards_exactly_one_12_point_venue(self):
        self.credit(40)
        self.credit(20, category="DAILY_GOAL")
        self.opportunity("VET")
        self.opportunity("PARK")
        self.settle()
        self.assertEqual(daily_activity_points(self.owner, local_date(self.now)), 72)
        self.assertEqual(CheckIn.objects.filter(point_entry__isnull=False).count(), 1)

    def test_disabled_or_cancelled_context_never_awards(self):
        self.opportunity()
        QuestDefinition.objects.filter(code="CHECK_IN").update(is_enabled=False)
        self.settle()
        self.assertFalse(PointEntry.objects.exists())
        QuestDefinition.objects.filter(code="CHECK_IN").update(is_enabled=True)
        context = self.walk_context(state="CANCELLED", ended_at=self.now)
        self.opportunity("PARK", walk_context=context)
        self.settle(context=context)
        self.assertFalse(PointEntry.objects.exists())

    def test_withdrawn_business_partnership_prevents_settlement(self):
        cafe = self.opportunity("CAFE")
        restaurant = self.opportunity("RESTAURANT")
        Venue.objects.filter(pk__in=(cafe.venue_id, restaurant.venue_id)).update(is_partner=False)
        self.settle()
        self.assertFalse(PointEntry.objects.exists())
        self.context.refresh_from_db()
        self.assertIsNotNone(self.context.settled_at)
        # A later partnership cannot backfill this already-settled walk.
        Venue.objects.filter(pk__in=(cafe.venue_id, restaurant.venue_id)).update(is_partner=True)
        self.settle()
        self.assertFalse(PointEntry.objects.exists())

    def test_finished_context_does_not_need_live_social_gps_for_settlement(self):
        self.opportunity()
        self.context.state = "FINISHED"
        self.context.ended_at = self.now
        self.context.save()
        self.settle()
        self.assertEqual(get_balance(self.owner), 12)

    def test_ready_visit_outside_uploaded_walk_is_rejected_and_nothing_credited(self):
        self.opportunity(ready_at=self.now + timedelta(seconds=1))
        with self.assertRaises(ValidationError):
            self.settle()
        self.assertFalse(PointEntry.objects.exists())
        self.context.refresh_from_db()
        self.assertIsNone(self.context.settled_at)

    def test_cross_midnight_award_uses_walk_end_business_date_once(self):
        end = datetime(2026, 10, 10, 0, 1, tzinfo=MELBOURNE)
        context = self.walk_context(started_at=end - timedelta(minutes=30))
        row = self.opportunity("VET", now=end - timedelta(minutes=2), walk_context=context)
        walk = self.completed_walk(context=context, ended_at=end)
        settle_walk_checkins(walk, now=end + timedelta(minutes=1))
        row.refresh_from_db()
        self.assertEqual(row.local_date, end.date())
        self.assertEqual(row.point_entry.earned_on, end.date())
        settle_walk_checkins(walk, now=end + timedelta(days=1))
        self.assertEqual(PointEntry.objects.count(), 1)

    def test_progress_does_not_leak_previous_walk_partial_work_or_other_owner(self):
        old = self.opportunity(ready=False)
        self.opportunity("PARK", owner=self.other)
        current = self.walk_context()
        row = self.opportunity("VET", ready=False, walk_context=current)
        visible = current_progress(owner=self.owner, walk_request_id=current.request_id, now=self.now)
        self.assertEqual([item.pk for item in visible["items"]], [row.pk])
        self.assertNotIn(old.pk, [item.pk for item in visible["items"]])
        self.assertEqual(current_progress(owner=self.owner, walk_request_id=uuid4(), now=self.now)["items"], [])

    def test_quest_surface_cannot_accept_client_authored_completion(self):
        row = self.opportunity(ready=False)
        client = APIClient()
        client.force_authenticate(self.owner)
        response = client.post("/api/quests", {"check_in_id": row.pk, "verified_seconds": 600}, format="json")
        self.assertIn(response.status_code, (404, 405))
        self.assertFalse(PointEntry.objects.exists())


class CheckInConstraintTests(CheckInFixture, TestCase):
    def test_same_walk_venue_unique_but_new_walk_has_independent_progress(self):
        self.opportunity()
        with self.assertRaises(IntegrityError), transaction.atomic():
            self.opportunity()
        self.opportunity(walk_context=self.walk_context())
        self.assertEqual(CheckIn.objects.count(), 2)
        with self.assertRaises(IntegrityError), transaction.atomic():
            self.opportunity("PARK", category_slot="BEACH")

    def test_database_rejects_unbounded_progress_or_false_collection(self):
        for values in ({"required_seconds": 0}, {"radius_m": 0}, {"promised_points": 0},
                       {"verified_seconds": 601}, {"venue": None}, {"center_latitude": 91},
                       {"started_at": None}, {"collected_at": self.now}):
            with self.subTest(values=values), self.assertRaises(IntegrityError), transaction.atomic():
                self.opportunity(**values)

    def test_collection_can_follow_midnight_but_cannot_precede_ready(self):
        entry = self.credit(12, category="CHECK_IN")
        with self.assertRaises(IntegrityError), transaction.atomic():
            self.opportunity(point_entry=entry, collected_at=self.now - timedelta(minutes=1))
        self.opportunity(point_entry=entry, collected_at=next_midnight(self.now))

    def test_melbourne_midnight_respects_dst(self):
        for year, month, day, hours in ((2026, 10, 4, 23), (2027, 4, 4, 25)):
            start = datetime(year, month, day, tzinfo=MELBOURNE)
            duration = next_midnight(start).astimezone(datetime_timezone.utc) - start.astimezone(datetime_timezone.utc)
            self.assertEqual(duration.total_seconds(), hours * 3600)
