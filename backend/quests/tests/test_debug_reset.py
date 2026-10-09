from datetime import date, datetime, timedelta
from unittest.mock import patch
from uuid import uuid4
from zoneinfo import ZoneInfo

from django.contrib.auth import get_user_model
from django.test import override_settings
from rest_framework.test import APIClient, APITestCase

from checkins.models import CheckIn
from dogs.models import Breed, Dog, DogDailyGoal, DogGoalTarget
from evidence.models import DocumentEntitlement, DocumentKind, DocumentSubmission, EvidenceFingerprint
from quests.models import QuestAward
from rewards.models import PointEntry
from rewards.policy import local_date, next_midnight
from rewards.services import credit_points, get_balance
from venues.models import Venue
from walks.models import Walk


User = get_user_model()


@override_settings(DEBUG=True)
class QuestDebugResetTests(APITestCase):
    def setUp(self):
        self.now = datetime(2026, 10, 8, 12, tzinfo=ZoneInfo("Australia/Melbourne"))
        self.owner = User.objects.create_user(email="reset-owner@example.com", display_name="Owner")
        self.other = User.objects.create_user(email="reset-other@example.com", display_name="Other")
        self.cafe = User.objects.create_user(email="reset-cafe@example.com", display_name="Cafe", role=User.Role.CAFE)
        breed = Breed.objects.create(name="Reset breed", energy_level="MODERATE", default_size="SMALL")
        self.dog = Dog.objects.create(owner=self.owner, breed=breed, name="Milo", age_months=72,
            date_of_birth=date(2020, 10, 8), size="SMALL", is_brachycephalic=False)
        self.other_dog = Dog.objects.create(owner=self.other, breed=breed, name="Pip", age_months=72,
            date_of_birth=date(2020, 10, 8), size="SMALL", is_brachycephalic=False)
        self.client.force_authenticate(self.owner)

    def credit(self, owner, amount, source, category, rules_version):
        return credit_points(user=owner, amount=amount, type=PointEntry.Type.EARN,
            source_reference=source, earn_category=category, earned_on=local_date(self.now),
            rules_version=rules_version)

    def document_state(self, owner, dog, suffix):
        entitlement = DocumentEntitlement.objects.create(
            owner=owner, dog=dog, dog_id_snapshot=dog.pk, kind=DocumentKind.MICROCHIP,
            entitlement_key="lifetime", promised_points=300,
            rules_version="microchip-lifetime-2026-09-25",
        )
        entry = self.credit(owner, 300, f"document-entitlement:{entitlement.pk}",
                            PointEntry.EarnCategory.DOCUMENT, entitlement.rules_version)
        entitlement.point_entry = entry
        entitlement.collected_at = self.now
        entitlement.save(update_fields=("point_entry", "collected_at"))
        submission = DocumentSubmission.objects.create(
            owner=owner, dog=dog, dog_id_snapshot=dog.pk, dog_name_snapshot=dog.name,
            kind=DocumentKind.MICROCHIP, request_id=uuid4(), request_fingerprint=suffix,
            registration_number="012345678901234", entitlement=entitlement,
            file=f"documents/{suffix}.pdf",
        )
        EvidenceFingerprint.objects.create(
            owner=owner, kind=DocumentKind.MICROCHIP, fingerprint=suffix,
            dog_id_snapshot=dog.pk, entitlement=entitlement, is_file=True,
        )
        return entitlement, submission, entry

    def check_in(self, owner, suffix):
        venue = Venue.objects.create(name=f"Venue {suffix}", kind=Venue.Kind.CAFE,
            latitude=-37.8, longitude=144.9, checkin_enabled=True, is_partner=True)
        row = CheckIn.objects.create(
            owner=owner, venue=venue, venue_name_snapshot=venue.name, local_date=local_date(self.now),
            category_slot=Venue.Kind.CAFE, required_seconds=600, verified_seconds=600,
            center_latitude=-37.8, center_longitude=144.9,
            last_recorded_at=self.now - timedelta(minutes=1), last_latitude=-37.8,
            last_longitude=144.9, last_verified_at=self.now - timedelta(minutes=1),
            started_at=self.now - timedelta(minutes=11), ready_at=self.now - timedelta(minutes=1),
            expires_at=next_midnight(self.now),
        )
        entry = self.credit(owner, 12, f"checkin:{row.pk}",
                            PointEntry.EarnCategory.CHECK_IN, row.rules_version)
        row.point_entry = entry
        row.collected_at = self.now
        row.save(update_fields=("point_entry", "collected_at"))
        return row, venue, entry

    def award(self, owner, dog):
        award = QuestAward.objects.create(
            owner=owner, dog=dog, dog_id_snapshot=dog.pk, dog_name_snapshot=dog.name,
            kind=QuestAward.Kind.BIRTHDAY, year=2026,
            qualification_key=f"birthday:{dog.pk}:2026", promised_points=20,
            qualified_on=local_date(self.now), qualified_at=self.now, rules_version="reset-test",
        )
        entry = self.credit(owner, 20, award.qualification_key,
                            PointEntry.EarnCategory.BIRTHDAY, award.rules_version)
        award.point_entry = entry
        award.awarded_at = self.now
        award.save(update_fields=("point_entry", "awarded_at"))
        return award, entry

    def test_reset_replays_existing_ledger_entries_and_preserves_owner_scope(self):
        entitlement, _submission, document_entry = self.document_state(self.owner, self.dog, "owner")
        other_entitlement, _, _ = self.document_state(self.other, self.other_dog, "other")
        award, birthday_entry = self.award(self.owner, self.dog)
        other_award, _ = self.award(self.other, self.other_dog)
        check_in, venue, check_in_entry = self.check_in(self.owner, "owner")
        other_check_in, _, _ = self.check_in(self.other, "other")
        target = DogGoalTarget.objects.create(
            dog=self.dog, dog_id_snapshot=self.dog.pk, owner=self.owner,
            effective_from=local_date(self.now), target_active_seconds=1800,
        )
        goal = DogDailyGoal.objects.create(
            dog=self.dog, dog_id_snapshot=self.dog.pk, owner=self.owner,
            local_date=local_date(self.now), target_active_seconds=1800,
            inputs_snapshot={"target_id": target.pk}, rules_version="manual-duration-v1",
        )
        walk = Walk.objects.create(
            owner=self.owner, request_id=uuid4(), request_fingerprint="walk",
            started_at=self.now - timedelta(minutes=20), ended_at=self.now,
            point_date=local_date(self.now), distance_m=1000, active_seconds=1200,
        )
        before_balance = get_balance(self.owner)
        before_entries = set(PointEntry.objects.filter(user=self.owner).values_list("pk", flat=True))

        with patch("quests.debug_reset.private_storage.delete") as delete_file:
            with self.captureOnCommitCallbacks(execute=True):
                response = self.client.post("/api/quests/reset", {}, format="json")

        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.data, {
            "reset": True, "wallet_balance": before_balance,
            "cleared": {"quest_awards": 1, "document_submissions": 1,
                        "document_entitlements": 1, "evidence_fingerprints": 1, "check_ins": 1},
        })
        self.assertEqual(get_balance(self.owner), before_balance)
        self.assertEqual(set(PointEntry.objects.filter(user=self.owner).values_list("pk", flat=True)), before_entries)
        self.assertTrue(Dog.objects.filter(pk=self.dog.pk).exists())
        self.assertTrue(DogGoalTarget.objects.filter(pk=target.pk).exists())
        self.assertTrue(DogDailyGoal.objects.filter(pk=goal.pk).exists())
        self.assertTrue(Walk.objects.filter(pk=walk.pk).exists())
        self.assertFalse(DocumentSubmission.objects.filter(owner=self.owner).exists())
        self.assertFalse(EvidenceFingerprint.objects.filter(owner=self.owner).exists())
        self.assertIsNone(DocumentEntitlement.objects.get(pk=entitlement.pk).point_entry_id)
        self.assertIsNone(QuestAward.objects.get(pk=award.pk).point_entry_id)
        reset_check_in = CheckIn.objects.get(pk=check_in.pk)
        self.assertEqual(reset_check_in.point_entry_id, check_in_entry.pk)
        self.assertIsNotNone(reset_check_in.started_at)
        self.assertTrue(DocumentEntitlement.objects.filter(pk=other_entitlement.pk, point_entry__isnull=False).exists())
        self.assertTrue(QuestAward.objects.filter(pk=other_award.pk, point_entry__isnull=False).exists())
        self.assertTrue(CheckIn.objects.filter(pk=other_check_in.pk, point_entry__isnull=False).exists())
        delete_file.assert_called_once_with("documents/owner.pdf")

        with patch("checkins.views.local_date", return_value=local_date(self.now)), \
                patch("checkins.services.timezone.now", return_value=self.now):
            self.assertEqual(self.client.get("/api/check-ins").data["items"][0]["status"], "COLLECTED")
            venue_rows = self.client.get("/api/venues").data
        self.assertEqual(next(row for row in venue_rows if row["id"] == venue.pk)["checkin_status"], "COLLECTED")

        submitted = self.client.post("/api/quests/documents", {
            "request_id": str(uuid4()), "dog_id": self.dog.pk,
            "kind": DocumentKind.MICROCHIP, "registration_number": "012345678901234",
        }, format="json")
        self.assertEqual(submitted.status_code, 201)
        self.assertEqual(submitted.data["entitlement_id"], entitlement.pk)
        with patch("evidence.services.timezone.now", return_value=self.now):
            collected_document = self.client.post(
                f"/api/quests/documents/entitlements/{entitlement.pk}/collect", {}, format="json")
        self.assertEqual(collected_document.status_code, 200)
        self.assertEqual(DocumentEntitlement.objects.get(pk=entitlement.pk).point_entry_id, document_entry.pk)

        with patch("quests.services.timezone.now", return_value=self.now):
            collected_birthday = self.client.post(
                f"/api/quests/birthdays/{self.dog.pk}/collect", {}, format="json")
        self.assertEqual(collected_birthday.status_code, 201)
        self.assertEqual(QuestAward.objects.get(pk=award.pk).point_entry_id, birthday_entry.pk)

        # A Quest reset must not reopen an already committed venue kind quota.
        with patch("checkins.services.timezone.now", return_value=self.now):
            recollected_check_in = self.client.post(
                f"/api/check-ins/{check_in.attempt_id}/collect", {}, format="json")
        self.assertEqual(recollected_check_in.status_code, 200)
        self.assertEqual(CheckIn.objects.get(pk=check_in.pk).point_entry_id, check_in_entry.pk)
        self.assertEqual(get_balance(self.owner), before_balance)
        self.assertEqual(set(PointEntry.objects.filter(user=self.owner).values_list("pk", flat=True)), before_entries)

    @override_settings(DEBUG=False, TESTING=False)
    def test_reset_is_hidden_outside_debug_or_test_mode(self):
        self.document_state(self.owner, self.dog, "production")
        response = self.client.post("/api/quests/reset", {}, format="json")
        self.assertEqual(response.status_code, 404)
        self.assertTrue(DocumentSubmission.objects.filter(owner=self.owner).exists())

    def test_reset_requires_an_authenticated_owner(self):
        self.client.force_authenticate(self.cafe)
        self.assertEqual(self.client.post("/api/quests/reset", {}).status_code, 403)
        self.client.force_authenticate(None)
        self.assertEqual(self.client.post("/api/quests/reset", {}).status_code, 401)
