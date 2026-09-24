from datetime import date

from django.contrib.auth import get_user_model
from django.db import IntegrityError, transaction
from django.test import TestCase
from django.utils import timezone

from dogs.models import Breed, Dog, DogDailyGoal


class DailyGoalFoundationTests(TestCase):
    @classmethod
    def setUpTestData(cls):
        cls.owner = get_user_model().objects.create_user(email="goal-foundation@example.com", display_name="Goal owner")
        cls.breed = Breed.objects.create(name="Goal foundation breed", energy_level="LOW", default_size="SMALL")
        cls.dog = Dog.objects.create(owner=cls.owner, breed=cls.breed, name="Pip", age_months=24, size="SMALL", is_brachycephalic=False)

    def goal(self, **overrides):
        # Test-only target, never a product default or activated formula.
        values = dict(dog=self.dog, dog_id_snapshot=self.dog.pk, owner=self.owner, local_date=date(2026, 9, 25),
                      target_active_seconds=1234, inputs_snapshot={"fixture": True}, rules_version="test-only")
        values.update(overrides)
        return DogDailyGoal.objects.create(**values)

    def test_profile_creation_does_not_invent_goal(self):
        self.assertFalse(DogDailyGoal.objects.exists())
        self.assertIsNone(self.dog.microchip_number)

    def test_dog_date_uniqueness_survives_owner_transfer_and_deletion(self):
        goal = self.goal()
        identity = self.dog.pk
        other = get_user_model().objects.create_user(email="goal-new-owner@example.com", display_name="Other")
        self.dog.owner = other
        self.dog.save(update_fields=("owner",))
        with self.assertRaises(IntegrityError), transaction.atomic():
            self.goal(owner=other)
        self.dog.delete()
        goal.refresh_from_db()
        self.assertIsNone(goal.dog_id)
        self.assertEqual(goal.dog_id_snapshot, identity)
        self.assertEqual(goal.owner_id, self.owner.pk)

    def test_database_rejects_zero_target_and_inconsistent_final_result(self):
        for overrides in (
            {"target_active_seconds": 0},
            {"finalised_at": timezone.now()},
            {"finalised_at": timezone.now(), "final_active_seconds": 12, "final_goal_met": True},
            {"finalised_at": timezone.now(), "final_active_seconds": 2000, "final_goal_met": False},
        ):
            with self.subTest(overrides=overrides), self.assertRaises(IntegrityError), transaction.atomic():
                self.goal(**overrides)

    def test_final_result_can_be_frozen_without_creating_points(self):
        goal = self.goal(finalised_at=timezone.now(), final_active_seconds=1234, final_goal_met=True)
        self.assertTrue(goal.final_goal_met)
        self.assertFalse(self.owner.point_entries.exists())
