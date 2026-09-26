import base64
import tempfile
from concurrent.futures import ThreadPoolExecutor
from datetime import date, datetime, timedelta, timezone as dt_timezone
from unittest.mock import patch
from unittest import skipUnless
from threading import Barrier
from uuid import uuid4

from django.contrib.auth import get_user_model
from django.db import IntegrityError, close_old_connections, connection, transaction
from django.test import TransactionTestCase, override_settings
from rest_framework.test import APIClient, APITestCase

from dogs.models import Breed, Dog
from evidence.models import DocumentEntitlement, DocumentSubmission, EvidenceFingerprint
from evidence.serializers import DocumentRequestSerializer
from evidence.services import submit_document
from evidence.tests.test_documents import pdf_file
from rewards.models import PointEntry
from rewards.policy import MELBOURNE

User = get_user_model()


@override_settings(PASSWORD_HASHERS=["django.contrib.auth.hashers.MD5PasswordHasher"])
class CouncilAnnualTests(APITestCase):
    @classmethod
    def setUpTestData(cls):
        cls.owner = User.objects.create_user(email="annual-council@example.com", display_name="Owner")
        cls.other = User.objects.create_user(email="annual-council-other@example.com", display_name="Other")
        breed = Breed.objects.create(name="Annual council breed", energy_level="LOW", default_size="SMALL")
        cls.dog = Dog.objects.create(owner=cls.owner, name="Coco", breed=breed, age_months=12, size="SMALL", is_brachycephalic=False)

    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.settings = override_settings(PRIVATE_MEDIA_ROOT=directory.name)
        self.settings.enable()
        self.addCleanup(self.settings.disable)
        self.now = datetime(2026, 9, 27, 12, tzinfo=MELBOURNE)
        clock = patch("django.utils.timezone.now", side_effect=lambda: self.now)
        clock.start()
        self.addCleanup(clock.stop)
        self.client.force_authenticate(self.owner)

    def payload(self, **changes):
        data = {"request_id": str(uuid4()), "dog_id": self.dog.pk, "kind": "COUNCIL_REGISTRATION",
                "registration_number": "00042", "council_name": "City of Melbourne",
                "registration_year": self.now.year + ((self.now.month, self.now.day) >= (4, 10))}
        data.update(changes)
        return data

    def upload_payload(self):
        return {"request_id": str(uuid4()), "dog_id": self.dog.pk, "kind": "COUNCIL_REGISTRATION",
                "filename": "registration.pdf", "file_base64": base64.b64encode(pdf_file()).decode()}

    def submit(self, payload=None):
        return self.client.post("/api/quests/documents", payload or self.payload(), format="json")

    def collect(self, submitted):
        return self.client.post(f"/api/quests/documents/entitlements/{submitted.data['entitlement_id']}/collect", {}, format="json")

    def tasks(self):
        response = self.client.get("/api/quests")
        self.assertEqual(response.status_code, 200)
        return [row for row in response.data["tasks"] if row["kind"] == "COUNCIL_REGISTRATION"]

    def eligibility(self):
        return next(row for row in self.client.get("/api/quests/documents").data["eligibility"] if row["kind"] == "COUNCIL_REGISTRATION")

    def test_each_registration_year_earns_once_and_same_number_can_be_renewed(self):
        first = self.submit()
        self.assertEqual(first.status_code, 201)
        self.assertEqual(first.data["submission"]["reward_registration_year"], 2027)
        self.assertEqual(DocumentEntitlement.objects.get().entitlement_key, "council:2027")
        self.assertEqual(self.collect(first).data["registration_year"], 2027)
        repeated = self.submit()
        self.assertEqual(repeated.data["entitlement_id"], first.data["entitlement_id"])
        self.assertFalse(self.collect(repeated).data["created"])
        self.now = datetime(2027, 4, 10, 0, 0, tzinfo=MELBOURNE)
        self.assertEqual([(row["id"], row["status"]) for row in self.tasks()], [(f"council:{self.dog.pk}:2028", "IN_PROGRESS")])
        self.assertTrue(self.eligibility()["can_earn"])
        self.assertEqual(self.eligibility()["registration_year"], 2028)
        second = self.submit()
        self.assertNotEqual(second.data["entitlement_id"], first.data["entitlement_id"])
        collected = self.collect(second)
        self.assertEqual((collected.data["points"], collected.data["registration_year"]), (300, 2028))
        self.assertEqual(list(PointEntry.objects.order_by("id").values_list("amount", flat=True)), [300, 300])

    def test_old_pending_does_not_hide_new_year_and_both_remain_collectible(self):
        first = self.submit()
        old_receipt = first.data.copy()
        self.now = datetime(2027, 4, 10, 12, tzinfo=MELBOURNE)
        self.assertEqual({(row["registration_year"], row["status"]) for row in self.tasks()}, {(2027, "READY"), (2028, "IN_PROGRESS")})
        eligibility = self.eligibility()
        self.assertEqual((eligibility["pending_count"], eligibility["awards_count"], eligibility["can_earn"]), (0, 0, True))
        second = self.submit()
        self.assertEqual({(row["registration_year"], row["status"]) for row in self.tasks()}, {(2027, "READY"), (2028, "READY")})
        self.assertEqual(self.collect(first).data["points"], 300)
        self.assertEqual(self.collect(second).data["points"], 300)
        self.assertFalse(self.collect(first).data["created"])
        self.assertEqual(DocumentSubmission.objects.get(pk=first.data["submission"]["id"]).response_snapshot, old_receipt)
        self.assertEqual(PointEntry.objects.count(), 2)

    @override_settings(TIME_ZONE="UTC")
    def test_april_ten_rollover_is_melbourne_and_original_request_replay_is_immutable(self):
        self.now = datetime(2027, 4, 9, 13, 59, tzinfo=dt_timezone.utc)
        # payload generation here uses the intended ending year explicitly.
        payload = self.payload(registration_year=2027)
        first = self.submit(payload)
        self.assertEqual(first.status_code, 201)
        self.now += timedelta(minutes=1)
        replay = self.submit(payload)
        self.assertEqual((replay.status_code, replay.data), (200, first.data))
        stale = self.submit({**payload, "request_id": str(uuid4())})
        self.assertEqual(stale.status_code, 400)
        self.assertEqual(self.submit(self.payload(registration_year=2028)).status_code, 201)
        self.assertEqual(set(DocumentEntitlement.objects.values_list("registration_year", flat=True)), {2027, 2028})

    def test_upload_reward_year_is_server_current_and_manual_document_year_stays_unknown(self):
        response = self.submit(self.upload_payload())
        self.assertEqual(response.status_code, 201)
        submission = response.data["submission"]
        self.assertIsNone(submission["registration_year"])
        self.assertEqual(submission["reward_registration_year"], 2027)
        self.assertEqual(submission["status"], "SELF_REPORTED")
        self.assertEqual(self.client.get("/api/quests/documents").data["entitlements"][0]["registration_year"], 2027)

    def test_typed_request_cannot_cross_rollover_while_waiting_for_transaction_lock(self):
        self.now = datetime(2027, 4, 9, 23, 59, tzinfo=MELBOURNE)
        serializer = DocumentRequestSerializer(data=self.payload(), context={"owner": self.owner})
        serializer.is_valid(raise_exception=True)
        self.now += timedelta(minutes=1)
        from rest_framework.exceptions import ValidationError
        with self.assertRaises(ValidationError):
            submit_document(owner=self.owner, data=serializer.validated_data)
        self.assertFalse(DocumentEntitlement.objects.exists())
        self.assertFalse(DocumentSubmission.objects.exists())
        self.assertFalse(PointEntry.objects.exists())

    def test_upload_crossing_rollover_uses_locked_current_reward_year(self):
        self.now = datetime(2027, 4, 9, 23, 59, tzinfo=MELBOURNE)
        serializer = DocumentRequestSerializer(data=self.upload_payload(), context={"owner": self.owner})
        serializer.is_valid(raise_exception=True)
        self.now += timedelta(minutes=1)
        response, created = submit_document(owner=self.owner, data=serializer.validated_data)
        self.assertTrue(created)
        self.assertEqual(response["submission"]["reward_registration_year"], 2028)
        self.assertIsNone(response["submission"]["registration_year"])

    def test_same_file_is_rejected_across_years_even_after_owner_transfer(self):
        first = self.submit(self.upload_payload())
        self.assertEqual(first.status_code, 201)
        self.collect(first)
        self.now = datetime(2027, 4, 10, 12, tzinfo=MELBOURNE)
        self.assertEqual(self.submit(self.upload_payload()).status_code, 400)
        self.dog.owner = self.other
        self.dog.save(update_fields=["owner"])
        self.client.force_authenticate(self.other)
        self.assertEqual(self.submit(self.upload_payload()).status_code, 400)
        self.assertEqual(DocumentEntitlement.objects.count(), 1)
        self.assertEqual(EvidenceFingerprint.objects.count(), 1)
        self.assertEqual(DocumentSubmission.objects.count(), 1)
        self.assertEqual(PointEntry.objects.count(), 1)

    def test_transfer_does_not_reset_same_year_but_next_year_belongs_to_current_owner(self):
        first = self.submit()
        self.collect(first)
        self.dog.owner = self.other
        self.dog.save(update_fields=["owner"])
        self.client.force_authenticate(self.other)
        same = self.submit()
        self.assertEqual(same.data["entitlement_id"], first.data["entitlement_id"])
        self.assertEqual(self.collect(same).status_code, 404)
        self.now = datetime(2027, 4, 10, 12, tzinfo=MELBOURNE)
        next_year = self.submit()
        self.assertEqual(self.collect(next_year).status_code, 200)
        self.assertEqual(list(PointEntry.objects.order_by("id").values_list("user_id", flat=True)), [self.owner.pk, self.other.pk])
        self.client.force_authenticate(self.owner)
        self.assertFalse(self.collect(first).data["created"])

    def test_transfer_of_unclaimed_current_year_requires_current_owner_submission(self):
        first = self.submit()
        self.dog.owner = self.other
        self.dog.save(update_fields=["owner"])
        self.assertEqual(self.collect(first).status_code, 404)
        self.client.force_authenticate(self.other)
        self.assertEqual(self.collect(first).status_code, 404)
        submitted = self.submit()
        self.assertEqual(submitted.data["entitlement_id"], first.data["entitlement_id"])
        self.assertEqual(self.collect(submitted).status_code, 200)
        self.assertEqual(PointEntry.objects.get().user_id, self.other.pk)

    def test_held_current_year_hides_task_without_blocking_new_year(self):
        first = self.submit()
        entitlement = DocumentEntitlement.objects.get(pk=first.data["entitlement_id"])
        for status in ("ON_HOLD", "REJECTED"):
            with self.subTest(status=status):
                entitlement.eligibility_status, entitlement.eligibility_reason = status, "Review outcome"
                entitlement.save(update_fields=["eligibility_status", "eligibility_reason"])
                self.assertEqual(self.tasks(), [])
                self.assertEqual(self.collect(first).status_code, 400)
        self.now = datetime(2027, 4, 10, 12, tzinfo=MELBOURNE)
        self.assertEqual([(row["registration_year"], row["status"]) for row in self.tasks()], [(2028, "IN_PROGRESS")])
        self.assertEqual(self.collect(self.submit()).status_code, 200)

    def test_year_shape_and_per_dog_year_uniqueness_are_database_enforced(self):
        self.submit()
        with transaction.atomic(), self.assertRaises(IntegrityError):
            DocumentEntitlement.objects.create(owner=self.owner, dog=self.dog, dog_id_snapshot=self.dog.pk,
                kind="COUNCIL_REGISTRATION", entitlement_key="different-key", registration_year=2027, promised_points=300)
        with transaction.atomic(), self.assertRaises(IntegrityError):
            DocumentEntitlement.objects.create(owner=self.owner, dog=self.dog, dog_id_snapshot=self.dog.pk,
                kind="COUNCIL_REGISTRATION", entitlement_key="missing-year", promised_points=300)
        with transaction.atomic(), self.assertRaises(IntegrityError):
            DocumentEntitlement.objects.create(owner=self.owner, dog=self.dog, dog_id_snapshot=self.dog.pk,
                kind="MICROCHIP_REGISTRATION", entitlement_key="wrong-year", registration_year=2027, promised_points=300)

    def test_migration_preflight_reports_conflicting_original_years_without_modifying_history(self):
        from importlib import import_module
        from types import SimpleNamespace
        from django.apps import apps

        self.submit()
        self.now = datetime(2027, 4, 10, 12, tzinfo=MELBOURNE)
        second = self.submit()
        # Represent inconsistent imported historical metadata without violating
        # the current database's durable entitlement uniqueness constraint.
        DocumentSubmission.objects.filter(pk=second.data["submission"]["id"]).update(registration_year=2027)
        before = list(DocumentEntitlement.objects.order_by("id").values())
        migration = import_module("evidence.migrations.0005_council_annual_rewards")
        with self.assertRaisesMessage(RuntimeError, "conflicting or invalid original registration year"):
            migration.preflight_council_years(apps, SimpleNamespace(connection=connection))
        self.assertEqual(list(DocumentEntitlement.objects.order_by("id").values()), before)
        self.assertEqual(PointEntry.objects.count(), 0)


@skipUnless(connection.vendor == "mysql", "Requires MySQL row-lock semantics")
class CouncilAnnualConcurrencyTests(TransactionTestCase):
    def test_parallel_new_year_submissions_share_one_reward_despite_old_pending_entitlement(self):
        from quests.models import QuestDefinition

        QuestDefinition.objects.update_or_create(code="DOCUMENTS", defaults={"title": "Documents", "is_enabled": True})
        owner = User.objects.create_user(email="annual-concurrent@example.com", display_name="Owner")
        breed = Breed.objects.create(name="Annual concurrent breed", energy_level="LOW", default_size="SMALL")
        dog = Dog.objects.create(owner=owner, name="Coco", breed=breed, age_months=12, size="SMALL", is_brachycephalic=False)
        old = DocumentEntitlement.objects.create(owner=owner, dog=dog, dog_id_snapshot=dog.pk,
            kind="COUNCIL_REGISTRATION", entitlement_key="council:2027", registration_year=2027, promised_points=300)
        now = datetime(2027, 4, 10, 12, tzinfo=MELBOURNE)
        barrier = Barrier(2)

        def submit_and_collect(_):
            close_old_connections()
            try:
                client = APIClient()
                client.force_authenticate(owner)
                barrier.wait(timeout=10)
                submitted = client.post("/api/quests/documents", {
                    "request_id": str(uuid4()), "dog_id": dog.pk, "kind": "COUNCIL_REGISTRATION",
                    "registration_number": "00042", "council_name": "City of Melbourne", "registration_year": 2028,
                }, format="json")
                self.assertEqual(submitted.status_code, 201)
                return client.post(f"/api/quests/documents/entitlements/{submitted.data['entitlement_id']}/collect", {}, format="json")
            finally:
                close_old_connections()

        with patch("django.utils.timezone.now", return_value=now), ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(submit_and_collect, range(2)))
        self.assertEqual([result.status_code for result in results], [200, 200])
        self.assertEqual(sorted(result.data["created"] for result in results), [False, True])
        self.assertEqual({result.data["registration_year"] for result in results}, {2028})
        self.assertEqual(DocumentEntitlement.objects.count(), 2)
        self.assertEqual(PointEntry.objects.count(), 1)
        old.refresh_from_db()
        self.assertIsNone(old.point_entry_id)


class CouncilAnnualMigrationTests(TransactionTestCase):
    def test_original_submission_year_and_melbourne_fallback_preserve_all_history(self):
        from django.db.migrations.executor import MigrationExecutor

        executor = MigrationExecutor(connection)
        latest = executor.loader.graph.leaf_nodes()
        before = [("evidence", "0004_registration_details") if app == "evidence" else (app, name)
                  for app, name in latest]
        try:
            executor.migrate(before)
            apps = executor.loader.project_state(before).apps
            owner = apps.get_model("accounts", "User").objects.create(email="annual-migration@example.com", display_name="Legacy")
            Entitlement = apps.get_model("evidence", "DocumentEntitlement")
            Submission = apps.get_model("evidence", "DocumentSubmission")
            Entry = apps.get_model("rewards", "PointEntry")
            entry = Entry.objects.create(user_id=owner.pk, type="EARN", amount=275, remaining_points=123,
                source_reference="preserved-council-credit", expires_at=datetime(2028, 1, 1, tzinfo=dt_timezone.utc))
            before_boundary = datetime(2025, 4, 9, 13, 59, tzinfo=dt_timezone.utc)
            after_boundary = before_boundary + timedelta(minutes=1)
            later = datetime(2026, 9, 27, 1, tzinfo=dt_timezone.utc)
            expected = {}

            def entitlement(snapshot, created, *, paid=False, kind="COUNCIL_REGISTRATION"):
                row = Entitlement.objects.create(owner_id=owner.pk, dog_id_snapshot=snapshot, kind=kind,
                    entitlement_key="lifetime", promised_points=275 if paid else 300,
                    point_entry_id=entry.pk if paid else None, collected_at=created if paid else None)
                Entitlement.objects.filter(pk=row.pk).update(created_at=created)
                return row

            def submission(row, at, year):
                record = Submission.objects.create(owner_id=owner.pk, dog_id_snapshot=row.dog_id_snapshot,
                    dog_name_snapshot="Historical dog", kind=row.kind, entitlement_id=row.pk,
                    request_id=uuid4(), request_fingerprint="a" * 64, registration_number="00042",
                    registration_year=year, awarded_points=275 if row.point_entry_id else 0,
                    response_snapshot={"original": str(uuid4()), "balance": 456},
                    filename="old-registration.pdf", file="documents/original.pdf", file_sha256="b" * 64)
                Submission.objects.filter(pk=record.pk).update(submitted_at=at)

            explicit = entitlement(710, later, paid=True)
            submission(explicit, before_boundary, 2025)
            submission(explicit, later, 2027)
            expected[explicit.pk] = 2025
            upload = entitlement(711, later)
            submission(upload, before_boundary, None)
            submission(upload, later, 2027)
            expected[upload.pk] = 2025
            after = entitlement(712, later)
            submission(after, after_boundary, None)
            expected[after.pk] = 2026
            orphan = entitlement(713, after_boundary)
            expected[orphan.pk] = 2026
            microchip = entitlement(714, before_boundary, kind="MICROCHIP_REGISTRATION")
            expected[microchip.pk] = None
            old_entitlements = list(Entitlement.objects.order_by("id").values())
            old_submissions = list(Submission.objects.order_by("id").values())
            old_entries = list(Entry.objects.order_by("id").values())

            MigrationExecutor(connection).migrate(latest)
            actual = list(DocumentEntitlement.objects.order_by("id").values())
            for row in actual:
                self.assertEqual(row.pop("registration_year"), expected[row["id"]])
            self.assertEqual(actual, old_entitlements)
            self.assertEqual(list(DocumentSubmission.objects.order_by("id").values()), old_submissions)
            self.assertEqual(list(PointEntry.objects.order_by("id").values()), old_entries)
        finally:
            MigrationExecutor(connection).migrate(latest)
