import base64
import tempfile
from concurrent.futures import ThreadPoolExecutor
from datetime import date, datetime
from threading import Barrier
from unittest import skipUnless
from unittest.mock import patch
from uuid import uuid4

from django.contrib.auth import get_user_model
from django.db import close_old_connections, connection
from django.test import TransactionTestCase, override_settings
from rest_framework.test import APIClient, APITestCase

from dogs.models import Breed, Dog
from evidence.models import DocumentEntitlement, DocumentSubmission
from evidence.tests.test_documents import pdf_file, photo_file
from quests.models import QuestDefinition
from rewards.models import PointEntry
from rewards.policy import MELBOURNE


@override_settings(PASSWORD_HASHERS=["django.contrib.auth.hashers.MD5PasswordHasher"])
class DocumentCorrectionTests(APITestCase):
    @classmethod
    def setUpTestData(cls):
        cls.owner = get_user_model().objects.create_user(email="correct@example.com", display_name="Owner")
        cls.other = get_user_model().objects.create_user(email="other-correct@example.com", display_name="Other")
        breed = Breed.objects.create(name="Correction breed", energy_level="LOW", default_size="SMALL")
        cls.dog = Dog.objects.create(owner=cls.owner, name="Coco", breed=breed, age_months=12, size="SMALL", is_brachycephalic=False)

    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        settings = override_settings(PRIVATE_MEDIA_ROOT=directory.name)
        settings.enable(); self.addCleanup(settings.disable)
        self.now = datetime(2026, 9, 29, 12, tzinfo=MELBOURNE)
        clock = patch("django.utils.timezone.now", side_effect=lambda: self.now)
        clock.start(); self.addCleanup(clock.stop)
        self.client.force_authenticate(self.owner)

    def payload(self, **changes):
        data = {"request_id": str(uuid4()), "dog_id": self.dog.pk, "kind": "COUNCIL_REGISTRATION",
                "registration_number": "00042", "council_name": "City of Melbourne", "valid_to": "2027-06-15"}
        data.update(changes)
        return data

    def submit(self, data=None):
        response = self.client.post("/api/quests/documents", data or self.payload(), format="json")
        self.assertEqual(response.status_code, 201, response.data)
        return response.data

    def collect(self, receipt):
        return self.client.post(f"/api/quests/documents/entitlements/{receipt['entitlement_id']}/collect", {}, format="json")

    def correct(self, receipt, data=None):
        return self.client.post(f"/api/quests/documents/{receipt['submission']['id']}/corrections", data or self.payload(), format="json")

    def registration(self, kind="COUNCIL_REGISTRATION"):
        return next(row for row in self.client.get("/api/quests/documents").data["registrations"] if row["kind"] == kind)

    def council_tasks(self):
        return [row for row in self.client.get("/api/quests").data["tasks"] if row["kind"] == "COUNCIL_REGISTRATION"]

    def test_paid_details_and_attachment_can_be_corrected_without_credit_or_losing_original(self):
        first = self.submit(self.payload(filename="original.pdf", file_base64=base64.b64encode(pdf_file()).decode()))
        self.assertEqual(self.collect(first).status_code, 200)
        old = DocumentSubmission.objects.get()
        ledger = list(PointEntry.objects.values())
        corrected = self.correct(first, self.payload(registration_number="00100", council_name="Yarra", document_dog_name="Coco on file"))
        self.assertEqual(corrected.status_code, 201, corrected.data)
        new = DocumentSubmission.objects.get(pk=corrected.data["submission"]["id"])
        self.assertEqual(new.file.name, old.file.name)
        self.assertEqual(new.entitlement_id, old.entitlement_id)
        self.assertEqual((new.registration_number, new.council_name, new.awarded_points), ("00100", "Yarra", 0))
        old.refresh_from_db()
        self.assertEqual(old.response_snapshot, first)
        self.assertEqual(list(PointEntry.objects.values()), ledger)
        self.assertEqual(self.registration()["submission"]["id"], new.pk)
        self.assertTrue(self.registration()["can_correct"])
        self.assertFalse(self.registration()["can_renew"])
        replacement = self.correct(corrected.data, self.payload(filename="replacement.jpg", file_base64=base64.b64encode(photo_file("blue")).decode()))
        self.assertEqual(replacement.status_code, 201, replacement.data)
        self.assertNotEqual(DocumentSubmission.objects.get(pk=replacement.data["submission"]["id"]).file.name, old.file.name)
        download = self.client.get(f"/api/quests/documents/{old.pk}/file")
        self.assertEqual(download.status_code, 200)
        self.assertEqual(b"".join(download.streaming_content), pdf_file())
        self.assertEqual(PointEntry.objects.count(), 1)

    def test_backdating_expiry_cannot_advance_renewal_but_expired_task_disappears(self):
        first = self.submit()
        self.collect(first)
        updated = self.correct(first, self.payload(valid_to="2026-09-28"))
        self.assertEqual(updated.status_code, 201)
        self.assertEqual(self.registration()["submission"]["valid_to"], "2026-09-28")
        self.assertEqual(self.registration()["renewal_after"], "2027-06-15")
        self.assertFalse(self.registration()["can_renew"])
        self.assertEqual(self.council_tasks(), [])
        denied = self.client.post("/api/quests/documents", self.payload(valid_to="2028-06-15"), format="json")
        self.assertEqual(denied.status_code, 400)
        self.now = datetime(2027, 6, 16, 0, tzinfo=MELBOURNE)
        self.assertTrue(self.registration()["can_renew"])
        self.assertEqual(self.council_tasks()[0]["status"], "IN_PROGRESS")
        renewed = self.submit(self.payload(valid_to="2028-06-15"))
        self.assertEqual(self.collect(renewed).status_code, 200)
        self.assertEqual(PointEntry.objects.count(), 2)
        self.assertEqual(self.correct(updated.data).status_code, 409)

    def test_pending_correction_does_not_credit_and_expired_corrected_reward_cannot_collect(self):
        first = self.submit()
        corrected = self.correct(first, self.payload(valid_to="2026-09-28"))
        self.assertEqual(corrected.status_code, 201)
        self.assertEqual(self.collect(first).data["code"], "EXPIRED")
        self.assertEqual(self.council_tasks(), [])
        self.assertFalse(PointEntry.objects.exists())
        fixed = self.correct(corrected.data, self.payload(valid_to="2027-08-01"))
        self.assertEqual(fixed.status_code, 201)
        self.assertEqual(self.registration()["renewal_after"], "2027-08-01")
        self.assertEqual(self.collect(fixed.data).status_code, 200)
        back = self.correct(fixed.data, self.payload(valid_to="2027-06-15"))
        self.assertEqual(back.status_code, 201)
        self.assertEqual(self.registration()["renewal_after"], "2027-08-01")
        self.assertEqual(PointEntry.objects.count(), 1)

    def test_stale_edit_conflicts_and_exact_retry_replays_across_collection(self):
        first = self.submit()
        payload = self.payload(registration_number="00043")
        updated = self.correct(first, payload)
        self.assertEqual(updated.status_code, 201)
        self.collect(updated.data)
        retry = self.correct(first, payload)
        self.assertEqual((retry.status_code, retry.data), (200, updated.data))
        self.assertEqual(self.correct(first).status_code, 409)
        self.assertEqual(self.correct(first, {**payload, "registration_number": "00044"}).status_code, 409)
        self.assertEqual(self.client.post("/api/quests/documents", payload, format="json").status_code, 409)
        self.assertEqual(DocumentSubmission.objects.count(), 2)

    def test_other_owner_cannot_read_or_correct_private_registration_and_transfer_cannot_reset_reward(self):
        first = self.submit()
        self.collect(first)
        self.client.force_authenticate(self.other)
        self.assertEqual(self.correct(first).status_code, 404)
        self.dog.owner = self.other; self.dog.save(update_fields=["owner"])
        self.assertIsNone(self.registration()["submission"])
        self.assertFalse(self.registration()["can_correct"])
        self.assertEqual(self.correct(first).status_code, 404)
        self.client.force_authenticate(self.owner)
        self.assertEqual(self.correct(first).status_code, 400)
        self.assertEqual(PointEntry.objects.count(), 1)

    def test_correction_keeps_dog_kind_and_entitlement_and_allows_catalog_disabled(self):
        first = self.submit()
        for change in ({"dog_id": self.dog.pk + 1}, {"kind": "MICROCHIP_REGISTRATION"}, {"expected_entitlement_id": 99999}):
            self.assertEqual(self.correct(first, self.payload(**change)).status_code, 400)
        QuestDefinition.objects.filter(code="DOCUMENTS").update(is_enabled=False)
        self.assertEqual(self.correct(first).status_code, 201)
        self.assertFalse(PointEntry.objects.exists())

    def test_microchip_correction_retains_proof_for_legacy_format_and_one_lifetime_reward(self):
        data = {"request_id": str(uuid4()), "dog_id": self.dog.pk, "kind": "MICROCHIP_REGISTRATION",
                "registration_number": "0012345678", "registry_name": "CAR",
                "filename": "chip.pdf", "file_base64": base64.b64encode(pdf_file()).decode()}
        first = self.submit(data)
        self.collect(first)
        updated = self.correct(first, {key: value for key, value in {**data, "request_id": str(uuid4()), "registration_number": "0012345679"}.items() if key not in ("filename", "file_base64")})
        self.assertEqual(updated.status_code, 201, updated.data)
        self.assertEqual(updated.data["entitlement_id"], first["entitlement_id"])
        self.assertEqual(self.registration("MICROCHIP_REGISTRATION")["submission"]["registration_number"], "0012345679")
        self.assertFalse(self.collect(updated.data).data["created"])
        self.assertEqual(PointEntry.objects.count(), 1)

    def test_failure_rolls_back_expiry_and_preserves_file(self):
        first = self.submit(self.payload(filename="proof.pdf", file_base64=base64.b64encode(pdf_file()).decode()))
        with patch("evidence.services.DocumentSubmission.objects.create", side_effect=RuntimeError("save failed")):
            with self.assertRaises(RuntimeError):
                self.correct(first, self.payload(valid_to="2028-06-15"))
        row = DocumentEntitlement.objects.get()
        self.assertEqual((row.valid_to, row.renewal_blocked_through), (date(2027, 6, 15), date(2027, 6, 15)))
        self.assertEqual(DocumentSubmission.objects.count(), 1)
        download = self.client.get(f"/api/quests/documents/{first['submission']['id']}/file")
        self.assertEqual(download.status_code, 200)
        self.assertEqual(b"".join(download.streaming_content), pdf_file())


@skipUnless(connection.vendor == "mysql", "Requires MySQL row locks")
class CorrectionConcurrencyTests(TransactionTestCase):
    def test_two_editors_cannot_overwrite_same_document_version(self):
        QuestDefinition.objects.update_or_create(code="DOCUMENTS", defaults={"title": "Documents", "is_enabled": True})
        owner = get_user_model().objects.create_user(email="concurrent-edit@example.com")
        breed = Breed.objects.create(name="Concurrent correction", energy_level="LOW", default_size="SMALL")
        dog = Dog.objects.create(owner=owner, name="Coco", breed=breed, age_months=12, size="SMALL", is_brachycephalic=False)
        payload = {"request_id": str(uuid4()), "dog_id": dog.pk, "kind": "COUNCIL_REGISTRATION",
                   "registration_number": "00042", "council_name": "Yarra", "valid_to": "2030-06-15"}
        client = APIClient()
        client.force_authenticate(owner)
        first = client.post("/api/quests/documents", payload, format="json")
        self.assertEqual(first.status_code, 201)
        barrier = Barrier(2)

        def correct(number):
            close_old_connections()
            try:
                worker = APIClient()
                worker.force_authenticate(owner)
                barrier.wait(timeout=10)
                return worker.post(f"/api/quests/documents/{first.data['submission']['id']}/corrections",
                    {**payload, "request_id": str(uuid4()), "registration_number": number}, format="json")
            finally:
                close_old_connections()

        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(correct, ("00043", "00044")))
        self.assertEqual(sorted(result.status_code for result in results), [201, 409])
        self.assertEqual(DocumentEntitlement.objects.count(), 1)
        self.assertEqual(DocumentSubmission.objects.count(), 2)
        self.assertFalse(PointEntry.objects.exists())
