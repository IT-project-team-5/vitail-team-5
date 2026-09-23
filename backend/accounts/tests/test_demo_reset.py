import io
import json
from pathlib import Path
import stat
from tempfile import TemporaryDirectory
from unittest.mock import patch
from uuid import uuid4
from datetime import timedelta

from django.contrib.admin.models import ADDITION, LogEntry
from django.contrib.contenttypes.models import ContentType
from django.contrib.sessions.models import Session
from django.core.management import call_command
from django.core.management.base import CommandError
from django.db import connection
from django.test import TestCase, override_settings
from django.utils import timezone

from accounts.models import CafeProfile, User
from dogs.models import Breed, Dog
from rewards.models import CafeOrderFeedState, PointEntry, Redemption, Reward
from rewards.services import create_redemption, credit_points, get_balance
from walks.models import Walk


@override_settings(DEBUG=True, PASSWORD_HASHERS=["django.contrib.auth.hashers.MD5PasswordHasher"])
class DemoResetTests(TestCase):
    @classmethod
    def setUpTestData(cls):
        cls.owner = User.objects.create_user(email="old-owner@example.com", display_name="Old Owner")
        cls.admin = User.objects.create_superuser(email="old-admin@example.com", display_name="Old Admin")
        cls.cafe = User.objects.create_user(
            email="old-cafe@example.com", display_name="Old Café", role=User.Role.CAFE,
        )
        CafeProfile.objects.create(user=cls.cafe, description="Old profile")
        cls.breed = Breed.objects.create(name="Reference breed", energy_level="LOW", default_size="SMALL")
        cls.dog = Dog.objects.create(
            owner=cls.owner, name="Old Dog", breed=cls.breed,
            age_months=24, size="SMALL", is_brachycephalic=False,
        )
        now = timezone.now()
        cls.walk = Walk.objects.create(
            owner=cls.owner, request_id=uuid4(), request_fingerprint="old-fingerprint",
            started_at=now - timedelta(minutes=30), ended_at=now,
            point_date=now.date(), distance_m=1000, points_awarded=10,
        )
        cls.walk.dogs.add(cls.dog)
        cls.reward = Reward.objects.create(cafe_user=cls.cafe, name="Old Coffee", point_cost=40)
        credit_points(user=cls.owner, amount=100)
        cls.order = create_redemption(owner=cls.owner, reward_id=cls.reward.pk)
        cls.session = Session.objects.create(
            session_key="old-session", session_data="old-session-data", expire_date=now + timedelta(days=1),
        )
        cls.log = LogEntry.objects.create(
            user=cls.admin, content_type=ContentType.objects.get_for_model(Reward),
            object_id=str(cls.reward.pk), object_repr="Old Coffee", action_flag=ADDITION,
        )

    def setUp(self):
        directory = TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.credentials = Path(directory.name) / "demo-credentials.json"
        self.output = io.StringIO()
        self.previous_data = self.snapshot()

    @staticmethod
    def snapshot():
        return {
            model._meta.label: list(model.objects.order_by("pk").values())
            for model in (
                User, CafeProfile, Breed, Dog, Walk, Walk.dogs.through,
                Reward, Redemption, PointEntry, CafeOrderFeedState, Session, LogEntry,
            )
        }

    def reset(self, **kwargs):
        options = {
            "confirm_database": str(connection.settings_dict["NAME"]),
            "credentials_file": str(self.credentials),
            "stdout": self.output,
        }
        options.update(kwargs)
        call_command("reset_demo_data", **options)

    def assert_previous_data_unchanged(self):
        self.assertEqual(self.snapshot(), self.previous_data)

    def test_wrong_database_confirmation_does_not_create_file_or_delete_data(self):
        with self.assertRaisesMessage(CommandError, "exactly match"):
            self.reset(confirm_database="definitely-not-this-database")
        self.assertFalse(self.credentials.exists())
        self.assert_previous_data_unchanged()

    @override_settings(DEBUG=False)
    def test_production_guard_prevents_reset(self):
        with self.assertRaisesMessage(CommandError, "DEBUG=False"):
            self.reset()
        self.assertFalse(self.credentials.exists())
        self.assert_previous_data_unchanged()

    def test_confirmation_and_credentials_path_are_required(self):
        for omitted in ("confirm_database", "credentials_file"):
            options = {
                "confirm_database": str(connection.settings_dict["NAME"]),
                "credentials_file": str(self.credentials),
            }
            del options[omitted]
            with self.subTest(omitted=omitted), self.assertRaises(CommandError):
                call_command("reset_demo_data", **options)
        self.assertFalse(self.credentials.exists())
        self.assert_previous_data_unchanged()

    def test_existing_credentials_file_is_never_overwritten(self):
        self.credentials.write_text("preserve these credentials", encoding="utf-8")
        with self.assertRaisesMessage(CommandError, "Cannot create a new credentials file"):
            self.reset()
        self.assertEqual(self.credentials.read_text(), "preserve these credentials")
        self.assert_previous_data_unchanged()

    def test_credentials_symlink_is_not_followed(self):
        target = self.credentials.with_name("existing-private-file.json")
        target.write_text("private existing contents", encoding="utf-8")
        self.credentials.symlink_to(target)
        with self.assertRaises(CommandError):
            self.reset()
        self.assertEqual(target.read_text(), "private existing contents")
        self.assertTrue(self.credentials.is_symlink())
        self.assert_previous_data_unchanged()

    def test_missing_credentials_parent_prevents_any_database_changes(self):
        with self.assertRaises(CommandError):
            self.reset(credentials_file=str(self.credentials.parent / "missing" / "credentials.json"))
        self.assert_previous_data_unchanged()

    def test_invalid_point_amount_prevents_reset(self):
        for amount in (0, -1, 1_000_001):
            with self.subTest(amount=amount), self.assertRaisesMessage(CommandError, "--owner-points"):
                self.reset(owner_points=amount)
        self.assertFalse(self.credentials.exists())
        self.assert_previous_data_unchanged()

    def test_seed_failure_restores_all_old_data_and_removes_credentials(self):
        with patch(
            "accounts.management.commands.reset_demo_data.credit_points",
            side_effect=RuntimeError("simulated seed failure"),
        ), self.assertRaisesMessage(RuntimeError, "simulated seed failure"):
            self.reset()
        self.assertFalse(self.credentials.exists())
        self.assert_previous_data_unchanged()

    def test_credentials_write_failure_rolls_back_reset(self):
        with patch(
            "accounts.management.commands.reset_demo_data.json.dump",
            side_effect=OSError("simulated disk full"),
        ), self.assertRaisesMessage(OSError, "simulated disk full"):
            self.reset()
        self.assertFalse(self.credentials.exists())
        self.assert_previous_data_unchanged()

    def test_credentials_sync_failure_rolls_back_reset(self):
        with patch(
            "accounts.management.commands.reset_demo_data.os.fsync",
            side_effect=OSError("simulated sync failure"),
        ), self.assertRaisesMessage(OSError, "simulated sync failure"):
            self.reset()
        self.assertFalse(self.credentials.exists())
        self.assert_previous_data_unchanged()

    def test_success_creates_exact_accounts_catalogue_and_private_credentials(self):
        old_user_ids = set(User.objects.values_list("pk", flat=True))
        before = timezone.now()
        self.reset()
        self.assertEqual(User.objects.count(), 5)
        self.assertEqual(User.objects.filter(role=User.Role.OWNER).count(), 1)
        self.assertEqual(User.objects.filter(role=User.Role.ADMIN).count(), 1)
        self.assertEqual(User.objects.filter(role=User.Role.CAFE).count(), 3)
        self.assertFalse(old_user_ids & set(User.objects.values_list("pk", flat=True)))
        owner = User.objects.get(email="owner@vitail.test")
        admin = User.objects.get(email="admin@vitail.test")
        self.assertEqual((admin.is_staff, admin.is_superuser, admin.is_active), (True, True, True))
        self.assertEqual(User.objects.filter(is_staff=True).count(), 1)
        self.assertEqual(User.objects.filter(is_superuser=True).count(), 1)
        self.assertEqual(get_balance(owner), 10000)
        grant = PointEntry.objects.get()
        self.assertEqual((grant.user_id, grant.amount, grant.remaining_points, grant.type),
                         (owner.pk, 10000, 10000, PointEntry.Type.ADMIN))
        self.assertGreater(grant.expires_at, before + timedelta(days=364))
        self.assertLess(grant.expires_at, timezone.now() + timedelta(days=367))
        self.assertEqual(CafeProfile.objects.count(), 3)
        self.assertEqual(Reward.objects.count(), 15)
        for cafe in User.objects.filter(role=User.Role.CAFE):
            with self.subTest(cafe=cafe.email):
                profile = cafe.cafe_profile
                self.assertGreater(len(profile.description), 100)
                self.assertTrue(profile.address)
                self.assertTrue(profile.opening_hours)
                self.assertEqual(cafe.rewards.count(), 5)
                for reward in cafe.rewards.all():
                    self.assertTrue(reward.description)
                    self.assertTrue(reward.is_available)
                    self.assertGreaterEqual(reward.point_cost, 40)
                    self.assertLessEqual(reward.point_cost, 180)
        for model in (Dog, Walk, Walk.dogs.through, Redemption, CafeOrderFeedState, Session, LogEntry):
            with self.subTest(model=model._meta.label):
                self.assertEqual(model.objects.count(), 0)
        self.assertEqual(list(Breed.objects.order_by("pk").values()), self.previous_data["dogs.Breed"])
        self.assertEqual(stat.S_IMODE(self.credentials.stat().st_mode), 0o600)
        credentials = json.loads(self.credentials.read_text())
        self.assertIn("FICTIONAL", credentials["notice"])
        self.assertEqual(credentials["owner_points"], 10000)
        self.assertEqual(len(credentials["accounts"]), 5)
        passwords = [account["password"] for account in credentials["accounts"]]
        self.assertEqual(len(set(passwords)), 5)
        for account in credentials["accounts"]:
            user = User.objects.get(email=account["email"])
            self.assertEqual(account["role"], user.role)
            self.assertEqual(account["cafe_name"], user.display_name if user.role == User.Role.CAFE else None)
            self.assertGreaterEqual(len(account["password"]), 32)
            self.assertTrue(user.check_password(account["password"]))
            self.assertNotIn(account["password"], self.output.getvalue())
        self.assertIn(str(self.credentials), self.output.getvalue())

    def test_owner_points_can_be_customized(self):
        self.reset(owner_points=25000)
        self.assertEqual(get_balance(User.objects.get(email="owner@vitail.test")), 25000)
        self.assertEqual(json.loads(self.credentials.read_text())["owner_points"], 25000)
