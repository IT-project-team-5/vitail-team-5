from django.contrib.auth import get_user_model
from rest_framework import status
from rest_framework.test import APITestCase


User = get_user_model()


class AuthApiTests(APITestCase):
    register_url = "/api/auth/register"
    login_url = "/api/auth/login"
    refresh_url = "/api/auth/refresh"
    me_url = "/api/auth/me"
    password = "StrongPass123!"

    def register_owner(self, email="owner@example.com", display_name="Dog Owner"):
        return self.client.post(
            self.register_url,
            {
                "email": email,
                "password": self.password,
                "display_name": display_name,
            },
            format="json",
        )

    def test_owner_can_register_and_receives_owner_role(self):
        response = self.register_owner()

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(set(response.data), {"access", "refresh", "user"})
        self.assertEqual(response.data["user"]["email"], "owner@example.com")
        self.assertEqual(response.data["user"]["display_name"], "Dog Owner")
        self.assertEqual(response.data["user"]["role"], User.Role.OWNER)
        user = User.objects.get(email="owner@example.com")
        self.assertTrue(user.check_password(self.password))

    def test_public_registration_cannot_create_a_cafe_or_admin(self):
        response = self.client.post(
            self.register_url,
            {
                "email": "safe@example.com",
                "password": self.password,
                "display_name": "Safe Owner",
                "role": User.Role.ADMIN,
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_201_CREATED)
        self.assertEqual(response.data["user"]["role"], User.Role.OWNER)

    def test_owner_can_log_in(self):
        self.register_owner()

        response = self.client.post(
            self.login_url,
            {"email": "OWNER@example.com", "password": self.password},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["user"]["role"], User.Role.OWNER)
        self.assertIn("access", response.data)
        self.assertIn("refresh", response.data)

    def test_admin_created_cafe_can_log_in(self):
        User.objects.create_user(
            email="cafe@example.com",
            password=self.password,
            display_name="Vitail Café",
            role=User.Role.CAFE,
        )

        response = self.client.post(
            self.login_url,
            {"email": "cafe@example.com", "password": self.password},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["user"]["role"], User.Role.CAFE)

    def test_duplicate_email_is_rejected_case_insensitively(self):
        self.register_owner()

        response = self.register_owner(email="OWNER@EXAMPLE.COM")

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertIn("email", response.data)
        self.assertEqual(User.objects.count(), 1)

    def test_invalid_login_returns_a_clear_generic_error(self):
        response = self.client.post(
            self.login_url,
            {"email": "missing@example.com", "password": "WrongPass123!"},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_401_UNAUTHORIZED)
        self.assertEqual(response.data["detail"], "Invalid email or password.")

    def test_me_requires_authentication_and_returns_current_user(self):
        register_response = self.register_owner()

        unauthenticated_response = self.client.get(self.me_url)
        self.assertEqual(
            unauthenticated_response.status_code, status.HTTP_401_UNAUTHORIZED
        )

        self.client.credentials(
            HTTP_AUTHORIZATION=f"Bearer {register_response.data['access']}"
        )
        response = self.client.get(self.me_url)

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(
            response.data,
            {
                "id": User.objects.get(email="owner@example.com").id,
                "email": "owner@example.com",
                "display_name": "Dog Owner",
                "role": User.Role.OWNER,
            },
        )

    def test_refresh_returns_a_new_access_token(self):
        register_response = self.register_owner()

        response = self.client.post(
            self.refresh_url,
            {"refresh": register_response.data["refresh"]},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertIn("access", response.data)

    def test_authenticated_user_can_update_own_display_name(self):
        user = User.objects.create_user(
            email="profile@example.com",
            password=self.password,
            display_name="Before",
            role=User.Role.OWNER,
        )
        self.client.force_authenticate(user)

        response = self.client.patch(
            self.me_url,
            {"display_name": "  Cache  "},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["display_name"], "Cache")
        user.refresh_from_db()
        self.assertEqual(user.display_name, "Cache")

    def test_blank_display_name_is_rejected(self):
        user = User.objects.create_user(
            email="profile@example.com",
            password=self.password,
            display_name="Before",
        )
        self.client.force_authenticate(user)

        response = self.client.patch(
            self.me_url,
            {"display_name": "   "},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        user.refresh_from_db()
        self.assertEqual(user.display_name, "Before")

    def test_profile_patch_cannot_modify_role_or_email(self):
        user = User.objects.create_user(
            email="profile@example.com",
            password=self.password,
            display_name="Before",
            role=User.Role.OWNER,
        )
        self.client.force_authenticate(user)

        response = self.client.patch(
            self.me_url,
            {
                "display_name": "After",
                "email": "changed@example.com",
                "role": User.Role.ADMIN,
            },
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        user.refresh_from_db()
        self.assertEqual(user.email, "profile@example.com")
        self.assertEqual(user.role, User.Role.OWNER)
        self.assertEqual(user.display_name, "After")

    def test_profile_patch_requires_authentication(self):
        response = self.client.patch(
            self.me_url,
            {"display_name": "No Access"},
            format="json",
        )

        self.assertEqual(response.status_code, status.HTTP_401_UNAUTHORIZED)
