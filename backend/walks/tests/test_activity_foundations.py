from datetime import timedelta
from decimal import Decimal
from uuid import uuid4

from django.contrib.auth import get_user_model
from django.core.exceptions import ValidationError as ModelValidationError
from django.db import IntegrityError, transaction
from django.test import TestCase
from django.utils import timezone
from rest_framework.exceptions import ValidationError

from social.services import block_user
from walks.models import LocationSample, NetWalkInterval, Walk, WalkSession
from walks.services import WalkConflictError, start_walk_session, store_verified_net_interval, transition_walk_session


class ActivityFoundationTests(TestCase):
    @classmethod
    def setUpTestData(cls):
        User = get_user_model()
        cls.owner = User.objects.create_user(email="session-first@example.com", display_name="First")
        cls.other = User.objects.create_user(email="session-second@example.com", display_name="Second")

    def setUp(self):
        self.now = timezone.now()
        self.start = self.now - timedelta(minutes=5)

    def session(self, owner=None, **overrides):
        values = dict(owner=owner or self.owner, request_id=uuid4(), state="RECORDING", started_at=self.start,
                      heartbeat_at=self.now, validation_version="test-only", net_consent_at=self.start)
        values.update(overrides)
        return WalkSession.objects.create(**values)

    def sample(self, **overrides):
        values = dict(owner=self.owner, session=self.session(), stream_id=uuid4(), sequence=0, segment_id=0,
                      recorded_at=self.start, received_at=self.now, latitude=0, longitude=0, accuracy_m=5)
        values.update(overrides)
        return LocationSample(**values)

    def test_single_active_session_retry_transition_and_owner_isolation(self):
        request_id = uuid4()
        first = start_walk_session(owner=self.owner, request_id=request_id, started_at=self.start, validation_version="test-only")
        replay = start_walk_session(owner=self.owner, request_id=request_id, started_at=self.start, validation_version="test-only")
        self.assertEqual(first.pk, replay.pk)
        with self.assertRaises(WalkConflictError):
            start_walk_session(owner=self.owner, request_id=uuid4(), started_at=self.start, validation_version="test-only")
        with self.assertRaises(ValidationError):
            transition_walk_session(owner=self.other, session_id=first.pk, state="FINISHED")
        WalkSession.objects.filter(pk=first.pk).update(last_latitude=1, last_longitude=1, location_recorded_at=self.start, location_expires_at=self.now)
        paused = transition_walk_session(owner=self.owner, session_id=first.pk, state="PAUSED")
        self.assertIsNone(paused.location_recorded_at)
        self.assertIsNone(paused.last_latitude)
        transition_walk_session(owner=self.owner, session_id=first.pk, state="RECORDING")
        closed = transition_walk_session(owner=self.owner, session_id=first.pk, state="FINISHED")
        self.owner.refresh_from_db()
        self.assertIsNone(self.owner.active_walk_session_id)
        self.assertEqual(closed.state, "FINISHED")
        with self.assertRaises(WalkConflictError):
            transition_walk_session(owner=self.owner, session_id=first.pk, state="RECORDING")

    def test_database_rejects_terminal_session_without_end_and_unpaired_coordinates(self):
        for overrides in ({"state": "FINISHED"}, {"last_latitude": 1}, {"ended_at": self.now}):
            with self.subTest(overrides=overrides), self.assertRaises(IntegrityError), transaction.atomic():
                self.session(**overrides)

    def test_sample_identity_purpose_coordinate_and_owner_constraints(self):
        sample = self.sample()
        sample.save()
        duplicate = self.sample(session=sample.session, stream_id=sample.stream_id)
        with self.assertRaises(IntegrityError), transaction.atomic():
            duplicate.save()
        for overrides in ({"session": None}, {"latitude": 91}, {"accuracy_m": -1}):
            with self.subTest(overrides=overrides), self.assertRaises(IntegrityError), transaction.atomic():
                self.sample(**overrides).save()
        invalid_owner = self.sample(session=self.session(owner=self.other))
        with self.assertRaises(ModelValidationError):
            invalid_owner.clean()

    def test_historical_walk_duration_is_unknown_and_elapsed_time_is_not_a_default(self):
        walk = Walk.objects.create(owner=self.owner, request_id=uuid4(), request_fingerprint="a" * 64,
                                   started_at=self.start, ended_at=self.now, point_date=self.now.date(), distance_m=100)
        self.assertIsNone(walk.active_seconds)
        self.assertIsNone(walk.net_distance_m)
        self.assertIsNone(walk.base_point_entry_id)
        walk.active_seconds = 301
        with self.assertRaises(ModelValidationError):
            walk.clean()

    def test_database_rejects_net_credit_without_known_positive_distance_and_settlement(self):
        from rewards.services import credit_points
        entry = credit_points(user=self.owner, amount=2, type="EARN", source_reference="test-net-shape",
                              earn_category="NET_WALK", earned_on=self.now.date(), rules_version="test-only")
        for distance, settled_at in ((None, self.now), (0, self.now), (100, None)):
            with self.subTest(distance=distance, settled_at=settled_at), self.assertRaises(IntegrityError), transaction.atomic():
                Walk.objects.create(owner=self.owner, request_id=uuid4(), request_fingerprint="a" * 64,
                                    started_at=self.start, ended_at=self.now, point_date=self.now.date(), distance_m=100,
                                    net_point_entry=entry, net_distance_m=distance, net_settled_at=settled_at)
        self.assertFalse(Walk.objects.filter(net_point_entry=entry).exists())

    def interval(self, first, second, **overrides):
        values = dict(first_session_id=first.pk, second_session_id=second.pk,
                      started_at=self.start + timedelta(seconds=10), ended_at=self.start + timedelta(seconds=20),
                      first_distance_m=Decimal("10.00"), second_distance_m=Decimal("9.00"),
                      rules_version="test-only", validation_summary={"fixture": True})
        values.update(overrides)
        return store_verified_net_interval(**values)

    def test_net_interval_is_idempotent_not_a_credit_and_overlap_is_rejected(self):
        first, second = self.session(), self.session(owner=self.other)
        interval = self.interval(first, second)
        self.assertEqual(self.interval(first, second).pk, interval.pk)
        with self.assertRaises(WalkConflictError):
            self.interval(first, second, first_distance_m=Decimal("15.00"))
        with self.assertRaises(ModelValidationError):
            self.interval(first, second, started_at=self.start + timedelta(seconds=15), ended_at=self.start + timedelta(seconds=25))
        self.assertEqual(NetWalkInterval.objects.count(), 1)
        self.assertFalse(self.owner.point_entries.exists())
        self.assertFalse(self.other.point_entries.exists())

    def test_net_rejects_same_owner_withdrawn_consent_and_blocks(self):
        first, same_owner = self.session(), self.session()
        with self.assertRaises(ValidationError):
            self.interval(first, same_owner)
        other = self.session(owner=self.other, net_consent_withdrawn_at=self.start + timedelta(seconds=15))
        with self.assertRaises(ModelValidationError):
            self.interval(first, other)
        other.net_consent_withdrawn_at = None
        other.save(update_fields=("net_consent_withdrawn_at",))
        block_user(actor=self.other, other=self.owner)
        with self.assertRaises(ValidationError):
            self.interval(first, other)
        self.assertFalse(NetWalkInterval.objects.exists())
