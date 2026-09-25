import base64
import io
import tempfile
from datetime import date, datetime, timedelta, timezone as dt_timezone
from pathlib import Path
from unittest.mock import patch
from uuid import uuid4

from django.contrib.auth import get_user_model
from django.core.files.base import ContentFile
from django.test import override_settings
from django.utils.timezone import localdate as actual_localdate
from PIL import Image
from pypdf import PdfWriter
from rest_framework.test import APITestCase

from dogs.models import Breed, Dog
from evidence.models import DocumentEntitlement, DocumentSubmission, EvidenceFingerprint
from evidence.storage import private_storage
from evidence.services import collect_document, quest_tasks, request_fingerprint
from quests.models import QuestDefinition
from rewards.models import PointEntry
from rewards.services import credit_points, get_balance

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
        if "registration_number" not in changes:
            if data.get("file_base64"):
                data["registration_number"] = ""
            elif data["kind"] == "MICROCHIP_REGISTRATION":
                data["registration_number"] = "012345678901234"
        if data["kind"] == "COUNCIL_REGISTRATION" and data["registration_number"] and not data.get("file_base64"):
            data.setdefault("council_name", "City of Melbourne")
            data.setdefault("registration_year", 2027)
        return data

    def post(self, data):
        return self.client.post("/api/quests/documents", data, format="json")

    def collect(self, response):
        return self.client.post(f"/api/quests/documents/entitlements/{response.data['entitlement_id']}/collect", {}, format="json")

    def vet(self, event, color="red", **changes):
        data = self.payload(kind="VET_CHECKUP", registration_number="", event_date=event,
                            filename="vet.jpg", file_base64=base64.b64encode(photo_file(color)).decode())
        data.update(changes)
        return data

    def legacy_microchip(self, year, *, owner=None, paid=False, eligibility="ELIGIBLE"):
        owner = owner or self.owner
        data = {"request_id": uuid4(), "dog_id": self.dog.pk, "kind": "MICROCHIP_REGISTRATION",
                "registration_number": f"legacy-{year}", "valid_from": date(year, 1, 1), "valid_to": date(year, 12, 31)}
        entry = credit_points(user=owner, amount=300, type=PointEntry.Type.EARN,
                              source_reference=f"legacy-microchip:{self.dog.pk}:{year}") if paid else None
        entitlement = DocumentEntitlement.objects.create(
            owner=owner, dog=self.dog, dog_id_snapshot=self.dog.pk, kind=data["kind"],
            entitlement_key=f"period:{year}-01-01", promised_points=300,
            valid_from=data["valid_from"], valid_to=data["valid_to"], point_entry=entry,
            collected_at=datetime(2026, 9, 24, 1, tzinfo=dt_timezone.utc) if paid else None,
            eligibility_status=eligibility, eligibility_reason="Audit outcome" if eligibility != "ELIGIBLE" else "",
        )
        submission = DocumentSubmission.objects.create(
            owner=owner, dog=self.dog, dog_id_snapshot=self.dog.pk, dog_name_snapshot=self.dog.name,
            kind=data["kind"], request_id=data["request_id"], request_fingerprint=request_fingerprint(data),
            registration_number=data["registration_number"], entitlement=entitlement,
            valid_from=data["valid_from"], valid_to=data["valid_to"],
            response_snapshot={"legacy_year": year, "balance": 765, "awarded_points": 300 if paid else 0},
        )
        return entitlement, submission

    def collect_id(self, entitlement):
        return self.client.post(f"/api/quests/documents/entitlements/{entitlement.pk}/collect", {}, format="json")

    def microchip_tasks(self):
        return [row for row in quest_tasks(owner=self.owner, dogs=[self.dog], now=datetime(2026, 9, 25, 1, tzinfo=dt_timezone.utc))
                if row["kind"] == "MICROCHIP_REGISTRATION"]

    def test_number_submission_credits_once_per_dog_and_reupload_preserves_versions(self, _today):
        first = self.post(self.payload())
        self.assertEqual(first.status_code, 201)
        self.assertEqual(first.data["awarded_points"], 0)
        self.assertEqual(first.data["reward_status"], "READY")
        self.assertEqual(get_balance(self.owner), 0)
        self.assertEqual(self.collect(first).data["points"], 300)
        self.assertEqual(first.data["submission"]["status"], "SELF_REPORTED")
        second = self.post(self.payload(registration_number="Updated council number"))
        self.assertEqual(second.status_code, 201)
        self.assertEqual(second.data["awarded_points"], 0)
        self.assertEqual(DocumentSubmission.objects.count(), 2)
        self.assertEqual(DocumentSubmission.objects.first().status, "SELF_REPORTED")
        self.assertEqual(get_balance(self.owner), 300)
        another_dog = self.post(self.payload(dog_id=self.second_dog.pk, registration_number="Other dog number"))
        self.assertEqual(another_dog.data["awarded_points"], 0)
        self.assertEqual(self.collect(another_dog).data["points"], 300)

    def test_exact_idempotent_retry_replays_receipt_and_changed_request_conflicts(self, _today):
        payload = self.payload()
        first = self.post(payload)
        self.collect(first)
        retried = self.post(payload)
        self.assertEqual(retried.status_code, 200)
        self.assertEqual(retried.data, first.data)
        changed = self.post({**payload, "registration_number": "Different"})
        self.assertEqual(changed.status_code, 409)
        self.assertEqual(DocumentSubmission.objects.count(), 1)
        self.assertEqual(PointEntry.objects.count(), 1)

    def test_council_manual_details_preserve_leading_zero_and_require_current_year(self, _today):
        response = self.post(self.payload(registration_number="00042-AB"))
        self.assertEqual(response.status_code, 201)
        submission = response.data["submission"]
        self.assertEqual(submission["registration_number"], "00042-AB")
        self.assertEqual(submission["council_name"], "City of Melbourne")
        self.assertEqual(submission["registration_year"], 2027)
        self.assertIsNone(submission["valid_from"])
        self.assertIsNone(submission["valid_to"])
        for changes in ({"council_name": ""}, {"registration_year": None}, {"registration_year": 2026},
                        {"registration_year": 2028}, {"registration_number": "ABC/42"},
                        {"registration_number": "--"}, {"council_name": "Melbourne\nOther"}):
            with self.subTest(changes=changes):
                self.assertEqual(self.post(self.payload(**changes)).status_code, 400)
        self.assertEqual(DocumentSubmission.objects.count(), 1)

    def test_council_registration_year_rolls_over_april_ten_in_melbourne_and_retry_survives(self, _today):
        before = datetime(2026, 4, 9, 13, 59, tzinfo=dt_timezone.utc)
        payload = self.payload(registration_year=2026)
        with override_settings(TIME_ZONE="UTC"), patch("django.utils.timezone.localdate", wraps=actual_localdate):
            with patch("django.utils.timezone.now", return_value=before):
                receipt = self.post(payload)
                self.assertEqual(receipt.status_code, 201)
            with patch("django.utils.timezone.now", return_value=before + timedelta(minutes=1)):
                self.assertEqual(self.post({**payload, "request_id": str(uuid4())}).status_code, 400)
                self.assertEqual(self.post(self.payload(registration_year=2027)).status_code, 201)
                replay = self.post(payload)
                self.assertEqual(replay.status_code, 200)
                self.assertEqual(replay.data, receipt.data)

    def test_registration_modes_are_exclusive_and_upload_needs_no_manual_details(self, _today):
        proof = base64.b64encode(pdf_file()).decode()
        for payload in (
            self.payload(registration_number="ABC42", file_base64=proof),
            self.payload(registration_number=""),
            self.payload(registration_number="", file_base64=proof, council_name="City of Melbourne"),
            self.payload(registration_number="", file_base64=proof, registration_year=2027),
        ):
            self.assertEqual(self.post(payload).status_code, 400)
        response = self.post(self.payload(file_base64=proof))
        self.assertEqual(response.status_code, 201)
        self.assertEqual(response.data["submission"]["council_name"], "")
        self.assertIsNone(response.data["submission"]["registration_year"])

    def test_registration_photo_bytes_remain_private_and_filename_follows_actual_format(self, _today):
        for image_format, expected_type, suffix in (("JPEG", "image/jpeg", ".jpg"), ("PNG", "image/png", ".png")):
            with self.subTest(image_format=image_format):
                buffer = io.BytesIO()
                Image.new("RGB", (20, 20), "red").save(buffer, format=image_format)
                original = buffer.getvalue()
                response = self.post(self.payload(filename="../../proof.pdf", file_base64=base64.b64encode(original).decode()))
                self.assertEqual(response.status_code, 201)
                submission = DocumentSubmission.objects.get(pk=response.data["submission"]["id"])
                self.assertEqual(submission.file_content_type, expected_type)
                self.assertEqual(submission.filename, "proof" + suffix)
                download = self.client.get(response.data["submission"]["file_url"])
                self.assertEqual(download["Content-Type"], expected_type)
                self.assertEqual(b"".join(download.streaming_content), original)
                self.assertEqual(download["X-Content-Type-Options"], "nosniff")
                self.client.force_authenticate(self.other)
                self.assertEqual(self.client.get(response.data["submission"]["file_url"]).status_code, 404)
                self.client.force_authenticate(self.owner)

    def test_legacy_number_only_receipt_replays_without_new_council_fields(self, _today):
        legacy = {"request_id": uuid4(), "dog_id": self.dog.pk,
                  "kind": "COUNCIL_REGISTRATION", "registration_number": "Old / unstructured number"}
        entitlement = DocumentEntitlement.objects.create(
            owner=self.owner, dog=self.dog, dog_id_snapshot=self.dog.pk,
            kind=legacy["kind"], entitlement_key="lifetime", promised_points=275,
        )
        receipt = {"balance": 1234, "awarded_points": 0, "created": True, "legacy": "unchanged"}
        submission = DocumentSubmission.objects.create(
            owner=self.owner, dog=self.dog, dog_id_snapshot=self.dog.pk, dog_name_snapshot=self.dog.name,
            kind=legacy["kind"], request_id=legacy["request_id"], request_fingerprint=request_fingerprint(legacy),
            registration_number=legacy["registration_number"], entitlement=entitlement, response_snapshot=receipt,
        )
        QuestDefinition.objects.filter(code="DOCUMENTS").update(is_enabled=False)
        self.dog.delete()
        replay = self.post({**legacy, "request_id": str(legacy["request_id"])})
        self.assertEqual(replay.status_code, 200)
        self.assertEqual(replay.data, receipt)
        submission.refresh_from_db()
        self.assertEqual(submission.response_snapshot, receipt)
        self.assertEqual(submission.registration_number, legacy["registration_number"])
        self.assertEqual(self.client.get("/api/quests/documents").data["submissions"][0]["reward_points"], 275)
        self.assertEqual(DocumentSubmission.objects.count(), 1)
        self.assertEqual(PointEntry.objects.count(), 0)

    def test_legacy_number_and_pdf_retry_replays_unchanged_but_cannot_create_new_submission(self, _today):
        from evidence.uploads import validate_upload

        encoded = base64.b64encode(pdf_file()).decode()
        legacy = {"request_id": uuid4(), "dog_id": self.dog.pk, "kind": "COUNCIL_REGISTRATION",
                  "registration_number": "Legacy number", "upload": validate_upload(encoded, "legacy.pdf", "COUNCIL_REGISTRATION")}
        entitlement = DocumentEntitlement.objects.create(
            owner=self.owner, dog=self.dog, dog_id_snapshot=self.dog.pk,
            kind=legacy["kind"], entitlement_key="lifetime", promised_points=300,
        )
        receipt = {"balance": 321, "awarded_points": 300, "created": True, "old": "receipt"}
        DocumentSubmission.objects.create(
            owner=self.owner, dog=self.dog, dog_id_snapshot=self.dog.pk, dog_name_snapshot=self.dog.name,
            kind=legacy["kind"], request_id=legacy["request_id"], request_fingerprint=request_fingerprint(legacy),
            registration_number=legacy["registration_number"], entitlement=entitlement, response_snapshot=receipt,
        )
        payload = {key: str(value) if key == "request_id" else value for key, value in legacy.items() if key != "upload"}
        payload.update(filename="legacy.pdf", file_base64=encoded)
        response = self.post(payload)
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.data, receipt)
        self.assertEqual(self.post({**payload, "request_id": str(uuid4())}).status_code, 400)
        self.assertEqual(self.post({**payload, "registration_number": "Changed"}).status_code, 409)
        self.assertEqual(list(Path(self.directory.name).rglob("*.pdf")), [])
        self.assertEqual(DocumentSubmission.objects.count(), 1)

    def test_legacy_expired_microchip_period_and_short_number_still_replay_original_receipt(self, _today):
        legacy = {"request_id": uuid4(), "dog_id": self.dog.pk, "kind": "MICROCHIP_REGISTRATION",
                  "registration_number": "OLD123", "valid_from": date(2025, 1, 1), "valid_to": date(2025, 12, 31)}
        entitlement = DocumentEntitlement.objects.create(
            owner=self.owner, dog=self.dog, dog_id_snapshot=self.dog.pk,
            kind=legacy["kind"], entitlement_key="period:2025-01-01", promised_points=300,
            valid_from=legacy["valid_from"], valid_to=legacy["valid_to"],
        )
        receipt = {"balance": 456, "awarded_points": 0, "created": True, "old": "annual receipt"}
        submission = DocumentSubmission.objects.create(
            owner=self.owner, dog=self.dog, dog_id_snapshot=self.dog.pk, dog_name_snapshot=self.dog.name,
            kind=legacy["kind"], request_id=legacy["request_id"], request_fingerprint=request_fingerprint(legacy),
            registration_number=legacy["registration_number"], entitlement=entitlement, response_snapshot=receipt,
            valid_from=legacy["valid_from"], valid_to=legacy["valid_to"],
        )
        payload = {key: str(value) if key in {"request_id", "valid_from", "valid_to"} else value for key, value in legacy.items()}
        response = self.post(payload)
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.data, receipt)
        self.assertEqual(self.post({**payload, "request_id": str(uuid4())}).status_code, 400)
        submission.refresh_from_db()
        self.assertEqual(submission.valid_from, date(2025, 1, 1))
        self.assertEqual(submission.registration_number, "OLD123")
        self.assertEqual(PointEntry.objects.count(), 0)

    def test_encrypted_and_overlong_registration_pdfs_are_rejected_without_storage(self, _today):
        for pages, password in ((1, "private"), (21, None)):
            with self.subTest(pages=pages, encrypted=bool(password)):
                buffer = io.BytesIO()
                writer = PdfWriter()
                for _ in range(pages):
                    writer.add_blank_page(width=100, height=100)
                if password:
                    writer.encrypt(password)
                writer.write(buffer)
                response = self.post(self.payload(file_base64=base64.b64encode(buffer.getvalue()).decode()))
                self.assertEqual(response.status_code, 400)
        self.assertEqual(DocumentSubmission.objects.count(), 0)
        self.assertEqual(list(Path(self.directory.name).rglob("*")), [])

    def test_microchip_manual_number_normalizes_separators_preserves_zeroes_and_replays(self, _today):
        payload = self.payload(kind="MICROCHIP_REGISTRATION", registration_number="000 123-456-789-012")
        response = self.post(payload)
        self.assertEqual(response.status_code, 201)
        self.assertEqual(response.data["submission"]["registration_number"], "000123456789012")
        self.assertIsNone(response.data["submission"]["valid_from"])
        self.assertIsNone(response.data["submission"]["valid_to"])
        self.assertEqual(self.post(payload).data, response.data)
        canonical_retry = self.post({**payload, "registration_number": "000123456789012"})
        self.assertEqual(canonical_retry.status_code, 200)
        self.assertEqual(canonical_retry.data, response.data)
        for number in ("00012345678901", "0001234567890123", "00012345678901A", "０００１２３４５６７８９０１２", "000/123456789012"):
            with self.subTest(number=number):
                invalid = self.post(self.payload(kind="MICROCHIP_REGISTRATION", registration_number=number))
                self.assertEqual(invalid.status_code, 400)
        self.assertEqual(DocumentSubmission.objects.count(), 1)
        self.assertEqual(PointEntry.objects.count(), 0)

    def test_microchip_proof_accepts_pdf_or_photo_without_number_or_dates(self, _today):
        for original, filename in ((pdf_file(), "chip.pdf"), (photo_file(), "chip.jpg")):
            with self.subTest(filename=filename):
                response = self.post(self.payload(kind="MICROCHIP_REGISTRATION", filename=filename,
                                                 file_base64=base64.b64encode(original).decode()))
                self.assertEqual(response.status_code, 201)
                submission = response.data["submission"]
                self.assertEqual(submission["registration_number"], "")
                self.assertEqual(submission["status"], "SELF_REPORTED")
                self.assertIsNone(submission["registration_year"])
                self.assertIsNone(submission["valid_from"])
                self.assertIsNone(submission["valid_to"])
        self.assertEqual(DocumentEntitlement.objects.count(), 1)
        self.assertEqual(PointEntry.objects.count(), 0)

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
        self.collect(first)
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

    def test_microchip_lifetime_reward_cannot_be_renewed_by_number_or_year_changes(self, _today):
        payload = self.payload(kind="MICROCHIP_REGISTRATION")
        first = self.post(payload)
        self.assertEqual(self.collect(first).data["points"], 300)
        self.assertEqual(DocumentEntitlement.objects.get().entitlement_key, "lifetime")
        self.assertEqual(DocumentEntitlement.objects.get().rules_version, "microchip-lifetime-2026-09-25")
        with patch("django.utils.timezone.localdate", return_value=date(2027, 9, 25)):
            updated = self.post(self.payload(kind="MICROCHIP_REGISTRATION", registration_number="123456789012345"))
            self.assertEqual(updated.data["entitlement_id"], first.data["entitlement_id"])
            self.assertFalse(self.collect(updated).data["created"])
            self.assertEqual(self.post(payload).data, first.data)
        self.assertEqual(get_balance(self.owner), 300)
        self.assertEqual(DocumentEntitlement.objects.count(), 1)
        self.assertEqual(PointEntry.objects.count(), 1)

    def test_multiple_legacy_pending_periods_have_one_collectible_lifetime_reservation(self, _today):
        canonical, first_submission = self.legacy_microchip(2024)
        superseded, second_submission = self.legacy_microchip(2025)
        old_receipts = list(DocumentSubmission.objects.order_by("pk").values_list("response_snapshot", flat=True))
        rows = {row["id"]: row for row in self.client.get("/api/quests/documents").data["entitlements"]}
        self.assertTrue(rows[canonical.pk]["can_collect"])
        self.assertFalse(rows[superseded.pk]["can_collect"])
        self.assertEqual([(task["status"], task["entitlement_id"]) for task in self.microchip_tasks()], [("READY", canonical.pk)])
        self.assertEqual(self.collect_id(superseded).status_code, 400)
        self.assertTrue(self.collect_id(canonical).data["created"])
        self.assertEqual(self.collect_id(superseded).status_code, 400)
        self.assertFalse(self.collect_id(canonical).data["created"])
        replacement = self.post(self.payload(kind="MICROCHIP_REGISTRATION"))
        self.assertEqual(replacement.data["entitlement_id"], canonical.pk)
        self.assertEqual(replacement.data["reward_status"], "COLLECTED")
        self.assertEqual(PointEntry.objects.count(), 1)
        self.assertEqual(get_balance(self.owner), 300)
        self.assertEqual(list(DocumentSubmission.objects.filter(pk__in=[first_submission.pk, second_submission.pk]).order_by("pk").values_list("response_snapshot", flat=True)), old_receipts)
        superseded.refresh_from_db()
        self.assertIsNone(superseded.point_entry_id)
        self.assertEqual(superseded.entitlement_key, "period:2025-01-01")
        self.assertEqual(superseded.valid_from, date(2025, 1, 1))

    def test_historical_microchip_award_wins_over_older_pending_and_reuses_proof_without_rewriting_fingerprint(self, _today):
        pending, old_submission = self.legacy_microchip(2024)
        collected, _ = self.legacy_microchip(2025, paid=True)
        encoded = base64.b64encode(pdf_file()).decode()
        from evidence.uploads import validate_upload
        upload = validate_upload(encoded, "old-proof.pdf", "MICROCHIP_REGISTRATION")
        fingerprint = EvidenceFingerprint.objects.create(
            owner=self.owner, kind="MICROCHIP_REGISTRATION", fingerprint=upload["sha256"],
            dog_id_snapshot=self.dog.pk, entitlement=pending, is_file=True,
        )
        original_entitlements = list(DocumentEntitlement.objects.order_by("pk").values())
        original_receipts = list(DocumentSubmission.objects.order_by("pk").values_list("response_snapshot", flat=True))
        original_entries = list(PointEntry.objects.values())
        response = self.post(self.payload(kind="MICROCHIP_REGISTRATION", filename="old-proof.pdf", file_base64=encoded))
        self.assertEqual(response.status_code, 201)
        self.assertEqual(response.data["entitlement_id"], collected.pk)
        self.assertEqual(response.data["reward_status"], "COLLECTED")
        self.assertEqual(self.collect_id(pending).status_code, 400)
        self.assertFalse(self.collect_id(collected).data["created"])
        self.assertEqual(self.microchip_tasks(), [])
        self.assertTrue(all(not row["can_collect"] for row in self.client.get("/api/quests/documents").data["entitlements"]))
        fingerprint.refresh_from_db()
        self.assertEqual(fingerprint.entitlement_id, pending.pk)
        self.assertEqual(list(DocumentEntitlement.objects.order_by("pk").values()), original_entitlements)
        self.assertEqual(list(PointEntry.objects.values()), original_entries)
        self.assertEqual(list(DocumentSubmission.objects.exclude(pk=response.data["submission"]["id"]).order_by("pk").values_list("response_snapshot", flat=True)), original_receipts)

    def test_all_historical_microchip_awards_replay_without_allowing_pending_credit(self, _today):
        first, _ = self.legacy_microchip(2023, paid=True)
        second, _ = self.legacy_microchip(2024, paid=True)
        pending, _ = self.legacy_microchip(2025)
        for entitlement in (first, second):
            self.assertFalse(self.collect_id(entitlement).data["created"])
        self.assertEqual(self.collect_id(pending).status_code, 400)
        self.assertEqual(PointEntry.objects.count(), 2)
        self.assertEqual(get_balance(self.owner), 600)

    def test_transferred_legacy_microchip_requires_new_evidence_for_canonical_pending(self, _today):
        canonical, _ = self.legacy_microchip(2024, owner=self.other)
        later, _ = self.legacy_microchip(2025)
        self.assertEqual([task["status"] for task in self.microchip_tasks()], ["IN_PROGRESS"])
        self.assertEqual(self.collect_id(canonical).status_code, 404)
        self.assertEqual(self.collect_id(later).status_code, 400)
        self.client.force_authenticate(self.other)
        self.assertEqual(self.collect_id(canonical).status_code, 404)
        self.client.force_authenticate(self.owner)
        submitted = self.post(self.payload(kind="MICROCHIP_REGISTRATION"))
        self.assertEqual(submitted.data["entitlement_id"], canonical.pk)
        self.assertTrue(self.collect(submitted).data["created"])
        self.assertEqual(self.collect_id(later).status_code, 400)
        self.assertEqual(get_balance(self.owner), 300)
        self.assertEqual(get_balance(self.other), 0)
        self.assertEqual(PointEntry.objects.count(), 1)

    def test_transferred_dog_cannot_earn_again_after_former_owners_microchip_award(self, _today):
        collected, _ = self.legacy_microchip(2024, owner=self.other, paid=True)
        pending, _ = self.legacy_microchip(2025)
        submitted = self.post(self.payload(kind="MICROCHIP_REGISTRATION"))
        self.assertEqual(submitted.data["entitlement_id"], collected.pk)
        self.assertEqual(submitted.data["reward_status"], "COLLECTED")
        self.assertEqual(self.collect(submitted).status_code, 404)
        self.assertEqual(self.collect_id(pending).status_code, 400)
        self.assertEqual(self.microchip_tasks(), [])
        self.assertTrue(all(not row["can_collect"] for row in self.client.get("/api/quests/documents").data["entitlements"]))
        self.client.force_authenticate(self.other)
        self.assertFalse(self.collect_id(collected).data["created"])
        self.assertEqual(get_balance(self.other), 300)
        self.assertEqual(get_balance(self.owner), 0)

    def test_held_or_rejected_microchip_reservation_cannot_be_bypassed_by_another_period(self, _today):
        canonical, _ = self.legacy_microchip(2024, eligibility="ON_HOLD")
        later, _ = self.legacy_microchip(2025)
        for status in ("ON_HOLD", "REJECTED"):
            with self.subTest(status=status):
                canonical.eligibility_status = status
                canonical.save(update_fields=["eligibility_status"])
                submitted = self.post(self.payload(kind="MICROCHIP_REGISTRATION"))
                self.assertEqual(submitted.data["entitlement_id"], canonical.pk)
                self.assertEqual(self.collect_id(canonical).status_code, 400)
                self.assertEqual(self.collect_id(later).status_code, 400)
                self.assertEqual(self.microchip_tasks(), [])
                self.assertTrue(all(not row["can_collect"] for row in self.client.get("/api/quests/documents").data["entitlements"]))
        self.assertEqual(PointEntry.objects.count(), 0)
        self.assertEqual(DocumentEntitlement.objects.count(), 2)

    def test_vet_rewards_use_event_year_and_sixty_day_gap(self, _today):
        self.assertEqual(self.collect(self.post(self.vet("2026-01-01"))).data["points"], 200)
        self.assertEqual(self.post(self.vet("2026-01-01", "blue")).data["awarded_points"], 0)
        self.assertEqual(self.post(self.vet("2026-03-01", "green")).status_code, 400)  # 59 days
        self.assertEqual(self.collect(self.post(self.vet("2026-03-02", "green"))).data["points"], 200)
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
               self.payload(registration_number="", file_base64=base64.b64encode(b"GIF89a").decode()),
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
        self.assertEqual(repeated.data["awarded_points"], 0)
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
            self.assertEqual(response.data["awarded_points"], 0)
            self.assertEqual(self.collect(response).data["points"], 300)
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
        first = self.post(self.payload())
        self.collect(first)
        self.dog.owner = self.other
        self.dog.save(update_fields=["owner"])
        self.client.force_authenticate(self.other)
        response = self.post(self.payload(registration_number="Updated after transfer"))
        self.assertEqual(response.status_code, 201)
        self.assertEqual(response.data["awarded_points"], 0)
        self.assertEqual(get_balance(self.other), 0)
        self.assertEqual(self.collect(response).status_code, 404)
        self.client.force_authenticate(self.owner)
        self.assertFalse(self.collect(first).data["created"])
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

    def test_submit_reserves_ready_reward_then_explicit_collect_is_idempotent(self, _today):
        payload = self.payload()
        submitted = self.post(payload)
        entitlement = DocumentEntitlement.objects.get()
        self.assertIsNone(entitlement.point_entry_id)
        self.assertIsNone(entitlement.collected_at)
        self.assertEqual(submitted.data["awarded_points"], 0)
        dashboard = self.client.get("/api/quests/documents").data
        eligibility = next(row for row in dashboard["eligibility"] if row["dog_id"] == self.dog.pk and row["kind"] == "COUNCIL_REGISTRATION")
        self.assertEqual((eligibility["awards_count"], eligibility["pending_count"]), (0, 1))
        self.assertTrue(dashboard["entitlements"][0]["can_collect"])
        first, repeated = self.collect(submitted), self.collect(submitted)
        self.assertTrue(first.data["created"])
        self.assertFalse(repeated.data["created"])
        self.assertEqual(first.data["collected_at"], repeated.data["collected_at"])
        self.assertEqual(get_balance(self.owner), 300)
        self.assertEqual(PointEntry.objects.count(), 1)
        self.assertEqual(self.post(payload).data, submitted.data)
        history = self.client.get("/api/quests/documents").data
        self.assertEqual(history["submissions"][0]["reward_status"], "COLLECTED")
        self.assertEqual(history["submissions"][0]["awarded_points"], 0)

    def test_pending_vet_rewards_reserve_quota_without_credit(self, _today):
        first = self.post(self.vet("2026-01-01"))
        second = self.post(self.vet("2026-03-02", "blue"))
        self.assertEqual(self.post(self.vet("2026-09-01", "green")).status_code, 400)
        self.assertEqual(get_balance(self.owner), 0)
        self.collect(first)
        self.collect(second)
        self.assertEqual(get_balance(self.owner), 400)

    def test_collect_checks_owner_dog_and_catalog_but_successful_replay_survives_disable(self, _today):
        submitted = self.post(self.payload())
        self.client.force_authenticate(self.other)
        self.assertEqual(self.collect(submitted).status_code, 404)
        self.client.force_authenticate(self.cafe)
        self.assertEqual(self.collect(submitted).status_code, 403)
        self.client.force_authenticate(self.owner)
        QuestDefinition.objects.filter(code="DOCUMENTS").update(is_enabled=False)
        self.assertEqual(self.collect(submitted).status_code, 409)
        self.assertEqual(PointEntry.objects.count(), 0)
        QuestDefinition.objects.filter(code="DOCUMENTS").update(is_enabled=True)
        self.assertTrue(self.collect(submitted).data["created"])
        QuestDefinition.objects.filter(code="DOCUMENTS").update(is_enabled=False)
        self.assertFalse(self.collect(submitted).data["created"])
        self.assertEqual(PointEntry.objects.count(), 1)

    def test_uncollected_transfer_requires_current_owner_evidence_and_never_double_credits(self, _today):
        original = self.post(self.payload())
        self.dog.owner = self.other
        self.dog.save(update_fields=["owner"])
        self.assertEqual(self.collect(original).status_code, 404)
        self.client.force_authenticate(self.other)
        self.assertEqual(self.collect(original).status_code, 404)
        replacement = self.post(self.payload(registration_number="New owner evidence"))
        self.assertEqual(replacement.data["entitlement_id"], original.data["entitlement_id"])
        self.assertTrue(self.collect(replacement).data["created"])
        self.assertEqual(get_balance(self.other), 300)
        self.assertEqual(get_balance(self.owner), 0)
        self.assertEqual(PointEntry.objects.count(), 1)

    def test_collection_failure_rolls_back_credit_and_leaves_ready(self, _today):
        submitted = self.post(self.payload())
        with patch("evidence.services.DocumentEntitlement.save", side_effect=RuntimeError("collection failure")):
            with self.assertRaises(RuntimeError):
                self.collect(submitted)
        entitlement = DocumentEntitlement.objects.get()
        self.assertIsNone(entitlement.point_entry_id)
        self.assertIsNone(entitlement.collected_at)
        self.assertEqual(PointEntry.objects.count(), 0)

    def test_tasks_show_ready_then_collected_only_on_melbourne_collection_day(self, _today):
        submitted = self.post(self.payload())
        before_midnight = datetime(2026, 9, 25, 13, 59, tzinfo=dt_timezone.utc)
        after_midnight = before_midnight + timedelta(minutes=2)
        tasks = quest_tasks(owner=self.owner, dogs=[self.dog], now=before_midnight)
        council = [row for row in tasks if row["kind"] == "COUNCIL_REGISTRATION"]
        self.assertEqual([row["status"] for row in council], ["READY"])
        collect_document(owner=self.owner, entitlement_id=submitted.data["entitlement_id"], now=before_midnight)
        today_tasks = quest_tasks(owner=self.owner, dogs=[self.dog], now=before_midnight)
        self.assertEqual([row["status"] for row in today_tasks if row["kind"] == "COUNCIL_REGISTRATION"], ["COLLECTED"])
        tomorrow = quest_tasks(owner=self.owner, dogs=[self.dog], now=after_midnight)
        self.assertFalse(any(row["kind"] == "COUNCIL_REGISTRATION" for row in tomorrow))
        self.assertEqual(len(self.client.get("/api/quests/documents").data["submissions"]), 1)

    def test_tasks_hide_collected_microchip_and_vet_gap_and_pending_duplicates(self, _today):
        now = datetime(2026, 9, 25, 2, tzinfo=dt_timezone.utc)
        micro = self.post(self.payload(kind="MICROCHIP_REGISTRATION"))
        vet = self.post(self.vet("2026-09-01"))
        initial = quest_tasks(owner=self.owner, dogs=[self.dog], now=now)
        self.assertEqual([row["status"] for row in initial if row["kind"] == "MICROCHIP_REGISTRATION"], ["READY"])
        # Collection timestamps must use the same fixture clock as the dashboard;
        # freezing localdate alone does not freeze timezone.now().
        with patch("django.utils.timezone.now", return_value=now):
            self.assertEqual(self.collect(micro).status_code, 200)
            self.assertEqual(self.collect(vet).status_code, 200)
        collected_today = quest_tasks(owner=self.owner, dogs=[self.dog], now=now)
        self.assertEqual({row["kind"] for row in collected_today if row["status"] == "COLLECTED"},
                         {"MICROCHIP_REGISTRATION", "VET_CHECKUP"})
        tasks = quest_tasks(owner=self.owner, dogs=[self.dog], now=now + timedelta(days=1))
        self.assertFalse(any(row["kind"] in {"MICROCHIP_REGISTRATION", "VET_CHECKUP"} for row in tasks))

    def test_previous_owner_history_and_quest_keep_snapshot_after_transfer_and_rename(self, _today):
        now = datetime(2026, 9, 25, 2, tzinfo=dt_timezone.utc)
        submitted = self.post(self.payload())
        collect_document(owner=self.owner, entitlement_id=submitted.data["entitlement_id"], now=now)
        self.dog.owner = self.other
        self.dog.name = "New family's private dog name"
        self.dog.save(update_fields=["owner", "name"])
        history = self.client.get("/api/quests/documents").data
        self.assertEqual(history["submissions"][0]["dog_name"], "Coco")
        self.assertEqual(history["entitlements"][0]["dog_name"], "Coco")
        tasks = quest_tasks(owner=self.owner, dogs=[self.second_dog], now=now)
        collected = next(row for row in tasks if row["status"] == "COLLECTED")
        self.assertEqual(collected["subject_name"], "Coco")
        self.assertEqual(collected["subtitle"], "Coco")
        self.assertIsNone(collected["photo"])

    def test_validation_uses_melbourne_dates_when_server_default_is_utc(self, _today):
        melbourne_just_after_midnight = datetime(2026, 9, 24, 14, 10, tzinfo=dt_timezone.utc)
        with override_settings(TIME_ZONE="UTC"), patch("django.utils.timezone.localdate", wraps=actual_localdate), patch("django.utils.timezone.now", return_value=melbourne_just_after_midnight):
            self.assertEqual(self.post(self.vet("2026-09-25")).status_code, 201)
            self.assertEqual(self.post(self.vet("2026-09-26", "blue")).status_code, 400)
            self.assertEqual(self.post(self.payload(kind="MICROCHIP_REGISTRATION")).status_code, 201)
            expired = self.payload(dog_id=self.second_dog.pk, kind="MICROCHIP_REGISTRATION", valid_from="2025-09-25", valid_to="2026-09-24")
            self.assertEqual(self.post(expired).status_code, 400)


from concurrent.futures import ThreadPoolExecutor
from threading import Barrier
from unittest import skipUnless
from django.db import close_old_connections, connection
from django.test import TransactionTestCase
from rest_framework.test import APIClient


@skipUnless(connection.vendor == "mysql", "Requires MySQL row-lock semantics")
class DocumentConcurrencyTests(TransactionTestCase):
    def test_simultaneous_submissions_credit_one_per_dog_entitlement(self):
        self.concurrent_registration("COUNCIL_REGISTRATION")

    def test_simultaneous_microchip_submissions_credit_one_lifetime_reward(self):
        self.concurrent_registration("MICROCHIP_REGISTRATION")

    def concurrent_registration(self, kind):
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
                submitted = client.post("/api/quests/documents", {
                    "request_id": str(uuid4()), "dog_id": dog.pk,
                    "kind": kind, "registration_number": "012345678901234",
                    **({"council_name": "City of Melbourne", "registration_year": 2027} if kind == "COUNCIL_REGISTRATION" else {}),
                }, format="json")
                return client.post(f"/api/quests/documents/entitlements/{submitted.data['entitlement_id']}/collect", {}, format="json")
            finally:
                close_old_connections()
        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(lambda _: submit(), range(2)))
        self.assertEqual([result.status_code for result in results], [200, 200])
        self.assertEqual(sorted(result.data["created"] for result in results), [False, True])
        self.assertEqual(DocumentEntitlement.objects.count(), 1)
        self.assertEqual(PointEntry.objects.count(), 1)
        self.assertEqual(DocumentSubmission.objects.count(), 2)

    def test_simultaneous_legacy_microchip_collections_cannot_credit_two_periods(self):
        QuestDefinition.objects.update_or_create(code="DOCUMENTS", defaults={"title": "Documents", "is_enabled": True})
        owner = User.objects.create_user(email="legacy-concurrent-evidence@example.com", display_name="Owner")
        breed = Breed.objects.create(name="Legacy concurrent evidence breed", energy_level="LOW", default_size="SMALL")
        dog = Dog.objects.create(owner=owner, name="Coco", breed=breed, age_months=12, size="SMALL", is_brachycephalic=False)
        entitlements = []
        for year in (2024, 2025):
            entitlement = DocumentEntitlement.objects.create(
                owner=owner, dog=dog, dog_id_snapshot=dog.pk, kind="MICROCHIP_REGISTRATION",
                entitlement_key=f"period:{year}-01-01", promised_points=300,
                valid_from=date(year, 1, 1), valid_to=date(year, 12, 31),
            )
            DocumentSubmission.objects.create(
                owner=owner, dog=dog, dog_id_snapshot=dog.pk, dog_name_snapshot=dog.name,
                kind="MICROCHIP_REGISTRATION", request_id=uuid4(), request_fingerprint=str(year) * 16,
                registration_number=f"old-{year}", entitlement=entitlement, response_snapshot={"year": year},
            )
            entitlements.append(entitlement)
        barrier = Barrier(2)

        def collect(entitlement):
            close_old_connections()
            try:
                client = APIClient()
                client.force_authenticate(owner)
                barrier.wait(timeout=10)
                return client.post(f"/api/quests/documents/entitlements/{entitlement.pk}/collect", {}, format="json")
            finally:
                close_old_connections()

        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(collect, entitlements))
        self.assertEqual([result.status_code for result in results], [200, 400])
        self.assertEqual(PointEntry.objects.count(), 1)
        self.assertEqual(DocumentEntitlement.objects.filter(point_entry__isnull=False).count(), 1)
        self.assertEqual(DocumentSubmission.objects.count(), 2)


class DocumentCollectionMigrationTests(TransactionTestCase):
    def test_legacy_credits_backfill_collection_time_without_changing_receipts_or_points(self):
        from django.db.migrations.executor import MigrationExecutor
        executor = MigrationExecutor(connection)
        latest = executor.loader.graph.leaf_nodes()
        before = [("evidence", "0001_initial")]
        try:
            executor.migrate(before)
            apps = executor.loader.project_state(before).apps
            owner = apps.get_model("accounts", "User").objects.create(email="legacy-evidence@example.com", display_name="Legacy")
            entry = apps.get_model("rewards", "PointEntry").objects.create(user_id=owner.pk, amount=300, remaining_points=300, type="EARN", source_reference="legacy-document", expires_at=datetime(2027, 1, 1, tzinfo=dt_timezone.utc))
            Entitlement = apps.get_model("evidence", "DocumentEntitlement")
            credited = Entitlement.objects.create(owner_id=owner.pk, dog_id_snapshot=701, kind="COUNCIL_REGISTRATION", entitlement_key="lifetime", point_entry_id=entry.pk)
            pending = Entitlement.objects.create(owner_id=owner.pk, dog_id_snapshot=702, kind="COUNCIL_REGISTRATION", entitlement_key="lifetime")
            saved_receipt = {"balance": 300, "awarded_points": 300, "created": True}
            apps.get_model("evidence", "DocumentSubmission").objects.create(owner_id=owner.pk, dog_id_snapshot=701, dog_name_snapshot="Legacy dog", kind="COUNCIL_REGISTRATION", request_id=uuid4(), request_fingerprint="a" * 64, entitlement_id=credited.pk, awarded_points=300, response_snapshot=saved_receipt)
            MigrationExecutor(connection).migrate(latest)
            self.assertEqual(DocumentEntitlement.objects.get(pk=credited.pk).collected_at, entry.created_at)
            self.assertIsNone(DocumentEntitlement.objects.get(pk=pending.pk).collected_at)
            self.assertEqual(DocumentSubmission.objects.get().response_snapshot, saved_receipt)
            self.assertEqual(DocumentSubmission.objects.get().council_name, "")
            self.assertIsNone(DocumentSubmission.objects.get().registration_year)
            self.assertEqual(PointEntry.objects.count(), 1)
            self.assertEqual(PointEntry.objects.get().amount, 300)
        finally:
            MigrationExecutor(connection).migrate(latest)
