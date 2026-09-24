from django.contrib.auth import get_user_model
from django.test import TestCase
from django.utils import timezone
from rest_framework.test import APIClient
from rest_framework_simplejwt.tokens import RefreshToken

from accounts.serializers import token_response


class SessionVersionTests(TestCase):
    def setUp(self):
        self.user = get_user_model().objects.create_user(email="session-version@example.com", display_name="Walker", password="A-test-password-572")
        self.api = APIClient()

    def access(self, token):
        self.api.credentials(HTTP_AUTHORIZATION=f"Bearer {token}")
        return self.api.get("/api/auth/me")

    def test_existing_tokens_work_until_account_version_changes(self):
        old = RefreshToken.for_user(self.user)
        self.assertEqual(self.access(str(old.access_token)).status_code, 200)
        self.user.auth_version += 1
        self.user.save(update_fields=("auth_version",))
        self.assertEqual(self.access(str(old.access_token)).status_code, 401)
        self.api.credentials()
        self.assertEqual(self.api.post("/api/auth/refresh", {"refresh": str(old)}).status_code, 401)
        fresh = token_response(self.user)
        self.assertEqual(self.access(fresh["access"]).status_code, 200)

    def test_tombstone_rejects_access_refresh_and_password_login(self):
        tokens = token_response(self.user)
        self.user.deleted_at = timezone.now()
        self.user.save(update_fields=("deleted_at",))
        self.assertEqual(self.access(tokens["access"]).status_code, 401)
        self.api.credentials()
        self.assertEqual(self.api.post("/api/auth/refresh", {"refresh": tokens["refresh"]}).status_code, 401)
        self.assertEqual(self.api.post("/api/auth/login", {"email": self.user.email, "password": "A-test-password-572"}).status_code, 401)

    def test_new_users_have_distinct_opaque_public_ids_and_private_defaults(self):
        other = get_user_model().objects.create_user(email="session-other@example.com", display_name="Other")
        self.assertNotEqual(self.user.public_id, other.public_id)
        self.assertEqual(len(self.user.public_id), 32)
        self.assertEqual(self.user.location_visibility, "OFF")
        self.assertFalse(self.user.net_matching_enabled)
        self.assertFalse(self.user.leaderboard_visible)
