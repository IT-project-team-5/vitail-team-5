from concurrent.futures import ThreadPoolExecutor
from datetime import date, datetime, timedelta, timezone as dt_timezone
from threading import Barrier
from unittest import skipUnless
from unittest.mock import patch
from uuid import uuid4
from zoneinfo import ZoneInfo

from django.contrib.auth import get_user_model
from django.db import IntegrityError, close_old_connections, connection, transaction
from django.test import TransactionTestCase, override_settings
from rest_framework.test import APIClient, APITestCase

from dogs.models import Breed, Dog
from quests.models import QuestAward, QuestDefinition
from rewards.models import PointEntry
from rewards.services import credit_points, get_balance


MELBOURNE = ZoneInfo("Australia/Melbourne")
User = get_user_model()


class QuestApiTests(APITestCase):
    @classmethod
    def setUpTestData(cls):
        cls.owner = User.objects.create_user(email="quest-owner@example.com", password="QuestTest572!", display_name="Walker")
        cls.other_owner = User.objects.create_user(email="quest-other@example.com", password="QuestTest572!", display_name="Private Walker")
        cls.cafe = User.objects.create_user(email="quest-cafe@example.com", password="QuestTest572!", display_name="Cafe", role=User.Role.CAFE)
        cls.admin = User.objects.create_user(email="quest-admin@example.com", password="QuestTest572!", display_name="Admin", role=User.Role.ADMIN)
        breed = Breed.objects.create(name="Quest Breed", energy_level="MODERATE", default_size="SMALL")
        cls.dog = Dog.objects.create(owner=cls.owner, breed=breed, name="Milo", date_of_birth=date(2020, 9, 25), age_months=72, size="SMALL", is_brachycephalic=False)
        cls.second_dog = Dog.objects.create(owner=cls.owner, breed=breed, name="Pip", age_months=24, size="SMALL", is_brachycephalic=False)
        cls.other_dog = Dog.objects.create(owner=cls.other_owner, breed=breed, name="Private Dog", date_of_birth=date(2021, 9, 25), age_months=60, size="SMALL", is_brachycephalic=False)

    def setUp(self):
        self.now = datetime(2026, 9, 25, 12, tzinfo=MELBOURNE)
        clock = patch("quests.services.timezone.now", side_effect=lambda: self.now)
        clock.start()
        self.addCleanup(clock.stop)
        self.client.force_authenticate(self.owner)

    def collect(self, dog=None):
        return self.client.post(f"/api/quests/birthdays/{(dog or self.dog).pk}/collect/", {}, format="json")

    def dashboard(self):
        response = self.client.get("/api/quests/")
        self.assertEqual(response.status_code, 200)
        return response.data

    def test_catalogue_is_typed_and_has_no_duplicate_base_walk_task(self):
        self.assertEqual(set(QuestDefinition.objects.values_list("code", flat=True)), {"DAILY_GOAL", "STREAK", "BIRTHDAY", "CHECK_IN", "DOCUMENTS"})
        self.assertFalse(QuestDefinition.objects.filter(code="WALK").exists())

    def test_owner_auth_required_for_dashboard_and_collect(self):
        paths = ("/api/quests", "/api/quests/")
        public = APIClient()
        for path in paths:
            with self.subTest(path=path):
                self.assertEqual(public.get(path).status_code, 401)
        self.assertEqual(public.post(f"/api/quests/birthdays/{self.dog.pk}/collect/").status_code, 401)
        for role in (self.cafe, self.admin):
            self.client.force_authenticate(role)
            self.assertEqual(self.client.get("/api/quests/").status_code, 403)
            self.assertEqual(self.collect().status_code, 403)

    def test_new_owner_receives_only_the_compact_envelope_without_fake_tasks(self):
        fresh = User.objects.create_user(email="quest-new@example.com", password="QuestTest572!", display_name="New")
        self.client.force_authenticate(fresh)
        data = self.dashboard()
        self.assertEqual(set(data), {"server_time", "timezone", "local_date", "next_reset_at", "tasks"})
        self.assertEqual(data["tasks"], [])
        self.assertFalse(QuestAward.objects.exists())
        self.assertFalse(PointEntry.objects.exists())

    def test_catalogue_can_disable_a_capability_without_changing_qualification_rules(self):
        QuestDefinition.objects.filter(code__in=["DAILY_GOAL", "BIRTHDAY", "DOCUMENTS"]).update(is_enabled=False)
        self.assertEqual(self.dashboard()["tasks"], [])
        self.assertEqual(self.collect().data["code"], "QUEST_DISABLED")
        self.assertFalse(PointEntry.objects.exists())

    @override_settings(TIME_ZONE="UTC")
    def test_reset_boundary_uses_melbourne_across_daylight_saving(self):
        self.now = datetime(2026, 10, 3, 14, 30, tzinfo=dt_timezone.utc)
        data = self.dashboard()
        self.assertEqual(data["timezone"], "Australia/Melbourne")
        self.assertEqual(data["local_date"], "2026-10-04")
        reset = datetime.fromisoformat(data["next_reset_at"].replace("Z", "+00:00"))
        self.assertEqual(reset, datetime(2026, 10, 4, 13, tzinfo=dt_timezone.utc))

    def test_birthday_tasks_skip_missing_birthdays_and_use_the_actual_leap_anniversary(self):
        birthdays = [task for task in self.dashboard()["tasks"] if task["kind"] == "BIRTHDAY"]
        self.assertEqual([task["dog_id"] for task in birthdays], [self.dog.pk])
        self.assertEqual(birthdays[0]["status"], "READY")
        self.assertEqual(birthdays[0]["reward_points"], 60)
        self.dog.date_of_birth = date(2020, 2, 29)
        self.dog.save(update_fields=["date_of_birth"])
        for day in (date(2027, 2, 28), date(2027, 3, 1)):
            with self.subTest(day=day):
                self.now = datetime.combine(day, datetime.min.time().replace(hour=12), tzinfo=MELBOURNE)
                self.assertFalse(any(task["kind"] == "BIRTHDAY" for task in self.dashboard()["tasks"]))
                self.assertEqual(self.collect().data["code"], "BIRTHDAY_NOT_TODAY")
        self.assertFalse(PointEntry.objects.exists())
        self.now = datetime(2028, 2, 29, 12, tzinfo=MELBOURNE)
        birthdays = [task for task in self.dashboard()["tasks"] if task["kind"] == "BIRTHDAY"]
        self.assertEqual([task["dog_id"] for task in birthdays], [self.dog.pk])
        self.assertEqual(self.collect().status_code, 201)

    def test_birthday_collection_credits_sixty_and_retries_return_one_canonical_award(self):
        first = self.collect()
        self.assertEqual(first.status_code, 201)
        self.assertTrue(first.data["created"])
        self.assertEqual(first.data["balance"], 60)
        self.assertEqual(first.data["award"]["points"], 60)
        self.assertEqual(first.data["award"]["year"], 2026)
        repeated = self.collect()
        self.assertEqual(repeated.status_code, 200)
        self.assertFalse(repeated.data["created"])
        self.assertEqual(repeated.data["award"], first.data["award"])
        self.assertEqual(QuestAward.objects.count(), 1)
        self.assertEqual(PointEntry.objects.count(), 1)
        self.assertEqual(get_balance(self.owner), 60)
        birthday = next(task for task in self.dashboard()["tasks"] if task["kind"] == "BIRTHDAY")
        self.assertEqual(birthday["status"], "COLLECTED")
        entry = PointEntry.objects.get()
        self.assertEqual(entry.type, PointEntry.Type.EARN)
        self.assertEqual(entry.source_reference, f"birthday:{self.dog.pk}:2026")

    def test_transferred_dog_keeps_annual_entitlement_without_exposing_prior_receipt(self):
        original = self.collect()
        self.dog.owner = self.other_owner
        self.dog.save(update_fields=["owner"])
        self.client.force_authenticate(self.other_owner)
        self.assertFalse(any(task["kind"] == "BIRTHDAY" and task["dog_id"] == self.dog.pk
                             for task in self.dashboard()["tasks"]))
        blocked = self.collect()
        self.assertEqual(blocked.status_code, 409)
        self.assertEqual(blocked.data["code"], "BIRTHDAY_ALREADY_CLAIMED")
        self.assertEqual(set(blocked.data), {"code", "message"})
        self.assertEqual(get_balance(self.owner), 60)
        self.assertEqual(get_balance(self.other_owner), 0)
        self.assertEqual(QuestAward.objects.count(), 1)
        # An original recipient can still recover their own successful receipt.
        self.client.force_authenticate(self.owner)
        replay = self.collect()
        self.assertEqual(replay.status_code, 200)
        self.assertEqual(replay.data["award"], original.data["award"])
        self.assertEqual(replay.data["balance"], 60)
        self.assertFalse(replay.data["created"])
        # The new owner can claim the next year's independent entitlement.
        self.client.force_authenticate(self.other_owner)
        self.now = self.now.replace(year=2027)
        self.assertEqual(self.collect().status_code, 201)
        self.assertEqual(get_balance(self.other_owner), 60)

    def test_unrelated_owner_cannot_discover_another_dogs_claim(self):
        self.collect()
        self.client.force_authenticate(self.other_owner)
        response = self.collect()
        self.assertEqual(response.status_code, 404)
        self.assertEqual(response.data["code"], "DOG_NOT_FOUND")
        self.assertEqual(set(response.data), {"code", "message"})

    def test_original_award_replay_after_dog_deletion_keeps_original_dog_id(self):
        original = self.collect()
        dog_id = self.dog.pk
        self.dog.delete()
        repeated = self.client.post(f"/api/quests/birthdays/{dog_id}/collect/", {}, format="json")
        self.assertEqual(repeated.status_code, 200)
        self.assertFalse(repeated.data["created"])
        self.assertEqual(repeated.data["award"], original.data["award"])
        self.assertEqual(repeated.data["award"]["dog_id"], dog_id)
        self.assertEqual(repeated.data["balance"], 60)

    def test_changing_birth_date_cannot_collect_twice_in_one_year(self):
        first = self.collect()
        self.dog.date_of_birth = date(2020, 9, 26)
        self.dog.save(update_fields=["date_of_birth"])
        self.now += timedelta(days=1)
        repeated = self.collect()
        self.assertEqual(repeated.status_code, 200)
        self.assertEqual(repeated.data["award"]["id"], first.data["award"]["id"])
        self.assertEqual(get_balance(self.owner), 60)

    def test_birthday_collect_uses_melbourne_date_and_new_year_can_receive_new_award(self):
        self.now = datetime(2026, 9, 24, 14, tzinfo=dt_timezone.utc)
        self.assertEqual(self.collect().status_code, 201)
        self.now = datetime(2027, 9, 25, 12, tzinfo=MELBOURNE)
        second = self.collect()
        self.assertEqual(second.status_code, 201)
        self.assertEqual(second.data["award"]["year"], 2027)
        self.assertEqual(QuestAward.objects.count(), 2)

    def test_collect_rejects_missing_birthdays_other_owners_and_non_birthday(self):
        response = self.collect(self.second_dog)
        self.assertEqual(response.status_code, 400)
        self.assertEqual(response.data["code"], "BIRTHDAY_REQUIRED")
        other = self.collect(self.other_dog)
        self.assertEqual(other.status_code, 404)
        self.assertEqual(other.data["code"], "DOG_NOT_FOUND")
        self.now += timedelta(days=1)
        self.assertEqual(self.collect().status_code, 409)
        self.assertFalse(PointEntry.objects.exists())

    def test_directly_persisted_future_birthday_cannot_appear_eligible_or_award_points(self):
        # Imports and direct ORM writes do not run the API's DOB validator.
        Dog.objects.filter(pk=self.dog.pk).update(date_of_birth=date(2027, 9, 25))
        self.assertFalse(any(task["kind"] == "BIRTHDAY" for task in self.dashboard()["tasks"]))
        response = self.collect()
        self.assertEqual(response.status_code, 400)
        self.assertEqual(response.data["code"], "BIRTHDAY_IN_FUTURE")
        self.assertFalse(QuestAward.objects.exists())
        self.assertFalse(PointEntry.objects.exists())

    def test_successful_award_retry_remains_idempotent_after_invalid_birth_date_write(self):
        original = self.collect()
        Dog.objects.filter(pk=self.dog.pk).update(date_of_birth=date(2027, 9, 25))
        repeated = self.collect()
        self.assertEqual(repeated.status_code, 200)
        self.assertFalse(repeated.data["created"])
        self.assertEqual(repeated.data["award"], original.data["award"])
        self.assertEqual(get_balance(self.owner), 60)
        birthday = next(task for task in self.dashboard()["tasks"] if task["kind"] == "BIRTHDAY")
        self.assertEqual(birthday["status"], "COLLECTED")
        self.assertEqual(birthday["dog_id"], self.dog.pk)

    def test_award_failure_rolls_back_wallet_credit(self):
        with patch("quests.services.QuestAward.objects.create", side_effect=RuntimeError("storage failure")):
            with self.assertRaises(RuntimeError):
                self.collect()
        self.assertFalse(QuestAward.objects.exists())
        self.assertFalse(PointEntry.objects.exists())

    def test_collection_reuses_a_persisted_ready_qualification(self):
        award = QuestAward.objects.create(
            owner=self.owner, kind="BIRTHDAY", dog=self.dog,
            dog_id_snapshot=self.dog.pk, dog_name_snapshot=self.dog.name,
            year=2026, qualification_key=f"birthday:{self.dog.pk}:2026",
            promised_points=60, rules_version="birthday-2026-09-25",
            qualified_on=self.now.date(), qualified_at=self.now - timedelta(minutes=1),
        )
        response = self.collect()
        self.assertEqual(response.status_code, 201)
        self.assertEqual(response.data["award"]["id"], award.pk)
        self.assertEqual(QuestAward.objects.count(), 1)
        self.assertEqual(PointEntry.objects.count(), 1)
        self.assertEqual(self.collect().status_code, 200)

    def test_expired_qualification_does_not_credit_wallet(self):
        QuestAward.objects.create(
            owner=self.owner, kind="BIRTHDAY", dog=self.dog,
            dog_id_snapshot=self.dog.pk, dog_name_snapshot=self.dog.name,
            year=2026, qualification_key=f"birthday:{self.dog.pk}:2026",
            promised_points=60, rules_version="birthday-2026-09-25",
            qualified_on=self.now.date(), qualified_at=self.now - timedelta(hours=1),
            claim_expires_at=self.now,
        )
        self.assertEqual(self.collect().data["code"], "QUALIFICATION_UNAVAILABLE")
        self.assertFalse(PointEntry.objects.exists())
        self.assertFalse(any(task["kind"] == "BIRTHDAY" for task in self.dashboard()["tasks"]))

    def test_award_survives_dog_deletion_and_database_rejects_duplicate_qualification(self):
        self.collect()
        award = QuestAward.objects.get()
        new_entry = credit_points(user=self.other_owner, amount=60, source_reference="test:duplicate-qualification")
        with self.assertRaises(IntegrityError), transaction.atomic():
            QuestAward.objects.create(
                owner=self.other_owner, kind="BIRTHDAY", dog=self.dog,
                dog_id_snapshot=self.dog.pk, dog_name_snapshot=self.dog.name,
                year=2026, point_entry=new_entry, rules_version="test",
                qualification_key=f"birthday:{self.dog.pk}:2026", promised_points=60,
                qualified_on=self.now.date(), qualified_at=self.now, awarded_at=self.now,
            )
        original_id = self.dog.pk
        self.dog.delete()
        award.refresh_from_db()
        self.assertIsNone(award.dog_id)
        self.assertEqual(award.dog_id_snapshot, original_id)
        self.assertEqual(award.point_entry.amount, 60)

    def test_dog_photos_prefer_uploaded_files_and_make_relative_urls_absolute(self):
        self.dog.photo = "https://example.com/legacy.jpg"
        self.dog.uploaded_photo = "avatars/dogs/milo.jpg"
        self.dog.save(update_fields=["photo", "uploaded_photo"])
        data = self.dashboard()
        expected = "http://testserver/media/avatars/dogs/milo.jpg"
        rows = [task for task in data["tasks"] if task["dog_id"] == self.dog.pk]
        self.assertTrue(rows)
        self.assertEqual({task["photo"] for task in rows}, {expected})

    def test_tasks_show_only_today_birthday_and_omit_unavailable_goal_and_streak_actions(self):
        tasks = self.dashboard()["tasks"]
        birthday = [task for task in tasks if task["kind"] == "BIRTHDAY"]
        self.assertEqual(len(birthday), 1)
        self.assertEqual(birthday[0]["id"], f"birthday:{self.dog.pk}:2026")
        self.assertEqual(birthday[0]["status"], "READY")
        self.assertEqual(birthday[0]["subject_name"], "Milo")
        self.assertEqual(birthday[0]["reward_points"], 60)
        self.assertIsNone(birthday[0]["progress"])
        self.assertIsNone(birthday[0]["collected_at"])
        self.assertNotIn("DAILY_GOAL", {task["kind"] for task in tasks})
        self.assertNotIn("STREAK", {task["kind"] for task in tasks})
        self.assertNotIn(self.other_dog.pk, {task["dog_id"] for task in tasks})
        self.assertEqual(len({task["id"] for task in tasks}), len(tasks))
        Dog.objects.filter(pk=self.dog.pk).update(date_of_birth=date(2020, 9, 26))
        self.assertFalse(any(task["kind"] == "BIRTHDAY" for task in self.dashboard()["tasks"]))

    def test_today_collected_task_keeps_identity_at_bottom_then_disappears_next_day(self):
        self.collect()
        tasks = self.dashboard()["tasks"]
        collected = [task for task in tasks if task["kind"] == "BIRTHDAY"]
        self.assertEqual(len(collected), 1)
        self.assertEqual(collected[0]["id"], f"birthday:{self.dog.pk}:2026")
        self.assertEqual(collected[0]["status"], "COLLECTED")
        self.assertEqual(datetime.fromisoformat(collected[0]["collected_at"]), self.now)
        self.assertEqual(tasks[-1]["id"], collected[0]["id"])
        self.now += timedelta(days=1)
        self.assertFalse(any(task["kind"] == "BIRTHDAY" for task in self.dashboard()["tasks"]))

    def test_collected_birthday_stays_for_original_recipient_after_dog_transfer_or_deletion(self):
        self.collect()
        self.dog.owner = self.other_owner
        self.dog.save(update_fields=["owner"])
        own_tasks = [task for task in self.dashboard()["tasks"] if task["kind"] == "BIRTHDAY"]
        self.assertEqual(len(own_tasks), 1)
        self.assertEqual(own_tasks[0]["subject_name"], "Milo")
        self.assertEqual(own_tasks[0]["status"], "COLLECTED")
        self.client.force_authenticate(self.other_owner)
        self.assertFalse(any(task["kind"] == "BIRTHDAY" and task["dog_id"] == self.dog.pk for task in self.dashboard()["tasks"]))
        self.client.force_authenticate(self.owner)
        self.dog.delete()
        after_delete = [task for task in self.dashboard()["tasks"] if task["kind"] == "BIRTHDAY"]
        self.assertEqual(after_delete[0]["id"], own_tasks[0]["id"])

    @override_settings(TIME_ZONE="UTC")
    def test_collected_task_visibility_resets_at_melbourne_midnight_not_utc_midnight(self):
        self.now = datetime(2026, 9, 25, 13, 59, tzinfo=dt_timezone.utc)  # 23:59 Melbourne
        self.collect()
        self.assertTrue(any(task["kind"] == "BIRTHDAY" for task in self.dashboard()["tasks"]))
        self.now += timedelta(minutes=1)
        self.assertEqual(self.dashboard()["local_date"], "2026-09-26")
        self.assertFalse(any(task["kind"] == "BIRTHDAY" for task in self.dashboard()["tasks"]))

    def test_disabled_capabilities_do_not_offer_actionable_task_rows(self):
        QuestDefinition.objects.filter(code__in=["BIRTHDAY", "DOCUMENTS"]).update(is_enabled=False)
        self.assertEqual(self.dashboard()["tasks"], [])

    def test_document_submission_becomes_ready_until_explicit_collect_and_only_today_receipt_remains(self):
        from evidence.models import DocumentEntitlement

        submitted = self.client.post("/api/quests/documents", {
            "request_id": str(uuid4()), "dog_id": self.dog.pk,
            "kind": "COUNCIL_REGISTRATION", "registration_number": "TASK-123",
            "council_name": "City of Melbourne", "registration_year": 2027,
        }, format="json")
        self.assertEqual(submitted.status_code, 201)
        entitlement = DocumentEntitlement.objects.get(dog_id_snapshot=self.dog.pk, kind="COUNCIL_REGISTRATION")
        self.assertEqual(get_balance(self.owner), 0)
        tasks = self.dashboard()["tasks"]
        rows = [task for task in tasks if task["kind"] == "COUNCIL_REGISTRATION" and task["dog_id"] == self.dog.pk]
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["status"], "READY")
        self.assertEqual(rows[0]["entitlement_id"], entitlement.pk)
        collected = self.client.post(f"/api/quests/documents/entitlements/{entitlement.pk}/collect", {}, format="json")
        self.assertEqual(collected.status_code, 200)
        tasks = self.dashboard()["tasks"]
        rows = [task for task in tasks if task["kind"] == "COUNCIL_REGISTRATION" and task["dog_id"] == self.dog.pk]
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["status"], "COLLECTED")
        self.assertEqual(get_balance(self.owner), 300)
        priorities = {"READY": 0, "IN_PROGRESS": 1, "COLLECTED": 2}
        self.assertEqual([priorities[task["status"]] for task in tasks], sorted(priorities[task["status"]] for task in tasks))
        self.now += timedelta(days=1)
        self.assertFalse(any(task["kind"] == "COUNCIL_REGISTRATION" and task["dog_id"] == self.dog.pk for task in self.dashboard()["tasks"]))


@skipUnless(connection.vendor == "mysql", "Requires MySQL row-lock semantics")
class BirthdayConcurrencyTests(TransactionTestCase):
    def test_parallel_birthday_collections_share_one_entitlement_and_wallet_credit(self):
        # TransactionTestCase flushes catalogue seed rows between test classes.
        QuestDefinition.objects.update_or_create(code="BIRTHDAY", defaults={"title": "Birthday bonus", "is_enabled": True})
        owner = User.objects.create_user(email="birthday-concurrent@example.com", display_name="Walker")
        breed = Breed.objects.create(name="Birthday concurrent breed", energy_level="LOW", default_size="SMALL")
        dog = Dog.objects.create(owner=owner, breed=breed, name="Coco", date_of_birth=date(2020, 9, 25), age_months=72, size="SMALL", is_brachycephalic=False)
        barrier = Barrier(2)

        def collect():
            close_old_connections()
            try:
                client = APIClient()
                client.force_authenticate(owner)
                barrier.wait(timeout=10)
                return client.post(f"/api/quests/birthdays/{dog.pk}/collect/", {}, format="json")
            finally:
                close_old_connections()

        with patch("quests.services.timezone.now", return_value=datetime(2026, 9, 25, 12, tzinfo=MELBOURNE)):
            with ThreadPoolExecutor(max_workers=2) as pool:
                results = list(pool.map(lambda _: collect(), range(2)))
            balance = get_balance(owner)
        self.assertEqual(sorted(result.status_code for result in results), [200, 201])
        self.assertEqual(results[0].data["award"], results[1].data["award"])
        self.assertEqual(QuestAward.objects.count(), 1)
        self.assertEqual(PointEntry.objects.count(), 1)
        self.assertEqual(balance, 60)
