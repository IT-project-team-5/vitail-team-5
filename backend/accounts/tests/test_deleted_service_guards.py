from datetime import timedelta
from decimal import Decimal
from uuid import uuid4

from django.contrib.auth import get_user_model
from django.core.exceptions import ValidationError as ModelValidationError
from django.http import Http404
from django.test import TestCase
from django.utils import timezone
from rest_framework.exceptions import PermissionDenied, ValidationError

from checkins.models import CheckIn
from checkins.services import collect_checkin
from dogs.models import Breed, Dog
from evidence.models import DocumentSubmission
from evidence.serializers import DocumentRequestSerializer
from evidence.services import collect_document, submit_document
from quests.models import QuestDefinition
from quests.services import BirthdayClaimError, collect_birthday
from rewards.models import PointEntry
from rewards.policy import local_date, next_midnight
from social.models import Friendship, UserBlock
from social.services import are_friends, block_user, request_friendship, respond_to_friendship
from venues.models import Venue
from walks.models import NetWalkInterval, Walk, WalkSession
from walks.services import create_walk, start_walk_session, store_verified_net_interval, transition_walk_session


class DeletedAccountServiceGuardsTests(TestCase):
    def setUp(self):
        User = get_user_model()
        self.owner = User.objects.create_user(email="deleted-service-owner@example.com", display_name="Owner")
        self.other = User.objects.create_user(email="deleted-service-other@example.com", display_name="Other")
        self.now = timezone.now()
        self.start = self.now - timedelta(minutes=3)
        breed = Breed.objects.create(name="Deleted service breed", energy_level="LOW", default_size="SMALL")
        self.dog = Dog.objects.create(owner=self.owner, name="Coco", breed=breed, age_months=0,
            date_of_birth=local_date(self.now), size="SMALL", is_brachycephalic=False)
        for code in ("BIRTHDAY", "DOCUMENTS", "CHECK_IN"):
            QuestDefinition.objects.update_or_create(code=code, defaults={"title": code, "is_enabled": True})

    def tombstone(self, user=None):
        # Keep callers' old User instance alive: services must read current DB
        # state under their account lock instead of trusting stale auth objects.
        get_user_model().objects.filter(pk=(user or self.owner).pk).update(deleted_at=self.now)
        self.assertIsNone((user or self.owner).deleted_at)

    def document_data(self):
        serializer = DocumentRequestSerializer(data={"request_id": str(uuid4()), "dog_id": self.dog.pk,
            "kind": "COUNCIL_REGISTRATION", "registration_number": "Council ABC"})
        serializer.is_valid(raise_exception=True)
        return serializer.validated_data

    def test_deleted_owner_cannot_submit_walk_or_start_session_with_stale_user_instance(self):
        self.tombstone()
        with self.assertRaisesMessage(ValidationError, "Only active dog owners"):
            create_walk(owner=self.owner, request_id=uuid4(), started_at=self.start, ended_at=self.now, dog_ids=[self.dog.pk], samples=[])
        with self.assertRaisesMessage(ValidationError, "Only active owners"):
            start_walk_session(owner=self.owner, request_id=uuid4(), started_at=self.start, validation_version="test-only")
        self.assertFalse(Walk.objects.exists())
        self.assertFalse(WalkSession.objects.exists())
        self.assertFalse(PointEntry.objects.exists())

    def test_deleted_owner_cannot_resume_but_server_can_cancel_and_clear_active_session(self):
        session = start_walk_session(owner=self.owner, request_id=uuid4(), started_at=self.start, validation_version="test-only")
        transition_walk_session(owner=self.owner, session_id=session.pk, state="PAUSED")
        self.tombstone()
        for state in ("RECORDING", "PAUSED"):
            with self.subTest(state=state), self.assertRaises(ValidationError):
                transition_walk_session(owner=self.owner, session_id=session.pk, state=state)
        cancelled = transition_walk_session(owner=self.owner, session_id=session.pk, state="CANCELLED")
        self.assertEqual(cancelled.state, "CANCELLED")
        self.owner.refresh_from_db()
        self.assertIsNone(self.owner.active_walk_session_id)

    def test_deleted_member_cannot_create_net_intervals(self):
        first = start_walk_session(owner=self.owner, request_id=uuid4(), started_at=self.start, validation_version="test-only")
        second = start_walk_session(owner=self.other, request_id=uuid4(), started_at=self.start, validation_version="test-only")
        WalkSession.objects.filter(pk__in=[first.pk, second.pk]).update(net_consent_at=self.start)
        self.tombstone()
        with self.assertRaisesMessage(ValidationError, "unavailable"):
            store_verified_net_interval(first_session_id=first.pk, second_session_id=second.pk,
                started_at=self.start + timedelta(seconds=10), ended_at=self.start + timedelta(seconds=20),
                first_distance_m=Decimal("10.00"), second_distance_m=Decimal("9.00"),
                rules_version="test-only", validation_summary={"fixture": True})
        self.assertFalse(NetWalkInterval.objects.exists())

    def test_deleted_owner_cannot_collect_birthday_documents_or_checkin(self):
        receipt, _ = submit_document(owner=self.owner, data=self.document_data())
        venue = Venue.objects.create(name="Test Park", kind="PARK", latitude=-37.8, longitude=144.9, checkin_enabled=True)
        checkin = CheckIn.objects.create(owner=self.owner, venue=venue, local_date=local_date(self.now), category_slot="PARK",
            required_seconds=30, verified_seconds=30, center_latitude=-37.8, center_longitude=144.9,
            started_at=self.start, ready_at=self.now - timedelta(seconds=10), expires_at=next_midnight(self.now))
        self.tombstone()
        with self.assertRaises(BirthdayClaimError) as error:
            collect_birthday(owner=self.owner, dog_id=self.dog.pk, now=self.now)
        self.assertEqual(error.exception.status_code, 403)
        with self.assertRaises(PermissionDenied):
            submit_document(owner=self.owner, data=self.document_data())
        with self.assertRaises(Http404):
            collect_document(owner=self.owner, entitlement_id=receipt["entitlement_id"], now=self.now)
        with self.assertRaises(Http404):
            collect_checkin(owner=self.owner, checkin_id=checkin.pk, now=self.now)
        self.assertEqual(DocumentSubmission.objects.count(), 1)
        self.assertFalse(PointEntry.objects.exists())

    def test_deleted_member_is_not_a_friend_and_cannot_change_social_relationships(self):
        request_friendship(sender=self.owner, recipient=self.other)
        respond_to_friendship(actor=self.other, other=self.owner, accept=True)
        self.assertTrue(are_friends(self.owner.pk, self.other.pk))
        self.tombstone()
        self.assertFalse(are_friends(self.owner.pk, self.other.pk))
        for action in (
            lambda: request_friendship(sender=self.owner, recipient=self.other),
            lambda: respond_to_friendship(actor=self.other, other=self.owner, accept=True),
            lambda: block_user(actor=self.other, other=self.owner),
        ):
            with self.assertRaises(ModelValidationError):
                action()
        self.assertEqual(Friendship.objects.count(), 1)
        self.assertFalse(UserBlock.objects.exists())
