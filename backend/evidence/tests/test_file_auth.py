import base64
import tempfile
from datetime import timedelta
from uuid import uuid4

from django.contrib.auth import get_user_model
from django.test import override_settings
from django.utils import timezone
from rest_framework.test import APITestCase

from accounts.serializers import token_response
from dogs.models import Breed, Dog
from evidence.tests.test_documents import pdf_file
from quests.models import QuestDefinition


@override_settings(PASSWORD_HASHERS=["django.contrib.auth.hashers.MD5PasswordHasher"])
class PrivateDocumentSessionTests(APITestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        settings = override_settings(PRIVATE_MEDIA_ROOT=directory.name)
        settings.enable()
        self.addCleanup(settings.disable)
        User = get_user_model()
        self.owner = User.objects.create_user(email="document-token-owner@example.com", display_name="Owner")
        self.admin = User.objects.create_superuser(email="document-token-admin@example.com", display_name="Admin")
        breed = Breed.objects.create(name="Document auth breed", energy_level="LOW", default_size="SMALL")
        dog = Dog.objects.create(owner=self.owner, name="Coco", breed=breed, age_months=12, size="SMALL", is_brachycephalic=False)
        QuestDefinition.objects.update_or_create(code="DOCUMENTS", defaults={"title": "Documents", "is_enabled": True})
        self.original = pdf_file()
        self.client.force_authenticate(self.owner)
        response = self.client.post("/api/quests/documents", {
            "request_id": str(uuid4()), "dog_id": dog.pk, "kind": "COUNCIL_REGISTRATION",
            "registration_number": "00042", "council_name": "Melbourne City Council",
            "valid_to": (timezone.localdate() + timedelta(days=365)).isoformat(),
            "filename": "registration.pdf", "file_base64": base64.b64encode(self.original).decode(),
        }, format="json")
        self.assertEqual(response.status_code, 201)
        self.url = f"/api/quests/documents/{response.data['submission']['id']}/file"
        self.client.force_authenticate(user=None)

    def assert_download(self):
        response = self.client.get(self.url)
        self.assertEqual(response.status_code, 200)
        self.assertEqual(b"".join(response.streaming_content), self.original)

    def test_admin_preview_is_private_and_original_download_is_unchanged(self):
        self.assertEqual(self.client.get(self.url + "?preview=1").status_code, 401)
        self.client.force_login(self.admin)
        response = self.client.get(self.url + "?preview=1")
        self.assertEqual(response.status_code, 200)
        self.assertTrue(response["Content-Disposition"].startswith("inline"))
        self.assertEqual(response["Cache-Control"], "private, no-store")
        self.assertEqual(response["X-Content-Type-Options"], "nosniff")
        self.assertIn("sandbox", response["Content-Security-Policy"])
        self.assertEqual(b"".join(response.streaming_content), self.original)
        self.assert_download()

    def test_revoked_jwt_cannot_download_private_evidence_and_new_version_can(self):
        tokens = token_response(self.owner)
        self.client.credentials(HTTP_AUTHORIZATION=f"Bearer {tokens['access']}")
        self.assert_download()
        self.owner.auth_version += 1
        self.owner.save(update_fields=["auth_version"])
        self.assertEqual(self.client.get(self.url).status_code, 401)
        fresh = token_response(self.owner)
        self.client.credentials(HTTP_AUTHORIZATION=f"Bearer {fresh['access']}")
        self.assert_download()

    def test_tombstone_blocks_jwt_even_when_account_remains_active(self):
        tokens = token_response(self.owner)
        self.client.credentials(HTTP_AUTHORIZATION=f"Bearer {tokens['access']}")
        self.owner.deleted_at = timezone.now()
        self.owner.save(update_fields=["deleted_at"])
        self.assertTrue(self.owner.is_active)
        self.assertEqual(self.client.get(self.url).status_code, 401)

    def test_tombstone_blocks_existing_owner_and_admin_django_sessions(self):
        for user in (self.owner, self.admin):
            with self.subTest(role=user.role):
                self.client.force_login(user)
                self.assert_download()
                user.deleted_at = timezone.now()
                user.save(update_fields=["deleted_at"])
                self.assertEqual(self.client.get(self.url).status_code, 401)
                self.client.logout()
