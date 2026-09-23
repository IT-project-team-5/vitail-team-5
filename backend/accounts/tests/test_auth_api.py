from concurrent.futures import ThreadPoolExecutor
from threading import Barrier
from unittest import skipUnless
from unittest.mock import patch

from django.contrib.auth import get_user_model
from django.db import IntegrityError, close_old_connections, connection
from django.test import TransactionTestCase
from rest_framework import status
from rest_framework.test import APIClient, APITestCase

from accounts.serializers import RegisterSerializer


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

    def test_registration_preserves_password_whitespace_for_login(self):
        passwords = (
            "  River!Orchid9-Train",
            "River!Orchid9-Train  ",
            "  River!Orchid9-Train  ",
        )
        for index, password in enumerate(passwords):
            with self.subTest(password=password):
                email = f"whitespace{index}@example.com"
                register_response = self.client.post(
                    self.register_url,
                    {
                        "email": email,
                        "password": password,
                        "display_name": "Dog Owner",
                    },
                    format="json",
                )

                self.assertEqual(
                    register_response.status_code, status.HTTP_201_CREATED
                )
                login_response = self.client.post(
                    self.login_url,
                    {"email": email, "password": password},
                    format="json",
                )

                self.assertEqual(login_response.status_code, status.HTTP_200_OK)
                trimmed_login_response = self.client.post(
                    self.login_url,
                    {"email": email, "password": password.strip()},
                    format="json",
                )

                self.assertEqual(
                    trimmed_login_response.status_code, status.HTTP_401_UNAUTHORIZED
                )

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

    def test_duplicate_email_after_validation_returns_the_normal_error(self):
        self.register_owner()
        expected = self.register_owner()

        # Simulate a request whose email check passed before the other insert.
        with patch.object(
            RegisterSerializer, "validate_email", return_value="owner@example.com"
        ):
            response = self.register_owner()

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(response.json(), expected.json())
        self.assertEqual(User.objects.count(), 1)

    def test_registration_does_not_hide_unrelated_integrity_errors(self):
        self.register_owner()
        errors = (
            IntegrityError(1062, "Duplicate entry '1' for key 'accounts_user.PRIMARY'"),
            IntegrityError(1048, "Column 'display_name' cannot be null"),
            IntegrityError("FOREIGN KEY constraint failed"),
        )
        for error in errors:
            with self.subTest(error=error):
                with patch.object(User.objects, "create_user", side_effect=error):
                    with self.assertRaises(IntegrityError) as raised:
                        RegisterSerializer().create(
                            {
                                "email": "owner@example.com",
                                "password": self.password,
                                "display_name": "Dog Owner",
                            }
                        )
                self.assertIs(raised.exception, error)
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


@skipUnless(connection.vendor == "mysql", "Requires MySQL concurrency semantics")
class RegistrationConcurrencyTests(TransactionTestCase):
    def test_concurrent_duplicate_email_returns_validation_error(self):
        barrier = Barrier(2)
        validate_email = RegisterSerializer.validate_email

        def validate_before_either_insert(serializer, value):
            email = validate_email(serializer, value)
            barrier.wait(timeout=10)
            return email

        def register():
            close_old_connections()
            try:
                return APIClient(raise_request_exception=False).post(
                    "/api/auth/register",
                    {
                        "email": "concurrent-owner@example.com",
                        "password": "StrongPass123!",
                        "display_name": "Dog Owner",
                    },
                    format="json",
                )
            finally:
                close_old_connections()

        with patch.object(
            RegisterSerializer, "validate_email", validate_before_either_insert
        ):
            with ThreadPoolExecutor(max_workers=2) as pool:
                futures = [pool.submit(register) for _ in range(2)]
                responses = [future.result(timeout=30) for future in futures]

        self.assertEqual(User.objects.count(), 1)
        self.assertEqual(
            sorted(response.status_code for response in responses),
            [status.HTTP_201_CREATED, status.HTTP_400_BAD_REQUEST],
        )
        for response in responses:
            self.assertEqual(response["Content-Type"], "application/json")
        rejected = next(
            response
            for response in responses
            if response.status_code == status.HTTP_400_BAD_REQUEST
        )
        self.assertEqual(
            rejected.json(),
            {"email": ["An account with this email already exists."]},
        )
