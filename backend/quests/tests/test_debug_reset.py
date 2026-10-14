from datetime import date, datetime, timedelta
from unittest.mock import patch
from uuid import uuid4
from zoneinfo import ZoneInfo

from django.contrib.auth import get_user_model
from django.test import override_settings
from rest_framework.test import APIClient, APITestCase

from checkins.models import CheckIn, CheckInWalk
from checkins.services import report_checkin_location, settle_walk_checkins, start_checkin
from dogs.models import Breed, Dog, DogDailyGoal, DogGoalTarget
from evidence.models import DocumentEntitlement, DocumentKind, DocumentSubmission, EvidenceFingerprint
from quests.models import QuestAward, QuestDefinition
from rewards.models import PointEntry
from rewards.policy import local_date, next_midnight
from rewards.services import credit_points, get_balance
from venues.models import Venue
from walks.models import Walk
from walks.services import MAX_WALK_AGE


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

    def check_in(self, owner, suffix, *, source_style="legacy"):
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
        source = (f"checkin:{row.pk}" if source_style == "legacy" else
                  f"venue-walk:{owner.pk}:{row.local_date}:{row.category_slot}")
        entry = self.credit(owner, 12, source,
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
                with patch("quests.debug_reset.timezone.now", return_value=self.now):
                    response = self.client.post("/api/quests/reset", {}, format="json")
                    repeated_response = self.client.post("/api/quests/reset", {}, format="json")

        self.assertEqual(response.status_code, 200)
        self.assertEqual(repeated_response.status_code, 200)
        self.assertEqual(repeated_response.data["wallet_balance"], before_balance)
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
        self.assertIsNone(reset_check_in.point_entry_id)
        self.assertIsNone(reset_check_in.started_at)
        self.assertTrue(DocumentEntitlement.objects.filter(pk=other_entitlement.pk, point_entry__isnull=False).exists())
        self.assertTrue(QuestAward.objects.filter(pk=other_award.pk, point_entry__isnull=False).exists())
        self.assertTrue(CheckIn.objects.filter(pk=other_check_in.pk, point_entry__isnull=False).exists())
        delete_file.assert_called_once_with("documents/owner.pdf")

        with patch("checkins.views.local_date", return_value=local_date(self.now)), \
                patch("checkins.services.timezone.now", return_value=self.now):
            self.assertEqual(self.client.get("/api/check-ins").data["items"], [])
            venue_rows = self.client.get("/api/venues").data
        self.assertEqual(next(row for row in venue_rows if row["id"] == venue.pk)["checkin_status"], "AVAILABLE")

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

        # Re-run the venue quest through a new Walk. Settlement reattaches the
        # old ledger entry, so the test can run again without adding points.
        request_id = uuid4()
        context = CheckInWalk.objects.create(
            owner=self.owner, request_id=request_id,
            started_at=self.now - timedelta(minutes=20), state=CheckInWalk.State.RECORDING,
        )
        replayed = start_checkin(
            owner=self.owner, venue_id=venue.pk, walk_request_id=request_id,
            sample={"sequence": 1, "recorded_at": self.now - timedelta(seconds=10),
                    "latitude": -37.8, "longitude": 144.9, "accuracy_m": 5,
                    "is_simulated": False}, now=self.now,
        )
        self.assertEqual(replayed.pk, check_in.pk)
        CheckIn.objects.filter(pk=replayed.pk).update(
            verified_seconds=600, ready_at=self.now - timedelta(seconds=1),
        )
        replay_walk = Walk.objects.create(
            owner=self.owner, request_id=request_id, request_fingerprint="venue-replay",
            started_at=context.started_at, ended_at=self.now,
            point_date=local_date(self.now), distance_m=0, active_seconds=0,
        )
        settle_walk_checkins(replay_walk, now=self.now)
        self.assertEqual(CheckIn.objects.get(pk=check_in.pk).point_entry_id, check_in_entry.pk)
        self.assertEqual(get_balance(self.owner), before_balance)
        self.assertEqual(set(PointEntry.objects.filter(user=self.owner).values_list("pk", flat=True)), before_entries)

    def test_later_day_reset_reattaches_lifetime_and_annual_document_ledgers(self):
        council_expiry = date(2027, 4, 9)
        definitions = (
            (DocumentKind.MICROCHIP, "lifetime", "microchip-lifetime-2026-09-25",
             "012345678901234", None),
            (DocumentKind.COUNCIL, f"expiry:{council_expiry.isoformat()}",
             "council-expiry-2026-09-27", "MELB-572", council_expiry),
        )
        originals = {}
        for kind, key, rules_version, number, valid_to in definitions:
            entitlement = DocumentEntitlement.objects.create(
                owner=self.owner, dog=self.dog, dog_id_snapshot=self.dog.pk,
                kind=kind, entitlement_key=key, promised_points=300,
                rules_version=rules_version, valid_to=valid_to,
                renewal_blocked_through=valid_to,
            )
            entry = self.credit(
                self.owner, 300, f"document-entitlement:{entitlement.pk}",
                PointEntry.EarnCategory.DOCUMENT, rules_version,
            )
            entitlement.point_entry = entry
            entitlement.collected_at = self.now
            entitlement.save(update_fields=("point_entry", "collected_at"))
            DocumentSubmission.objects.create(
                owner=self.owner, dog=self.dog, dog_id_snapshot=self.dog.pk,
                dog_name_snapshot=self.dog.name, kind=kind, request_id=uuid4(),
                request_fingerprint=f"before-reset-{kind}", entitlement=entitlement,
                registration_number=number,
                council_name="City of Melbourne" if kind == DocumentKind.COUNCIL else "",
                valid_to=valid_to,
            )
            originals[kind] = (entitlement, entry, number, valid_to)

        before_balance = get_balance(self.owner)
        before_entries = set(PointEntry.objects.filter(user=self.owner).values_list("pk", flat=True))
        later = self.now + timedelta(days=1)
        with patch("quests.debug_reset.timezone.now", return_value=later):
            response = self.client.post("/api/quests/reset", {}, format="json")
        self.assertEqual(response.status_code, 200)

        for kind, (entitlement, entry, number, valid_to) in originals.items():
            entitlement.refresh_from_db()
            self.assertIsNone(entitlement.point_entry_id)
            payload = {
                "request_id": str(uuid4()), "dog_id": self.dog.pk,
                "kind": kind, "registration_number": number,
            }
            if kind == DocumentKind.COUNCIL:
                payload.update(council_name="City of Melbourne", valid_to=valid_to.isoformat())
            submitted = self.client.post("/api/quests/documents", payload, format="json")
            self.assertEqual(submitted.status_code, 201)
            self.assertEqual(submitted.data["entitlement_id"], entitlement.pk)
            collected = self.client.post(
                f"/api/quests/documents/entitlements/{entitlement.pk}/collect", {}, format="json",
            )
            self.assertEqual(collected.status_code, 200)
            entitlement.refresh_from_db()
            self.assertEqual(entitlement.point_entry_id, entry.pk)

        self.assertEqual(get_balance(self.owner), before_balance)
        self.assertEqual(
            set(PointEntry.objects.filter(user=self.owner).values_list("pk", flat=True)),
            before_entries,
        )

    def test_later_same_day_reset_replays_at_cap_and_refreshes_expiry(self):
        check_in, venue, entry = self.check_in(self.owner, "at-cap", source_style="current")
        reset_now = self.now + timedelta(hours=8)
        CheckIn.objects.filter(pk=check_in.pk).update(expires_at=self.now + timedelta(hours=2))
        other_venue = Venue.objects.create(
            name="Other cafe", kind=Venue.Kind.CAFE, latitude=-37.8, longitude=144.9,
            checkin_enabled=True, is_partner=True,
        )
        self.credit(self.owner, 60, "walk-at-cap", PointEntry.EarnCategory.WALK, "test-only")
        before_balance = get_balance(self.owner)
        before_entries = set(PointEntry.objects.filter(user=self.owner).values_list("pk", flat=True))
        with patch("checkins.services.timezone.now", return_value=self.now):
            ordinary_progress = self.client.get("/api/check-ins")
        ordinary_item = next(
            item for item in ordinary_progress.data["items"] if item["id"] == str(check_in.attempt_id)
        )
        self.assertFalse(ordinary_item["is_replayable"])

        with patch("quests.debug_reset.timezone.now", return_value=reset_now):
            response = self.client.post("/api/quests/reset", {}, format="json")
            repeated_response = self.client.post("/api/quests/reset", {}, format="json")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(repeated_response.status_code, 200)
        self.assertEqual(repeated_response.data["wallet_balance"], before_balance)
        self.assertEqual(CheckIn.objects.get(pk=check_in.pk).expires_at, next_midnight(reset_now))

        with patch("checkins.views.local_date", return_value=local_date(reset_now)), \
                patch("checkins.services.timezone.now", return_value=reset_now):
            records = {record["id"]: record for record in self.client.get("/api/venues").data}
        self.assertEqual(records[venue.pk]["checkin_status"], "AVAILABLE")
        self.assertEqual(records[other_venue.pk]["checkin_status"], "UNAVAILABLE")
        QuestDefinition.objects.filter(code=QuestDefinition.Code.CHECK_IN).update(is_enabled=False)
        with patch("checkins.views.local_date", return_value=local_date(reset_now)), \
                patch("checkins.services.timezone.now", return_value=reset_now):
            disabled = {record["id"]: record for record in self.client.get("/api/venues").data}
        self.assertEqual(disabled[venue.pk]["checkin_status"], "UNAVAILABLE")
        QuestDefinition.objects.filter(code=QuestDefinition.Code.CHECK_IN).update(is_enabled=True)

        request_id = uuid4()
        context = CheckInWalk.objects.create(
            owner=self.owner, request_id=request_id,
            started_at=reset_now - timedelta(minutes=20), state=CheckInWalk.State.RECORDING,
        )
        start_payload = {
            "walk_request_id": str(request_id), "sequence": 1,
            "recorded_at": (reset_now - timedelta(seconds=10)).isoformat(),
            "latitude": -37.8, "longitude": 144.9, "accuracy_m": 5,
            "is_simulated": False,
        }
        with patch("checkins.services.timezone.now", return_value=reset_now):
            start_response = self.client.post(
                f"/api/venues/{venue.pk}/check-ins", start_payload, format="json",
            )
        self.assertEqual(start_response.status_code, 201)
        self.assertTrue(start_response.data["is_replayable"])
        replayed = CheckIn.objects.get(attempt_id=start_response.data["id"])
        self.assertEqual(
            replayed.expires_at,
            context.started_at + MAX_WALK_AGE,
        )
        location_now = reset_now + timedelta(seconds=10)
        location_payload = {
            "sequence": 2, "recorded_at": location_now.isoformat(),
            "latitude": -37.8, "longitude": 144.9, "accuracy_m": 5,
            "is_simulated": False,
        }
        with patch("checkins.services.timezone.now", return_value=location_now):
            location_response = self.client.post(
                f"/api/check-ins/{replayed.attempt_id}/locations", location_payload, format="json",
            )
            pause_response = self.client.post(
                f"/api/check-ins/{replayed.attempt_id}/pause", {}, format="json",
            )
        self.assertEqual(location_response.status_code, 200)
        self.assertTrue(location_response.data["is_replayable"])
        self.assertEqual(pause_response.status_code, 200)
        self.assertTrue(pause_response.data["is_replayable"])
        with patch("checkins.services.timezone.now", return_value=reset_now), \
                patch("checkins.views.local_date", return_value=local_date(reset_now)):
            progress = self.client.get("/api/check-ins")
            venue_progress = {item["id"]: item for item in self.client.get("/api/venues").data}
        self.assertEqual(progress.status_code, 200)
        self.assertEqual(progress.data["earned_points_today"], 72)
        replay_item = next(item for item in progress.data["items"] if item["id"] == str(replayed.attempt_id))
        self.assertTrue(replay_item["is_replayable"])
        self.assertEqual(venue_progress[venue.pk]["checkin_status"], "IN_PROGRESS")
        self.assertTrue(venue_progress[venue.pk]["check_in"]["is_replayable"])

        Venue.objects.filter(pk=venue.pk).update(is_partner=False)
        with patch("checkins.services.timezone.now", return_value=reset_now):
            ineligible_progress = self.client.get("/api/check-ins")
        ineligible_item = next(
            item for item in ineligible_progress.data["items"] if item["id"] == str(replayed.attempt_id)
        )
        self.assertFalse(ineligible_item["is_replayable"])
        Venue.objects.filter(pk=venue.pk).update(is_partner=True)

        replay_expiry = replayed.expires_at
        CheckIn.objects.filter(pk=replayed.pk).update(expires_at=reset_now)
        with patch("checkins.services.timezone.now", return_value=reset_now):
            expired_progress = self.client.get("/api/check-ins")
        expired_item = next(
            item for item in expired_progress.data["items"] if item["id"] == str(replayed.attempt_id)
        )
        self.assertFalse(expired_item["is_replayable"])
        CheckIn.objects.filter(pk=replayed.pk).update(expires_at=replay_expiry)

        CheckInWalk.objects.filter(pk=context.pk).update(
            state=CheckInWalk.State.FINISHED, ended_at=reset_now,
        )
        with patch("checkins.services.timezone.now", return_value=reset_now):
            finished_progress = self.client.get(
                f"/api/check-ins?walk_request_id={request_id}",
            )
        finished_item = next(
            item for item in finished_progress.data["items"] if item["id"] == str(replayed.attempt_id)
        )
        self.assertFalse(finished_item["is_replayable"])
        CheckInWalk.objects.filter(pk=context.pk).update(
            state=CheckInWalk.State.RECORDING, ended_at=None,
        )

        QuestDefinition.objects.filter(code=QuestDefinition.Code.CHECK_IN).update(is_enabled=False)
        with patch("checkins.services.timezone.now", return_value=reset_now), \
                patch("checkins.views.local_date", return_value=local_date(reset_now)):
            disabled_progress = self.client.get("/api/check-ins")
            disabled_venues = {item["id"]: item for item in self.client.get("/api/venues").data}
        disabled_item = next(
            item for item in disabled_progress.data["items"] if item["id"] == str(replayed.attempt_id)
        )
        self.assertFalse(disabled_item["is_replayable"])
        self.assertEqual(disabled_venues[venue.pk]["checkin_status"], "UNAVAILABLE")
        QuestDefinition.objects.filter(code=QuestDefinition.Code.CHECK_IN).update(is_enabled=True)

        CheckIn.objects.filter(pk=replayed.pk).update(
            verified_seconds=600, ready_at=reset_now - timedelta(seconds=1),
        )
        CheckInWalk.objects.filter(pk=context.pk).update(
            state=CheckInWalk.State.FINISHED, ended_at=reset_now,
        )
        with patch("checkins.services.timezone.now", return_value=reset_now), \
                patch("checkins.views.local_date", return_value=local_date(reset_now)):
            ready_progress = self.client.get(
                f"/api/check-ins?walk_request_id={request_id}",
            )
            ready_venues = {
                item["id"]: item for item in self.client.get(
                    f"/api/venues?walk_request_id={request_id}",
                ).data
            }
        ready_item = next(
            item for item in ready_progress.data["items"] if item["id"] == str(replayed.attempt_id)
        )
        self.assertTrue(ready_item["is_replayable"])
        self.assertEqual(ready_venues[venue.pk]["checkin_status"], "READY")
        self.assertTrue(ready_venues[venue.pk]["check_in"]["is_replayable"])
        walk = Walk.objects.create(
            owner=self.owner, request_id=request_id, request_fingerprint="at-cap-replay",
            started_at=context.started_at, ended_at=reset_now,
            point_date=local_date(reset_now), distance_m=0, active_seconds=0,
        )
        settle_walk_checkins(walk, now=reset_now)

        self.assertEqual(CheckIn.objects.get(pk=check_in.pk).point_entry_id, entry.pk)
        self.assertEqual(get_balance(self.owner), before_balance)
        self.assertEqual(
            set(PointEntry.objects.filter(user=self.owner).values_list("pk", flat=True)),
            before_entries,
        )

    def test_reset_detaches_real_settled_walk_context_and_replays_its_ledger(self):
        check_in, venue, entry = self.check_in(self.owner, "settled", source_style="current")
        request_id = uuid4()
        historical_walk = Walk.objects.create(
            owner=self.owner, request_id=request_id, request_fingerprint="settled-history",
            started_at=self.now - timedelta(minutes=20), ended_at=self.now,
            point_date=local_date(self.now), distance_m=0, active_seconds=0,
        )
        historical_context = CheckInWalk.objects.create(
            owner=self.owner, request_id=request_id,
            started_at=historical_walk.started_at, ended_at=historical_walk.ended_at,
            state=CheckInWalk.State.FINISHED, walk=historical_walk, settled_at=self.now,
        )
        check_in.walk_context = historical_context
        check_in.save(update_fields=("walk_context",))
        self.credit(self.owner, 60, "settled-walk-cap", PointEntry.EarnCategory.WALK, "test-only")
        before_balance = get_balance(self.owner)
        before_entries = set(PointEntry.objects.filter(user=self.owner).values_list("pk", flat=True))

        with patch("quests.debug_reset.timezone.now", return_value=self.now):
            response = self.client.post("/api/quests/reset", {}, format="json")

        self.assertEqual(response.status_code, 200)
        self.assertFalse(CheckInWalk.objects.filter(pk=historical_context.pk).exists())
        self.assertTrue(Walk.objects.filter(pk=historical_walk.pk).exists())
        check_in.refresh_from_db()
        self.assertIsNone(check_in.walk_context_id)
        self.assertIsNone(check_in.point_entry_id)
        self.assertIsNone(check_in.started_at)
        self.assertTrue(PointEntry.objects.filter(pk=entry.pk).exists())
        self.assertEqual(get_balance(self.owner), before_balance)

        replay_request_id = uuid4()
        replay_context = CheckInWalk.objects.create(
            owner=self.owner, request_id=replay_request_id,
            started_at=self.now - timedelta(minutes=20), state=CheckInWalk.State.RECORDING,
        )
        replayed = start_checkin(
            owner=self.owner, venue_id=venue.pk, walk_request_id=replay_request_id,
            sample={"sequence": 1, "recorded_at": self.now - timedelta(seconds=10),
                    "latitude": -37.8, "longitude": 144.9, "accuracy_m": 5,
                    "is_simulated": False}, now=self.now,
        )
        self.assertEqual(replayed.pk, check_in.pk)
        CheckIn.objects.filter(pk=replayed.pk).update(
            verified_seconds=600, ready_at=self.now - timedelta(seconds=1),
        )
        replay_walk = Walk.objects.create(
            owner=self.owner, request_id=replay_request_id,
            request_fingerprint="settled-history-replay",
            started_at=replay_context.started_at, ended_at=self.now,
            point_date=local_date(self.now), distance_m=0, active_seconds=0,
        )
        settle_walk_checkins(replay_walk, now=self.now)

        replayed.refresh_from_db()
        self.assertEqual(replayed.point_entry_id, entry.pk)
        self.assertEqual(get_balance(self.owner), before_balance)
        self.assertEqual(
            set(PointEntry.objects.filter(user=self.owner).values_list("pk", flat=True)),
            before_entries,
        )

    def test_near_midnight_reset_replay_cannot_mint_next_day_points(self):
        check_in, venue, entry = self.check_in(self.owner, "midnight", source_style="current")
        self.credit(self.owner, 60, "walk-midnight-cap", PointEntry.EarnCategory.WALK, "test-only")
        reset_now = self.now.replace(hour=23, minute=55)
        midnight = next_midnight(reset_now)
        before_balance = get_balance(self.owner)
        before_entries = set(PointEntry.objects.filter(user=self.owner).values_list("pk", flat=True))

        with patch("quests.debug_reset.timezone.now", return_value=reset_now):
            response = self.client.post("/api/quests/reset", {}, format="json")
        self.assertEqual(response.status_code, 200)

        request_id = uuid4()
        context = CheckInWalk.objects.create(
            owner=self.owner, request_id=request_id,
            started_at=reset_now - timedelta(minutes=20), state=CheckInWalk.State.RECORDING,
        )
        replayed = start_checkin(
            owner=self.owner, venue_id=venue.pk, walk_request_id=request_id,
            sample={"sequence": 1, "recorded_at": reset_now - timedelta(seconds=10),
                    "latitude": -37.8, "longitude": 144.9, "accuracy_m": 5,
                    "is_simulated": False}, now=reset_now,
        )
        self.assertEqual(replayed.expires_at, context.started_at + MAX_WALK_AGE)
        for index in range(1, 11):
            sample_now = reset_now + timedelta(seconds=60 * index)
            replayed = report_checkin_location(
                owner=self.owner, checkin_id=replayed.pk,
                sample={"sequence": index + 1, "recorded_at": sample_now,
                        "latitude": -37.8, "longitude": 144.9, "accuracy_m": 5,
                        "is_simulated": False}, now=sample_now,
            )
            if index == 6:
                self.assertGreater(sample_now, midnight)
                with patch("checkins.services.timezone.now", return_value=sample_now), \
                        patch("checkins.views.local_date", return_value=local_date(sample_now)):
                    progress = self.client.get("/api/check-ins")
                    venues = {item["id"]: item for item in self.client.get("/api/venues").data}
                active = next(
                    item for item in progress.data["items"]
                    if item["id"] == str(replayed.attempt_id)
                )
                self.assertTrue(active["is_replayable"])
                self.assertEqual(venues[venue.pk]["checkin_status"], "IN_PROGRESS")
                self.assertTrue(venues[venue.pk]["check_in"]["is_replayable"])

        self.assertEqual(replayed.verified_seconds, 600)
        self.assertEqual(replayed.status, "READY")
        finished_at = reset_now + timedelta(minutes=10)
        walk = Walk.objects.create(
            owner=self.owner, request_id=request_id, request_fingerprint="midnight-replay",
            started_at=context.started_at, ended_at=finished_at,
            point_date=local_date(finished_at), distance_m=0, active_seconds=0,
        )
        settle_walk_checkins(walk, now=finished_at)

        replayed.refresh_from_db()
        self.assertEqual(replayed.point_entry_id, entry.pk)
        self.assertEqual(replayed.local_date, local_date(reset_now))
        self.assertEqual(get_balance(self.owner), before_balance)
        self.assertEqual(
            set(PointEntry.objects.filter(user=self.owner).values_list("pk", flat=True)),
            before_entries,
        )
        self.assertFalse(PointEntry.objects.filter(
            user=self.owner, earn_category=PointEntry.EarnCategory.CHECK_IN,
            earned_on=local_date(finished_at),
        ).exists())

    def test_old_day_replay_does_not_block_same_walk_new_day_category_reward(self):
        old_check_in, old_venue, old_entry = self.check_in(
            self.owner, "old-day-same-category", source_style="current",
        )
        reset_now = self.now.replace(hour=23, minute=55)
        midnight = next_midnight(reset_now)
        with patch("quests.debug_reset.timezone.now", return_value=reset_now):
            response = self.client.post("/api/quests/reset", {}, format="json")
        self.assertEqual(response.status_code, 200)

        request_id = uuid4()
        context = CheckInWalk.objects.create(
            owner=self.owner,
            request_id=request_id,
            started_at=reset_now - timedelta(minutes=20),
            state=CheckInWalk.State.RECORDING,
        )
        replayed = start_checkin(
            owner=self.owner,
            venue_id=old_venue.pk,
            walk_request_id=request_id,
            sample={
                "sequence": 1,
                "recorded_at": reset_now - timedelta(seconds=10),
                "latitude": -37.8,
                "longitude": 144.9,
                "accuracy_m": 5,
                "is_simulated": False,
            },
            now=reset_now,
        )
        CheckIn.objects.filter(pk=replayed.pk).update(
            verified_seconds=600,
            ready_at=reset_now,
        )

        new_venue = Venue.objects.create(
            name="New-day cafe",
            kind=Venue.Kind.CAFE,
            latitude=-37.81,
            longitude=144.91,
            checkin_enabled=True,
            is_partner=True,
        )
        new_started_at = midnight + timedelta(seconds=30)
        new_ready_at = new_started_at + timedelta(minutes=10)
        new_check_in = CheckIn.objects.create(
            owner=self.owner,
            walk_context=context,
            venue=new_venue,
            venue_name_snapshot=new_venue.name,
            local_date=local_date(new_ready_at),
            category_slot=Venue.Kind.CAFE,
            required_seconds=600,
            verified_seconds=600,
            center_latitude=new_venue.latitude,
            center_longitude=new_venue.longitude,
            started_at=new_started_at,
            ready_at=new_ready_at,
            expires_at=context.started_at + MAX_WALK_AGE,
        )
        walk = Walk.objects.create(
            owner=self.owner,
            request_id=request_id,
            request_fingerprint="old-and-new-day-category",
            started_at=context.started_at,
            ended_at=new_ready_at + timedelta(minutes=1),
            point_date=local_date(new_ready_at),
            distance_m=0,
            active_seconds=0,
        )
        before_balance = get_balance(self.owner)
        before_entries = set(
            PointEntry.objects.filter(user=self.owner).values_list("pk", flat=True)
        )

        settle_walk_checkins(walk, now=walk.ended_at)

        replayed.refresh_from_db()
        new_check_in.refresh_from_db()
        self.assertEqual(replayed.point_entry_id, old_entry.pk)
        self.assertEqual(replayed.local_date, local_date(reset_now))
        self.assertIsNotNone(new_check_in.point_entry_id)
        self.assertNotEqual(new_check_in.point_entry_id, old_entry.pk)
        self.assertEqual(new_check_in.point_entry.earned_on, walk.point_date)
        self.assertEqual(
            new_check_in.point_entry.source_reference,
            f"venue-walk:{self.owner.pk}:{walk.point_date}:{Venue.Kind.CAFE}",
        )
        self.assertEqual(get_balance(self.owner), before_balance + new_check_in.promised_points)
        self.assertEqual(
            set(PointEntry.objects.filter(user=self.owner).values_list("pk", flat=True)),
            before_entries | {new_check_in.point_entry_id},
        )

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
