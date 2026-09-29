import base64
import tempfile
from concurrent.futures import ThreadPoolExecutor
from datetime import date, datetime, timedelta, timezone as dt_timezone
from unittest.mock import patch
from unittest import skipUnless
from threading import Barrier
from uuid import uuid4

from django.contrib.auth import get_user_model
from django.db import close_old_connections, connection
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
class CouncilExpiryTests(APITestCase):
    @classmethod
    def setUpTestData(cls):
        cls.owner = User.objects.create_user(email="expiry-council@example.com", display_name="Owner")
        cls.other = User.objects.create_user(email="expiry-other@example.com", display_name="Other")
        breed = Breed.objects.create(name="Expiry breed", energy_level="LOW", default_size="SMALL")
        cls.dog = Dog.objects.create(owner=cls.owner, name="Coco", breed=breed, age_months=12, size="SMALL", is_brachycephalic=False)

    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        settings = override_settings(PRIVATE_MEDIA_ROOT=directory.name)
        settings.enable()
        self.addCleanup(settings.disable)
        self.now = datetime(2026, 9, 27, 12, tzinfo=MELBOURNE)
        clock = patch("django.utils.timezone.now", side_effect=lambda: self.now)
        clock.start()
        self.addCleanup(clock.stop)
        self.client.force_authenticate(self.owner)

    def payload(self, **changes):
        data = {"request_id": str(uuid4()), "dog_id": self.dog.pk, "kind": "COUNCIL_REGISTRATION",
                "registration_number": "00042", "council_name": "City of Melbourne", "valid_to": "2027-06-15"}
        data.update(changes)
        return data

    def upload_payload(self, **changes):
        return self.payload(filename="registration.pdf", file_base64=base64.b64encode(pdf_file()).decode(), **changes)

    def submit(self, payload=None):
        return self.client.post("/api/quests/documents", payload or self.payload(), format="json")

    def collect(self, submitted):
        return self.client.post(f"/api/quests/documents/entitlements/{submitted.data['entitlement_id']}/collect", {}, format="json")

    def tasks(self):
        response = self.client.get("/api/quests")
        self.assertEqual(response.status_code, 200)
        return [row for row in response.data["tasks"] if row["kind"] == "COUNCIL_REGISTRATION"]

    def test_confirmed_expiry_blocks_new_reward_until_day_after_expiry(self):
        first = self.submit()
        self.assertEqual(first.status_code, 201)
        self.assertEqual(DocumentEntitlement.objects.get().entitlement_key, "expiry:2027-06-15")
        self.assertEqual(self.collect(first).data["valid_to"], "2027-06-15")
        repeat = self.submit()
        self.assertEqual(repeat.data["entitlement_id"], first.data["entitlement_id"])
        self.assertFalse(self.collect(repeat).data["created"])
        for day in (datetime(2027, 4, 10, 12, tzinfo=MELBOURNE), datetime(2027, 6, 15, 23, 59, tzinfo=MELBOURNE)):
            self.now = day
            self.assertEqual(self.tasks(), [])
            self.assertEqual(self.submit(self.payload(valid_to="2028-06-15")).status_code, 400)
        self.now += timedelta(minutes=1)
        self.assertEqual([(t["id"], t["status"]) for t in self.tasks()], [(f"council:{self.dog.pk}:new", "IN_PROGRESS")])
        second = self.submit(self.payload(valid_to="2028-06-15"))
        self.assertNotEqual(second.data["entitlement_id"], first.data["entitlement_id"])
        self.assertEqual(self.collect(second).status_code, 200)
        self.assertEqual(list(PointEntry.objects.values_list("amount", flat=True)), [300, 300])

    @override_settings(TIME_ZONE="UTC")
    def test_expired_pending_disappears_and_cannot_collect_but_receipt_replays(self):
        self.now = datetime(2027, 6, 15, 13, 59, tzinfo=dt_timezone.utc)
        payload = self.payload()
        first = self.submit(payload)
        self.assertEqual(first.status_code, 201)
        self.assertEqual(self.tasks()[0]["status"], "READY")
        self.now += timedelta(minutes=1)
        self.assertEqual([t["status"] for t in self.tasks()], ["IN_PROGRESS"])
        denied = self.collect(first)
        self.assertEqual((denied.status_code, denied.data["code"]), (400, "EXPIRED"))
        history = self.client.get("/api/quests/documents").data
        self.assertEqual(history["submissions"][0]["reward_status"], "EXPIRED")
        self.assertFalse(history["entitlements"][0]["can_collect"])
        replay = self.submit(payload)
        self.assertEqual((replay.status_code, replay.data), (200, first.data))
        self.assertEqual(self.submit(self.payload()).status_code, 400)
        self.assertEqual(self.submit(self.payload(valid_to="2028-06-15")).status_code, 201)
        self.assertEqual(len(self.tasks()), 1)
        self.assertFalse(PointEntry.objects.exists())

    def test_submission_waiting_for_lock_rechecks_expiry_and_route(self):
        self.now = datetime(2027, 6, 15, 23, 59, tzinfo=MELBOURNE)
        first = self.submit()
        serializer = DocumentRequestSerializer(data=self.payload(expected_entitlement_id=first.data["entitlement_id"]), context={"owner": self.owner})
        serializer.is_valid(raise_exception=True)
        self.now += timedelta(minutes=1)
        from evidence.services import RequestConflict
        with self.assertRaises(RequestConflict):
            submit_document(owner=self.owner, data=serializer.validated_data)
        self.assertEqual(DocumentSubmission.objects.count(), 1)
        self.assertEqual(self.submit(self.payload(valid_to="2028-06-15", expected_entitlement_id=first.data["entitlement_id"])).status_code, 409)

    def test_unknown_paid_expiry_updates_existing_record_once_without_new_points(self):
        first = self.submit()
        self.collect(first)
        row = DocumentEntitlement.objects.get()
        DocumentEntitlement.objects.filter(pk=row.pk).update(valid_to=None, registration_year=2027)
        self.now += timedelta(days=1)
        task = self.tasks()[0]
        self.assertEqual((task["status"], task["reward_points"], task["needs_expiry"]), ("IN_PROGRESS", 0, True))
        snapshot = DocumentSubmission.objects.first().response_snapshot
        updated = self.submit(self.payload(valid_to="2026-09-26", expected_entitlement_id=row.pk))
        self.assertEqual(updated.status_code, 201)
        self.assertEqual(updated.data["entitlement_id"], row.pk)
        self.assertEqual(updated.data["awarded_points"], 0)
        self.assertEqual(DocumentSubmission.objects.get(pk=first.data["submission"]["id"]).response_snapshot, snapshot)
        self.assertEqual(PointEntry.objects.count(), 1)
        self.assertEqual(self.tasks()[0]["id"], f"council:{self.dog.pk}:new")
        self.assertEqual(self.submit(self.payload(valid_to="2027-09-26")).status_code, 201)
        self.assertEqual(PointEntry.objects.count(), 1)

    def test_unknown_unpaid_expiry_must_be_bound_before_collecting(self):
        first = self.submit()
        DocumentEntitlement.objects.update(valid_to=None)
        denied = self.collect(first)
        self.assertEqual((denied.status_code, denied.data["code"]), (400, "EXPIRY_REQUIRED"))
        self.assertEqual(self.tasks()[0]["status"], "IN_PROGRESS")
        updated = self.submit(self.payload(expected_entitlement_id=first.data["entitlement_id"]))
        self.assertEqual(updated.data["entitlement_id"], first.data["entitlement_id"])
        self.assertEqual(self.collect(updated).status_code, 200)
        self.assertEqual(self.submit(self.payload(valid_to="2028-06-15")).status_code, 400)
        self.assertEqual(DocumentEntitlement.objects.count(), 1)

    def test_legacy_superseded_pending_records_are_not_collectible_or_ready(self):
        first = self.submit()
        self.now += timedelta(seconds=1)
        newer = DocumentEntitlement.objects.create(owner=self.owner, dog=self.dog, dog_id_snapshot=self.dog.pk,
            kind="COUNCIL_REGISTRATION", entitlement_key="legacy:newer", registration_year=2028, promised_points=300,
            valid_to=date(2027, 7, 15))
        submitted = self.submit(self.payload(valid_to="2027-07-15", expected_entitlement_id=newer.pk))
        self.assertEqual(submitted.status_code, 201)
        self.assertEqual(self.collect(first).data["code"], "EXPIRED")
        self.assertEqual([t["entitlement_id"] for t in self.tasks()], [newer.pk])
        statuses = {s["id"]: s["reward_status"] for s in self.client.get("/api/quests/documents").data["submissions"]}
        self.assertEqual(statuses[first.data["submission"]["id"]], "EXPIRED")
        self.assertEqual(self.collect(submitted).status_code, 200)
        self.assertEqual(PointEntry.objects.count(), 1)

    def test_paid_unknown_blocks_newer_legacy_pending_until_confirmed_expiry(self):
        first = self.submit()
        self.collect(first)
        DocumentEntitlement.objects.update(valid_to=None)
        self.now += timedelta(seconds=1)
        newer = DocumentEntitlement.objects.create(owner=self.owner, dog=self.dog, dog_id_snapshot=self.dog.pk,
            kind="COUNCIL_REGISTRATION", entitlement_key="legacy:newer", promised_points=300, valid_to=date(2028, 6, 15))
        self.assertEqual(self.tasks()[0]["entitlement_id"], first.data["entitlement_id"])
        self.assertEqual(self.submit(self.payload(valid_to="2028-06-15", expected_entitlement_id=newer.pk)).status_code, 409)
        self.submit(self.payload(valid_to="2026-09-26", expected_entitlement_id=first.data["entitlement_id"]))
        self.assertEqual(self.tasks()[0]["entitlement_id"], newer.pk)
        self.assertEqual(PointEntry.objects.count(), 1)

    def test_same_file_cannot_support_renewal_even_after_transfer(self):
        first = self.submit(self.upload_payload())
        self.assertEqual(first.status_code, 201)
        self.collect(first)
        self.now = datetime(2027, 6, 16, 12, tzinfo=MELBOURNE)
        self.assertEqual(self.submit(self.upload_payload(valid_to="2028-06-15")).status_code, 400)
        self.dog.owner = self.other
        self.dog.save(update_fields=["owner"])
        self.client.force_authenticate(self.other)
        self.assertEqual(self.submit(self.upload_payload(valid_to="2028-06-15")).status_code, 400)
        self.assertEqual((DocumentEntitlement.objects.count(), DocumentSubmission.objects.count(), PointEntry.objects.count()), (1, 1, 1))

    def test_transfer_preserves_current_reward_and_renewal_belongs_to_current_owner(self):
        first = self.submit()
        self.collect(first)
        self.dog.owner = self.other
        self.dog.save(update_fields=["owner"])
        self.client.force_authenticate(self.other)
        same = self.submit()
        self.assertEqual(same.data["entitlement_id"], first.data["entitlement_id"])
        self.assertEqual(self.collect(same).status_code, 404)
        self.now = datetime(2027, 6, 16, 12, tzinfo=MELBOURNE)
        self.assertEqual(self.collect(self.submit(self.payload(valid_to="2028-06-15"))).status_code, 200)
        self.assertEqual(list(PointEntry.objects.order_by("id").values_list("user_id", flat=True)), [self.owner.pk, self.other.pk])
        self.client.force_authenticate(self.owner)
        self.assertFalse(self.collect(first).data["created"])

    def test_hold_blocks_collection_until_expiry_and_cannot_be_bypassed_by_edit(self):
        first = self.submit()
        DocumentEntitlement.objects.update(eligibility_status="ON_HOLD", eligibility_reason="Review")
        self.assertEqual(self.tasks(), [])
        self.assertEqual(self.collect(first).status_code, 400)
        self.assertEqual(self.submit(self.payload(valid_to="2028-06-15")).status_code, 400)
        self.now = datetime(2027, 6, 16, 12, tzinfo=MELBOURNE)
        self.assertEqual(self.tasks()[0]["status"], "IN_PROGRESS")

    def test_bounded_reading_suggestions_remain_separate_from_confirmed_details(self):
        reading = {"source": "MIXED", "pages_read": 2, "candidates": {
            "valid_to": [{"value": "2027-06-16", "page": 2, "source": "APPLE_VISION"}],
            "registration_number": [{"value": "0042", "page": 1, "source": "PDF_TEXT"}]}}
        response = self.submit(self.upload_payload(document_reading=reading, document_dog_name="Printed Coco"))
        self.assertEqual(response.status_code, 201)
        row = DocumentSubmission.objects.get()
        self.assertEqual(row.document_reading, reading)
        self.assertEqual((row.registration_number, row.valid_to, row.document_dog_name), ("00042", date(2027, 6, 15), "Printed Coco"))
        self.assertEqual(row.status, "SELF_REPORTED")
        self.assertEqual(self.submit(self.payload(document_reading=reading)).status_code, 400)
        for invalid in ({**reading, "raw_text": "not stored"}, {**reading, "pages_read": 21},
                        {**reading, "source": []},
                        {**reading, "candidates": {"valid_to": [{"value": "2027-06-15", "page": 1, "source": {}}]}},
                        {**reading, "candidates": {"valid_to": [{"value": "2027-06-15", "page": 3}]}},
                        {**reading, "candidates": {"unknown": []}},
                        {**reading, "candidates": {"valid_to": [{"value": "x", "page": 1}] * 4}}):
            with self.subTest(invalid=invalid):
                self.assertEqual(self.submit(self.upload_payload(document_reading=invalid)).status_code, 400)
        self.assertEqual(DocumentSubmission.objects.count(), 1)


@skipUnless(connection.vendor == "mysql", "Requires MySQL row-lock semantics")
class CouncilExpiryConcurrencyTests(TransactionTestCase):
    def test_parallel_renewal_submissions_share_one_reward_despite_expired_pending_entitlement(self):
        from quests.models import QuestDefinition

        QuestDefinition.objects.update_or_create(code="DOCUMENTS", defaults={"title": "Documents", "is_enabled": True})
        owner = User.objects.create_user(email="annual-concurrent@example.com", display_name="Owner")
        breed = Breed.objects.create(name="Annual concurrent breed", energy_level="LOW", default_size="SMALL")
        dog = Dog.objects.create(owner=owner, name="Coco", breed=breed, age_months=12, size="SMALL", is_brachycephalic=False)
        old = DocumentEntitlement.objects.create(owner=owner, dog=dog, dog_id_snapshot=dog.pk,
            kind="COUNCIL_REGISTRATION", entitlement_key="council:2027", registration_year=2027, valid_to=date(2027, 4, 9), promised_points=300)
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
                    "registration_number": "00042", "council_name": "City of Melbourne", "valid_to": "2028-06-15",
                }, format="json")
                self.assertEqual(submitted.status_code, 201)
                return client.post(f"/api/quests/documents/entitlements/{submitted.data['entitlement_id']}/collect", {}, format="json")
            finally:
                close_old_connections()

        with patch("django.utils.timezone.now", return_value=now), ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(submit_and_collect, range(2)))
        self.assertEqual([result.status_code for result in results], [200, 200])
        self.assertEqual(sorted(result.data["created"] for result in results), [False, True])
        self.assertEqual({result.data["valid_to"] for result in results}, {"2028-06-15"})
        self.assertEqual(DocumentEntitlement.objects.count(), 2)
        self.assertEqual(PointEntry.objects.count(), 1)
        old.refresh_from_db()
        self.assertIsNone(old.point_entry_id)
