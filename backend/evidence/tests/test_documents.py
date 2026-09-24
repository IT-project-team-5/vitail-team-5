import base64
import io
import tempfile
from datetime import date, timedelta
from pathlib import Path
from unittest.mock import patch
from uuid import uuid4

from django.contrib.auth import get_user_model
from django.core.files.base import ContentFile
from django.test import override_settings
from PIL import Image
from pypdf import PdfWriter
from rest_framework.test import APITestCase

from dogs.models import Breed, Dog
from evidence.models import DocumentEntitlement, DocumentSubmission, EvidenceFingerprint
from evidence.storage import private_storage
from quests.models import QuestDefinition
from rewards.models import PointEntry
from rewards.services import get_balance

User = get_user_model()


def pdf_file():
    file = io.BytesIO()
    writer = PdfWriter()
    writer.add_blank_page(width=100, height=100)
    writer.write(file)
    return file.getvalue()


def photo_file(color="red"):
    file = io.BytesIO()
    Image.new("RGB", (20, 20), color).save(file, format="JPEG")
    return file.getvalue()


@override_settings(PASSWORD_HASHERS=["django.contrib.auth.hashers.MD5PasswordHasher"])
@patch("django.utils.timezone.localdate", return_value=date(2026, 9, 25))
class DocumentApiTests(APITestCase):
    @classmethod
    def setUpTestData(cls):
        QuestDefinition.objects.update_or_create(code="DOCUMENTS", defaults={"title": "Documents", "is_enabled": True})
        cls.owner = User.objects.create_user(email="evidence@example.com", display_name="Owner")
        cls.other = User.objects.create_user(email="other-evidence@example.com", display_name="Other")
        cls.admin = User.objects.create_user(email="admin-evidence@example.com", display_name="Admin", role="ADMIN")
        cls.cafe = User.objects.create_user(email="cafe-evidence@example.com", display_name="Cafe", role="CAFE")
        cls.breed = Breed.objects.create(name="Evidence breed", energy_level="LOW", default_size="SMALL")
        cls.dog = Dog.objects.create(owner=cls.owner, name="Coco", breed=cls.breed, age_months=12, size="SMALL", is_brachycephalic=False)
        cls.second_dog = Dog.objects.create(owner=cls.owner, name="Milo", breed=cls.breed, age_months=12, size="SMALL", is_brachycephalic=False)

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.settings = override_settings(PRIVATE_MEDIA_ROOT=self.directory.name)
        self.settings.enable()
        self.addCleanup(self.settings.disable)
        self.client.force_authenticate(self.owner)

    def payload(self, **changes):
        data = {"request_id": str(uuid4()), "dog_id": self.dog.pk,
                "kind": "COUNCIL_REGISTRATION", "registration_number": "Council ABC-42"}
        data.update(changes)
        return data

    def post(self, data):
        return self.client.post("/api/quests/documents", data, format="json")

    def vet(self, event, color="red", **changes):
        data = self.payload(kind="VET_CHECKUP", registration_number="", event_date=event,
                            filename="vet.jpg", file_base64=base64.b64encode(photo_file(color)).decode())
        data.update(changes)
        return data

    def test_number_submission_credits_once_per_dog_and_reupload_preserves_versions(self, _today):
        first = self.post(self.payload())
        self.assertEqual(first.status_code, 201)
        self.assertEqual(first.data["awarded_points"], 300)
        self.assertEqual(first.data["submission"]["status"], "SELF_REPORTED")
        second = self.post(self.payload(registration_number="Updated council number"))
        self.assertEqual(second.status_code, 201)
        self.assertEqual(second.data["awarded_points"], 0)
        self.assertEqual(DocumentSubmission.objects.count(), 2)
        self.assertEqual(DocumentSubmission.objects.first().status, "SELF_REPORTED")
        self.assertEqual(get_balance(self.owner), 300)
        another_dog = self.post(self.payload(dog_id=self.second_dog.pk, registration_number="Other dog number"))
        self.assertEqual(another_dog.data["awarded_points"], 300)

    def test_exact_idempotent_retry_replays_receipt_and_changed_request_conflicts(self, _today):
        payload = self.payload()
        first = self.post(payload)
        retried = self.post(payload)
        self.assertEqual(retried.status_code, 200)
        self.assertEqual(retried.data, first.data)
        changed = self.post({**payload, "registration_number": "Different"})
        self.assertEqual(changed.status_code, 409)
        self.assertEqual(DocumentSubmission.objects.count(), 1)
        self.assertEqual(PointEntry.objects.count(), 1)

    def test_disabled_catalog_rejects_new_submissions_before_files_or_rewards(self, _today):
        QuestDefinition.objects.filter(code="DOCUMENTS").update(is_enabled=False)
        response = self.post(self.payload(file_base64=base64.b64encode(pdf_file()).decode()))
        self.assertEqual(response.status_code, 409)
        self.assertEqual(DocumentSubmission.objects.count(), 0)
        self.assertEqual(DocumentEntitlement.objects.count(), 0)
        self.assertEqual(EvidenceFingerprint.objects.count(), 0)
        self.assertEqual(PointEntry.objects.count(), 0)
        self.assertEqual(list(Path(self.directory.name).rglob("*.pdf")), [])

    def test_disable_preserves_successful_retry_history_and_private_download(self, _today):
        original = pdf_file()
        payload = self.payload(file_base64=base64.b64encode(original).decode())
        first = self.post(payload)
        QuestDefinition.objects.filter(code="DOCUMENTS").update(is_enabled=False)
        retry = self.post(payload)
        self.assertEqual(retry.status_code, 200)
        self.assertEqual(retry.data, first.data)
        self.assertEqual(self.post({**payload, "request_id": str(uuid4())}).status_code, 409)
        history = self.client.get("/api/quests/documents")
        self.assertEqual(history.status_code, 200)
        self.assertEqual(len(history.data["submissions"]), 1)
        download = self.client.get(first.data["submission"]["file_url"])
        self.assertEqual(download.status_code, 200)
        self.assertEqual(b"".join(download.streaming_content), original)
        self.assertEqual(PointEntry.objects.count(), 1)
        self.assertEqual(len(list(Path(self.directory.name).rglob("*.pdf"))), 1)

    def test_microchip_annual_period_and_overlap_do_not_multiply_points(self, _today):
        payload = self.payload(kind="MICROCHIP_REGISTRATION", valid_from="2026-01-01", valid_to="2026-12-31")
        self.assertEqual(self.post(payload).data["awarded_points"], 300)
        overlap = {**payload, "request_id": str(uuid4()), "valid_from": "2026-02-01", "valid_to": "2027-01-31"}
        self.assertEqual(self.post(overlap).data["awarded_points"], 0)
        short = {**payload, "request_id": str(uuid4()), "valid_from": "2026-09-01", "valid_to": "2026-09-30"}
        self.assertEqual(self.post(short).status_code, 400)
        with patch("django.utils.timezone.localdate", return_value=date(2027, 9, 25)):
            next_year = {**payload, "request_id": str(uuid4()), "valid_from": "2027-01-01", "valid_to": "2027-12-31"}
            self.assertEqual(self.post(next_year).data["awarded_points"], 300)
            # A delayed retry does not fail because the original annual period expired.
            self.assertEqual(self.post(payload).status_code, 200)
        self.assertEqual(get_balance(self.owner), 600)

    def test_vet_rewards_use_event_year_and_sixty_day_gap(self, _today):
        self.assertEqual(self.post(self.vet("2026-01-01")).data["awarded_points"], 200)
        self.assertEqual(self.post(self.vet("2026-01-01", "blue")).data["awarded_points"], 0)
        self.assertEqual(self.post(self.vet("2026-03-01", "green")).status_code, 400)  # 59 days
        self.assertEqual(self.post(self.vet("2026-03-02", "green")).data["awarded_points"], 200)
        self.assertEqual(self.post(self.vet("2026-09-01", "white")).status_code, 400)
        self.assertEqual(get_balance(self.owner), 400)

    def test_gap_applies_across_new_year_and_duplicate_photo_cannot_move_visits(self, _today):
        self.assertEqual(self.post(self.vet("2025-12-20")).status_code, 201)
        self.assertEqual(self.post(self.vet("2026-01-20", "blue")).status_code, 400)
        duplicate = self.post(self.vet("2026-03-20"))
        self.assertEqual(duplicate.status_code, 400)
        self.assertEqual(DocumentEntitlement.objects.count(), 1)

    def test_forged_future_date_wrong_file_type_and_large_files_are_rejected(self, _today):
        bad = [self.vet("2026-09-26"), self.vet("2026-09-01", file_base64=base64.b64encode(pdf_file()).decode()),
               self.payload(registration_number="", file_base64=base64.b64encode(photo_file()).decode()),
               self.payload(registration_number="", file_base64="not base64"),
               self.payload(kind="MICROCHIP_REGISTRATION", valid_from="9999-01-01", valid_to="9999-12-31"),
               self.payload(registration_number="", file_base64=base64.b64encode(b"%PDF-FAKE").decode()),
               self.payload(registration_number="", file_base64=base64.b64encode(b"x" * (4 * 1024 * 1024 + 1)).decode())]
        for data in bad:
            with self.subTest(kind=data["kind"]):
                self.assertEqual(self.post(data).status_code, 400)
        self.assertEqual(DocumentSubmission.objects.count(), 0)
        self.assertFalse(list(Path(self.directory.name).rglob("*.pdf")))

    def test_request_body_is_bounded_before_json_file_decoding(self, _today):
        response = self.client.post("/api/quests/documents", b'{"file_base64":"' + b"x" * (6 * 1024 * 1024) + b'"}', content_type="application/json")
        self.assertEqual(response.status_code, 400)
        self.assertEqual(PointEntry.objects.count(), 0)
        self.assertEqual(DocumentSubmission.objects.count(), 0)

    def test_pdf_bytes_preserved_private_and_download_is_owner_or_admin_only(self, _today):
        original = pdf_file()
        response = self.post(self.payload(registration_number="", filename="../../Original.pdf",
                                          file_base64=base64.b64encode(original).decode()))
        self.assertEqual(response.status_code, 201)
        submission = DocumentSubmission.objects.get()
        with private_storage.open(submission.file.name, "rb") as file:
            self.assertEqual(file.read(), original)
        self.assertNotIn("..", submission.file.name)
        with self.assertRaises(ValueError):
            _ = submission.file.url
        endpoint = response.data["submission"]["file_url"]
        download = self.client.get(endpoint)
        self.assertEqual(download.status_code, 200)
        self.assertEqual(b"".join(download.streaming_content), original)
        self.assertEqual(download["Cache-Control"], "private, no-store")
        self.client.force_authenticate(self.other)
        self.assertEqual(self.client.get(endpoint).status_code, 404)
        self.client.force_authenticate(self.cafe)
        self.assertEqual(self.client.get(endpoint).status_code, 404)
        self.client.force_authenticate(self.admin)
        admin = self.client.get(endpoint)
        self.assertEqual(admin.status_code, 200)
        self.assertEqual(b"".join(admin.streaming_content), original)
        self.client.force_authenticate(None)
        self.assertEqual(self.client.get(endpoint).status_code, 401)

    def test_owner_scope_is_enforced_while_family_registration_can_cover_two_dogs(self, _today):
        self.assertEqual(self.post(self.payload()).status_code, 201)
        repeated = self.post(self.payload(dog_id=self.second_dog.pk))
        self.assertEqual(repeated.status_code, 201)
        self.assertEqual(repeated.data["awarded_points"], 300)
        self.assertEqual(DocumentEntitlement.objects.count(), 2)
        self.client.force_authenticate(self.other)
        self.assertEqual(self.post(self.payload(registration_number="Other")).status_code, 400)
        self.assertEqual(self.client.get("/api/quests/documents").data["submissions"], [])
        self.client.force_authenticate(self.cafe)
        self.assertEqual(self.post(self.payload()).status_code, 403)

    def test_one_certificate_can_support_two_dogs_but_never_duplicates_one_dog_reward(self, _today):
        encoded = base64.b64encode(pdf_file()).decode()
        for dog in (self.dog, self.second_dog):
            response = self.post(self.payload(dog_id=dog.pk, file_base64=encoded))
            self.assertEqual(response.status_code, 201)
            self.assertEqual(response.data["awarded_points"], 300)
        repeated = self.post(self.payload(file_base64=encoded))
        self.assertEqual(repeated.data["awarded_points"], 0)
        self.assertEqual(get_balance(self.owner), 600)
        self.assertEqual(len(list(Path(self.directory.name).rglob("*.pdf"))), 3)

    def test_vet_visit_before_known_dog_birthday_is_rejected(self, _today):
        self.dog.date_of_birth = date(2026, 8, 1)
        self.dog.save(update_fields=["date_of_birth"])
        response = self.post(self.vet("2026-07-31"))
        self.assertEqual(response.status_code, 400)
        self.assertIn("event_date", response.data)
        self.assertEqual(PointEntry.objects.count(), 0)

    def test_file_or_receipt_failure_rolls_back_points_and_evidence(self, _today):
        payload = self.payload(file_base64=base64.b64encode(pdf_file()).decode())
        with patch("evidence.services.private_storage.save", side_effect=OSError("disk full")):
            with self.assertRaises(OSError):
                self.post(payload)
        self.assertEqual(get_balance(self.owner), 0)
        self.assertEqual(DocumentEntitlement.objects.count(), 0)
        with patch("evidence.services.DocumentSubmissionSerializer.to_representation", side_effect=RuntimeError("receipt failure")):
            with self.assertRaises(RuntimeError):
                self.post(payload)
        self.assertEqual(DocumentSubmission.objects.count(), 0)
        self.assertEqual(EvidenceFingerprint.objects.count(), 0)
        self.assertEqual(PointEntry.objects.count(), 0)
        self.assertEqual(list(Path(self.directory.name).rglob("*.pdf")), [])

    def test_partial_file_write_failure_removes_new_bytes_and_rolls_back_rewards(self, _today):
        def broken_chunks(_content):
            yield b"partially written private evidence"
            raise OSError("disk full after a chunk")

        payload = self.payload(file_base64=base64.b64encode(pdf_file()).decode())
        with patch.object(ContentFile, "chunks", broken_chunks):
            with self.assertRaisesMessage(OSError, "disk full after a chunk"):
                self.post(payload)
        self.assertEqual(list(Path(self.directory.name).rglob("*.pdf")), [])
        self.assertEqual(DocumentSubmission.objects.count(), 0)
        self.assertEqual(DocumentEntitlement.objects.count(), 0)
        self.assertEqual(EvidenceFingerprint.objects.count(), 0)
        self.assertEqual(PointEntry.objects.count(), 0)

    def test_partial_write_cleanup_never_deletes_an_existing_name_collision(self, _today):
        name = "documents/existing.pdf"
        saved = private_storage.save(name, ContentFile(b"preserved original"))

        class BrokenFile(ContentFile):
            def chunks(self, chunk_size=None):
                yield b"incomplete new evidence"
                raise OSError("write failure")

        # Exercise the exclusive-open collision handling, after save's earlier
        # availability check could have raced with another writer.
        with self.assertRaises(OSError):
            private_storage._save(name, BrokenFile(b""))
        with private_storage.open(saved, "rb") as original:
            self.assertEqual(original.read(), b"preserved original")
        self.assertEqual(len(list(Path(self.directory.name).rglob("*.pdf"))), 1)

    def test_entitlement_stays_with_dog_if_an_admin_transfers_profile(self, _today):
        self.post(self.payload())
        self.dog.owner = self.other
        self.dog.save(update_fields=["owner"])
        self.client.force_authenticate(self.other)
        response = self.post(self.payload(registration_number="Updated after transfer"))
        self.assertEqual(response.status_code, 201)
        self.assertEqual(response.data["awarded_points"], 0)
        self.assertEqual(get_balance(self.other), 0)
        self.assertEqual(DocumentEntitlement.objects.count(), 1)

    def test_dog_deletion_preserves_original_submission_and_entitlement(self, _today):
        receipt = self.post(self.payload())
        self.dog.delete()
        submission = DocumentSubmission.objects.get()
        self.assertIsNone(submission.dog_id)
        self.assertEqual(submission.dog_name_snapshot, "Coco")
        self.assertEqual(DocumentEntitlement.objects.count(), 1)
        dashboard = self.client.get("/api/quests/documents")
        self.assertEqual(dashboard.data["submissions"][0]["id"], receipt.data["submission"]["id"])


from concurrent.futures import ThreadPoolExecutor
from threading import Barrier
from unittest import skipUnless
from django.db import close_old_connections, connection
from django.test import TransactionTestCase
from rest_framework.test import APIClient


@skipUnless(connection.vendor == "mysql", "Requires MySQL row-lock semantics")
class DocumentConcurrencyTests(TransactionTestCase):
    def test_simultaneous_submissions_credit_one_per_dog_entitlement(self):
        QuestDefinition.objects.update_or_create(code="DOCUMENTS", defaults={"title": "Documents", "is_enabled": True})
        owner = User.objects.create_user(email="concurrent-evidence@example.com", display_name="Owner")
        breed = Breed.objects.create(name="Concurrent evidence breed", energy_level="LOW", default_size="SMALL")
        dog = Dog.objects.create(owner=owner, name="Coco", breed=breed, age_months=12, size="SMALL", is_brachycephalic=False)
        barrier = Barrier(2)
        def submit():
            close_old_connections()
            try:
                client = APIClient()
                client.force_authenticate(owner)
                barrier.wait(timeout=10)
                return client.post("/api/quests/documents", {
                    "request_id": str(uuid4()), "dog_id": dog.pk,
                    "kind": "COUNCIL_REGISTRATION", "registration_number": "One entitlement",
                }, format="json")
            finally:
                close_old_connections()
        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(lambda _: submit(), range(2)))
        self.assertEqual([result.status_code for result in results], [201, 201])
        self.assertEqual(sorted(result.data["awarded_points"] for result in results), [0, 300])
        self.assertEqual(DocumentEntitlement.objects.count(), 1)
        self.assertEqual(PointEntry.objects.count(), 1)
        self.assertEqual(DocumentSubmission.objects.count(), 2)
