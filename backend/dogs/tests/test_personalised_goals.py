from concurrent.futures import ThreadPoolExecutor
from datetime import date, timedelta
from decimal import Decimal, ROUND_HALF_UP
from itertools import product
from threading import Barrier
from unittest import skipUnless

from django.contrib.auth import get_user_model
from django.core.exceptions import ValidationError
from django.db import close_old_connections, connection
from django.test import TestCase, TransactionTestCase
from rest_framework.test import APIClient

from dogs.goals import configure_target, goal_progress
from dogs.models import Dog, DogDailyGoal, DogGoalTarget
from dogs.personalised_goals import POLICY, owner_goal, recommend
from dogs.tests.test_goals import GoalFixture
from rewards.models import PointEntry


class PersonalisedFixture(GoalFixture):
    def setUp(self):
        super().setUp()
        self.dog.weight_kg = Decimal("15.00")
        self.dog.date_of_birth = date(2024, 1, 1)
        self.dog.save()
        self.dog.breed.energy_level = "HIGH"
        self.dog.breed.save()
        self.client = APIClient()
        self.client.force_authenticate(self.owner)
        self.url = f"/api/dogs/{self.dog.pk}/goal"

    def post(self, **values):
        return self.client.post(self.url, {"effective_from": self.day.isoformat(), **values}, format="json")

    def recommend(self, day=None, adjustment="1.00"):
        return recommend(dog=self.dog, effective_from=day or self.day, owner_adjustment=adjustment)


class RecommendationTests(PersonalisedFixture, TestCase):
    def test_confirmed_example_and_adjustment_applied_once(self):
        for adjustment, minutes, seconds in (("0.50", "31.25", 1875), ("1.00", "62.5", 3750), ("2.00", "125", 7500)):
            with self.subTest(adjustment=adjustment):
                result = self.recommend(adjustment=adjustment)
                self.assertEqual(Decimal(result["suggested_minutes"]), Decimal("62.5"))
                self.assertEqual(Decimal(result["target_minutes"]), Decimal(minutes))
                self.assertEqual(result["target_seconds"], seconds)

    def test_weight_boundaries(self):
        for weight, baseline in (("0.01", 30), ("4.99", 30), ("5", 40), ("9.99", 40),
                                 ("10", 50), ("24.99", 50), ("25", 60), ("39.99", 60), ("40", 60), ("90", 60)):
            with self.subTest(weight=weight):
                self.dog.weight_kg = Decimal(weight)
                self.assertEqual(self.recommend()["calculation_inputs"]["baseline_minutes"], baseline)

    def test_factor_combinations(self):
        for (weight, baseline), (energy, factor), (birthday, age), brachy, adjustment in product(
            [(3, 30), (7, 40), (15, 50), (30, 60), (45, 60)],
            [("LOW", ".75"), ("MODERATE", "1"), ("HIGH", "1.25"), ("VERY_HIGH", "1.5"), ("UNKNOWN", "1")],
            [(date(2026, 5, 4), ".5"), (date(2026, 2, 4), ".75"), (date(2024, 1, 1), "1"), (date(2010, 1, 1), ".75")],
            [False, True], [".5", "1", "2"]):
            with self.subTest(weight=weight, energy=energy, birthday=birthday, brachy=brachy, adjustment=adjustment):
                self.dog.weight_kg = Decimal(weight)
                self.dog.breed.energy_level = energy
                self.dog.date_of_birth = birthday
                self.dog.is_brachycephalic = brachy
                expected = Decimal(baseline) * Decimal(factor) * Decimal(age) * Decimal(".7" if brachy else "1")
                result = self.recommend(adjustment=adjustment)
                self.assertEqual(Decimal(result["suggested_minutes"]), expected)
                self.assertEqual(result["target_seconds"], int((expected * Decimal(adjustment) * 60).quantize(Decimal(1), rounding=ROUND_HALF_UP)))

    def test_calendar_age_boundaries_and_exact_tenth_birthday(self):
        self.dog.date_of_birth = date(2016, 1, 31)
        for day, factor in ((date(2016, 5, 30), None), (date(2016, 5, 31), ".50"),
                            (date(2016, 8, 30), ".50"), (date(2016, 8, 31), ".75"),
                            (date(2017, 1, 30), ".75"), (date(2017, 1, 31), "1"),
                            (date(2026, 1, 30), "1"), (date(2026, 1, 31), "1"), (date(2026, 2, 1), ".75")):
            with self.subTest(day=day):
                result = self.recommend(day)
                self.assertEqual(result["eligible"], factor is not None)
                if factor:
                    self.assertEqual(Decimal(result["calculation_inputs"]["age_factor"]), Decimal(factor))
                else:
                    self.assertIsNone(result["target_seconds"])

    def test_month_end_and_leap_day_birthdays(self):
        for birthday, day, factor in ((date(2024, 10, 31), date(2025, 2, 28), ".5"),
                                     (date(2024, 2, 29), date(2025, 2, 27), ".75"),
                                     (date(2024, 2, 29), date(2025, 2, 28), "1"),
                                     (date(2016, 2, 29), date(2026, 2, 28), "1"),
                                     (date(2016, 2, 29), date(2026, 3, 1), ".75")):
            with self.subTest(birthday=birthday, day=day):
                self.dog.date_of_birth = birthday
                self.assertEqual(Decimal(self.recommend(day)["calculation_inputs"]["age_factor"]), Decimal(factor))

    def test_rounding_is_only_final_seconds_half_up(self):
        self.dog.weight_kg = Decimal(3)
        self.dog.breed.energy_level = "LOW"
        self.dog.is_brachycephalic = True
        self.assertEqual(self.recommend(adjustment=".50")["target_seconds"], 473)  # 472.5, not banker's 472
        self.dog.date_of_birth = date(2026, 2, 1)
        self.assertEqual(self.recommend(adjustment=".51")["target_seconds"], 361)  # 361.4625
        self.assertEqual(self.recommend(adjustment=".52")["target_seconds"], 369)  # 368.55

    def test_unknown_energy_defaults_to_one_only(self):
        for value in ("UNKNOWN", "", "UNRECOGNISED"):
            self.dog.breed.energy_level = value
            self.assertEqual(Decimal(self.recommend()["suggested_minutes"]), Decimal(50))

    def test_missing_inputs_are_not_invented_from_size_or_age_months(self):
        for field in ("weight_kg", "date_of_birth", "is_brachycephalic", "breed_id"):
            dog = Dog.objects.select_related("breed").get(pk=self.dog.pk)
            setattr(dog, field, None)
            result = recommend(dog=dog, effective_from=self.day)
            self.assertFalse(result["eligible"])
            self.assertIsNone(result["target_seconds"])
            self.assertTrue(result["missing_inputs"])

    def test_service_rejects_invalid_adjustments(self):
        for value in (".49", "2.01", "NaN", "Infinity", "-.5", "one", None, True, ".505"):
            with self.subTest(value=value), self.assertRaises(ValidationError):
                self.recommend(adjustment=value)


class PersonalisedAPITests(PersonalisedFixture, TestCase):
    def test_preview_is_read_only_and_defaults_to_100_percent(self):
        response = self.client.get(self.url)
        self.assertEqual(response.status_code, 200)
        self.assertEqual(Decimal(response.data["owner_adjustment"]), Decimal(1))
        self.assertEqual(response.data["target_seconds"], 3750)
        self.assertEqual(response.data["effective_from"], self.day)
        self.assertFalse(DogGoalTarget.objects.exists())
        self.assertFalse(DogDailyGoal.objects.exists())

    def test_save_first_today_snapshots_policy_and_inputs_without_payout(self):
        response = self.post(owner_adjustment=".50")
        self.assertEqual(response.status_code, 201, response.data)
        target = DogGoalTarget.objects.get()
        self.assertEqual(target.calculation_policy, POLICY)
        self.assertEqual(target.calculation_inputs["owner_adjustment"], "0.50")
        self.assertEqual(target.target_active_seconds, 1875)
        self.progress()
        goal = DogDailyGoal.objects.get()
        self.assertEqual(goal.inputs_snapshot["calculation_inputs"], target.calculation_inputs)
        self.assertEqual(goal.inputs_snapshot["calculation_policy"], POLICY)
        self.assertFalse(PointEntry.objects.exists())
        self.assertEqual(self.client.get("/api/quests").data["goal_rewards_status"], "PENDING_MULTI_DOG_POLICY")

    def test_limits_types_and_client_supplied_calculation_rejected(self):
        for value in (".49", "2.01", "NaN", "Infinity", True, None, ".505", "junk"):
            with self.subTest(value=value):
                self.assertEqual(self.post(owner_adjustment=value).status_code, 400)
        self.assertEqual(self.post(target_seconds=1).status_code, 400)
        self.assertEqual(self.post(exercise_level=2).status_code, 400)
        self.assertEqual(self.client.post(self.url, {}, format="json").status_code, 400)
        self.assertFalse(DogGoalTarget.objects.exists())

    def test_requires_current_owner_and_authenticated_owner_role(self):
        other = get_user_model().objects.create_user(email="goal-stranger@example.com", display_name="Other")
        self.client.force_authenticate(other)
        self.assertEqual(self.client.get(self.url).status_code, 404)
        self.assertEqual(self.post().status_code, 404)
        self.client.force_authenticate(None)
        self.assertEqual(self.post().status_code, 401)
        other.role = "CAFE"
        other.save()
        self.client.force_authenticate(other)
        self.assertEqual(self.post().status_code, 403)
        with self.assertRaises(ValidationError):
            owner_goal(dog=self.dog, owner=other, save=True)

    def test_missing_profile_and_under_four_months_never_create_zero_goal(self):
        for updates in ({"weight_kg": None}, {"date_of_birth": None}, {"date_of_birth": self.day - timedelta(days=30)}):
            Dog.objects.filter(pk=self.dog.pk).update(weight_kg=15, date_of_birth=date(2024, 1, 1))
            Dog.objects.filter(pk=self.dog.pk).update(**updates)
            self.assertFalse(self.client.get(self.url).data["eligible"])
            self.assertEqual(self.post().status_code, 400)
            self.assertEqual(self.progress()["days"][-1]["state"], "NOT_ELIGIBLE")
            self.assertFalse(self.progress()["completed"])
        self.assertFalse(DogGoalTarget.objects.exists())
        self.assertFalse(DogDailyGoal.objects.exists())

    def test_archived_dog_cannot_configure(self):
        self.dog.archived_at = self.now
        self.dog.save()
        self.assertEqual(self.post().status_code, 400)

    def test_profile_weight_validation_and_legacy_compatibility(self):
        for weight in ("0", "-1", "NaN", "1.001"):
            self.assertEqual(self.client.patch(f"/api/dogs/{self.dog.pk}", {"weight_kg": weight}, format="json").status_code, 400)
        response = self.client.patch(f"/api/dogs/{self.dog.pk}", {"weight_kg": "9.99"}, format="json")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.data["weight_kg"], "9.99")
        self.assertEqual(self.client.patch(f"/api/dogs/{self.dog.pk}", {"weight_kg": None}, format="json").status_code, 200)
        self.assertFalse(self.client.get(self.url).data["eligible"])

    def test_changes_duplicate_dates_and_backdating_rejected(self):
        self.assertEqual(self.post(effective_from=(self.day - timedelta(days=1)).isoformat()).status_code, 400)
        self.assertEqual(self.post().status_code, 201)
        self.assertEqual(self.post(owner_adjustment="2").status_code, 400)
        tomorrow = (self.day + timedelta(days=1)).isoformat()
        self.assertEqual(self.post(effective_from=tomorrow, owner_adjustment="2").status_code, 201)
        self.assertEqual(self.post(effective_from=tomorrow).status_code, 400)
        self.assertEqual(DogGoalTarget.objects.count(), 2)

    def test_admin_owner_and_pause_share_one_timeline(self):
        self.configure(90)
        tomorrow = self.day + timedelta(days=1)
        self.assertEqual(self.post(effective_from=tomorrow.isoformat()).status_code, 201)
        self.assertEqual(self.progress()["target_seconds"], 90)
        self.configure(None, self.day + timedelta(days=2))
        preview = self.client.get(self.url).data
        self.assertEqual(preview["effective_from"], self.day + timedelta(days=3))
        self.assertEqual([t["target_seconds"] for t in preview["scheduled_targets"]], [3750, None])
        self.now += timedelta(days=1)
        self.assertEqual(self.progress()["target_seconds"], 3750)
        self.now += timedelta(days=1)
        self.assertIsNone(self.progress()["target_seconds"])
        self.assertFalse(self.progress()["completed"])

    def test_profile_and_breed_edits_preserve_targets_and_final_history(self):
        self.post()
        self.progress()
        self.now += timedelta(days=2)
        self.progress()
        before = list(DogDailyGoal.objects.values())
        original = DogGoalTarget.objects.get()
        self.dog.weight_kg = 3
        self.dog.date_of_birth = date(2026, 5, 1)
        self.dog.save()
        self.dog.breed.energy_level = "LOW"
        self.dog.breed.save()
        response = self.post(effective_from=(self.day + timedelta(days=3)).isoformat())
        self.assertEqual(response.status_code, 201)
        self.assertEqual(response.data["target_seconds"], 675)
        self.progress()
        self.assertEqual(list(DogDailyGoal.objects.values()), before)
        preserved = DogGoalTarget.objects.get(pk=original.pk)
        self.assertEqual(preserved.calculation_inputs, original.calculation_inputs)
        self.assertEqual(preserved.target_active_seconds, 3750)

    def test_scheduled_target_uses_first_birthday_not_configuration_age(self):
        self.dog.date_of_birth = date(2025, 10, 5)
        self.dog.save()
        self.assertEqual(self.client.get(self.url).data["target_seconds"], 2813)
        response = self.post(effective_from="2026-10-05")
        self.assertEqual(response.status_code, 201)
        self.assertEqual(response.data["target_seconds"], 3750)

    def test_transfer_back_does_not_restore_personalised_configuration(self):
        self.post()
        self.progress()
        other = get_user_model().objects.create_user(email="new-personal-owner@example.com", display_name="Other")
        stale = Dog.objects.get(pk=self.dog.pk)
        self.dog.owner = other
        self.dog.save(update_fields=("owner",))
        with self.assertRaises(ValidationError):
            owner_goal(dog=stale, owner=self.owner, save=True)
        self.assertEqual(self.post().status_code, 404)
        self.client.force_authenticate(other)
        preview = self.client.get(self.url).data
        self.assertIsNone(preview["current_target"])
        self.assertEqual(preview["scheduled_targets"], [])
        self.assertEqual(self.post().status_code, 400)
        self.dog.owner = self.owner
        self.dog.save(update_fields=("owner",))
        self.client.force_authenticate(self.owner)
        self.assertIsNone(self.client.get(self.url).data["current_target"])
        self.assertIsNone(self.progress()["target_seconds"])
        self.assertEqual(DogDailyGoal.objects.count(), 1)

    def test_owner_target_preserves_upload_cutoff_and_selected_dog_rules(self):
        self.walk()
        response = self.post(owner_adjustment=".50")
        self.assertEqual(response.status_code, 201)
        self.assertEqual(self.progress()["active_seconds"], 0)
        self.walk(seconds=60)
        self.assertEqual(self.progress()["active_seconds"], 60)
        self.assertFalse(PointEntry.objects.filter(earn_category="DAILY_GOAL").exists())

    def test_old_owners_future_schedule_does_not_delay_new_owner(self):
        self.configure(60, self.day + timedelta(days=100))
        other = get_user_model().objects.create_user(email="future-new-owner@example.com", display_name="Other")
        self.dog.owner = other
        self.dog.save(update_fields=("owner",))
        self.client.force_authenticate(other)
        preview = self.client.get(self.url).data
        self.assertEqual(preview["effective_from"], self.day + timedelta(days=1))
        self.assertEqual(preview["scheduled_targets"], [])
        response = self.post(effective_from=preview["effective_from"].isoformat())
        self.assertEqual(response.status_code, 201)
        self.now += timedelta(days=101)
        self.assertEqual(goal_progress(owner=other, now=self.now)[0]["target_seconds"], 3750)


@skipUnless(connection.vendor == "mysql", "Requires MySQL row locks")
class PersonalisedConcurrencyTests(PersonalisedFixture, TransactionTestCase):
    def test_admin_and_owner_same_date_create_only_one_revision(self):
        barrier = Barrier(2)

        def configure(as_owner):
            close_old_connections()
            try:
                dog = Dog.objects.get(pk=self.dog.pk)
                barrier.wait(timeout=10)
                try:
                    if as_owner:
                        owner_goal(dog=dog, owner=self.owner, effective_from=self.day, save=True)
                    else:
                        configure_target(dog=dog, effective_from=self.day, target_active_seconds=60)
                    return "saved"
                except ValidationError:
                    return "rejected"
            finally:
                close_old_connections()

        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(configure, [False, True]))
        self.assertCountEqual(results, ["saved", "rejected"])
        self.assertEqual(DogGoalTarget.objects.count(), 1)
