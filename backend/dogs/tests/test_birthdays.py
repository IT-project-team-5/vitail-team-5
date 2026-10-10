from datetime import date
from unittest.mock import patch

from django.core.exceptions import ValidationError
from django.db import connection
from django.db.migrations.executor import MigrationExecutor
from django.test import SimpleTestCase, TransactionTestCase
from rest_framework.test import APITestCase

from accounts.models import User
from dogs.models import Breed, Dog, age_in_months


class BirthdayAgeTests(SimpleTestCase):
    def test_completed_months_use_anniversary_day_and_month_end(self):
        for birthday, today, expected in (
            (date(2024, 9, 25), date(2026, 9, 24), 23),
            (date(2024, 9, 25), date(2026, 9, 25), 24),
            (date(2024, 9, 25), date(2026, 9, 26), 24),
            (date(2025, 1, 31), date(2025, 2, 27), 0),
            (date(2025, 1, 31), date(2025, 2, 28), 1),
            (date(2024, 2, 29), date(2025, 2, 27), 11),
            (date(2024, 2, 29), date(2025, 2, 28), 12),
            (date(2024, 2, 29), date(2028, 2, 28), 47),
            (date(2024, 2, 29), date(2028, 2, 29), 48),
            (date(2026, 9, 25), date(2026, 9, 25), 0),
        ):
            with self.subTest(birthday=birthday, today=today):
                self.assertEqual(age_in_months(birthday, today), expected)


@patch("django.utils.timezone.localdate", return_value=date(2026, 9, 25))
class BirthdayApiTests(APITestCase):
    @classmethod
    def setUpTestData(cls):
        cls.owner = User.objects.create_user(email="birthday-owner@example.com", display_name="Owner")
        cls.other = User.objects.create_user(email="birthday-other@example.com", display_name="Other")
        cls.breed = Breed.objects.create(name="Birthday breed", energy_level="LOW", default_size="SMALL")

    def setUp(self):
        self.client.force_authenticate(self.owner)

    def payload(self, **changes):
        data = {"name": "Coco", "breed_id": self.breed.pk, "size": "SMALL", "weight_kg": "8.00", "date_of_birth": "2024-09-25"}
        data.update(changes)
        return data

    def test_create_with_birthday_requires_no_static_age_and_ignores_stale_age(self, _today):
        response = self.client.post("/api/dogs", self.payload(age_months=999), format="json")
        self.assertEqual(response.status_code, 201)
        self.assertEqual(response.data["date_of_birth"], "2024-09-25")
        self.assertEqual(response.data["age_months"], 24)
        other = self.client.post("/api/dogs", self.payload(name="Luna"), format="json")
        self.assertEqual(other.status_code, 201)
        self.assertEqual(other.data["age_months"], 24)

    def test_future_or_invalid_birthday_is_rejected_without_creating_dog(self, _today):
        for birthday in ("2026-09-26", "2023-02-29", "2024-09-25T00:00:00Z", "not a date"):
            with self.subTest(birthday=birthday):
                response = self.client.post("/api/dogs", self.payload(date_of_birth=birthday), format="json")
                self.assertEqual(response.status_code, 400)
                self.assertIn("date_of_birth", response.data)
        self.assertEqual(Dog.objects.count(), 0)

    def test_age_recalculates_on_read_without_editing_profile(self, _today):
        dog = Dog.objects.create(owner=self.owner, breed=self.breed, name="Coco", age_months=1,
                                 date_of_birth=date(2024, 9, 26), size="SMALL", is_brachycephalic=False)
        self.assertEqual(self.client.get("/api/dogs").data[0]["age_months"], 23)
        with patch("django.utils.timezone.localdate", return_value=date(2026, 9, 26)):
            self.assertEqual(self.client.get("/api/dogs").data[0]["age_months"], 24)
        dog.refresh_from_db()
        self.assertEqual(dog.age_months, 1)  # Reads do not mutate legacy/cache fields.

    def test_legacy_age_create_and_profile_updates_never_infer_birthday(self, _today):
        data = self.payload(age_months=38)
        del data["date_of_birth"]
        created = self.client.post("/api/dogs", data, format="json")
        self.assertEqual(created.status_code, 201)
        self.assertIsNone(created.data["date_of_birth"])
        patched = self.client.patch(f"/api/dogs/{created.data['id']}", {"name": "New Name", "photo": "https://example.com/dog.jpg"}, format="json")
        self.assertEqual(patched.status_code, 200)
        self.assertIsNone(patched.data["date_of_birth"])
        self.assertEqual(patched.data["age_months"], 38)
        dog = Dog.objects.get(pk=created.data["id"])
        self.assertIsNone(dog.date_of_birth)

    def test_setting_birthday_overrides_age_and_remains_owner_scoped(self, _today):
        dog = Dog.objects.create(owner=self.owner, breed=self.breed, name="Coco", age_months=38,
                                 size="SMALL", is_brachycephalic=False)
        url = f"/api/dogs/{dog.pk}"
        response = self.client.patch(url, {"date_of_birth": "2024-02-29"}, format="json")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.data["age_months"], 30)
        age_edit = self.client.patch(url, {"age_months": 100}, format="json")
        self.assertEqual(age_edit.data["age_months"], 30)
        self.assertEqual(age_edit.data["date_of_birth"], "2024-02-29")
        self.client.force_authenticate(self.other)
        self.assertEqual(self.client.patch(url, {"date_of_birth": "2020-01-01"}, format="json").status_code, 404)
        dog.refresh_from_db()
        self.assertEqual(dog.date_of_birth, date(2024, 2, 29))

    def test_model_validation_used_by_admin_rejects_future_date(self, _today):
        dog = Dog(owner=self.owner, breed=self.breed, name="Coco", age_months=0,
                  date_of_birth=date(2026, 9, 26), size="SMALL", is_brachycephalic=False)
        with self.assertRaises(ValidationError) as caught:
            dog.full_clean()
        self.assertIn("date_of_birth", caught.exception.message_dict)


class BirthdayMigrationTests(TransactionTestCase):
    def test_legacy_profile_keeps_age_without_invented_birth_date(self):
        executor = MigrationExecutor(connection)
        latest = executor.loader.graph.leaf_nodes()
        before = [("dogs", "0002_dog_uploaded_photo")]
        try:
            executor.migrate(before)
            apps = executor.loader.project_state(before).apps
            user = apps.get_model("accounts", "User").objects.create(email="legacy-birthday@example.com", display_name="Legacy")
            breed = apps.get_model("dogs", "Breed").objects.create(name="Legacy birthday breed", energy_level="LOW", default_size="SMALL")
            old = apps.get_model("dogs", "Dog").objects.create(owner=user, breed=breed, name="Legacy Dog", age_months=38, size="SMALL", is_brachycephalic=False)
            MigrationExecutor(connection).migrate(latest)
            dog = Dog.objects.get(pk=old.pk)
            self.assertIsNone(dog.date_of_birth)
            self.assertEqual(dog.age_months, 38)
            self.assertEqual(dog.current_age_months, 38)
        finally:
            MigrationExecutor(connection).migrate(latest)
