from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta
from threading import Barrier
from unittest import skipUnless
from unittest.mock import patch
from uuid import uuid4

from django.contrib.auth import get_user_model
from django.core.exceptions import ValidationError as ModelValidationError
from django.db import close_old_connections, connection
from django.test import TestCase, TransactionTestCase
from rest_framework.exceptions import ValidationError
from rest_framework.test import APIClient

from checkins.services import daily_activity_points
from dogs.goals import configure_target, goal_progress
from dogs.models import Breed, Dog, DogDailyGoal, DogGoalTarget
from quests.goals import settle_reserved_goal
from quests.models import QuestAward
from rewards.models import PointEntry
from rewards.policy import MELBOURNE, local_date, local_midnight
from rewards.services import credit_points, get_balance
from walks.models import Walk, WalkSession
from walks.services import store_verified_net_interval
from walks.services import create_walk


class GoalFixture:
    def setUp(self):
        self.now = datetime(2026, 10, 4, 15, tzinfo=MELBOURNE)
        clock = patch("django.utils.timezone.now", side_effect=lambda: self.now)
        clock.start()
        self.addCleanup(clock.stop)
        self.owner = get_user_model().objects.create_user(email="goals@example.com", display_name="Walker")
        breed = Breed.objects.create(name="Goal breed", energy_level="LOW", default_size="SMALL")
        self.dog = Dog.objects.create(owner=self.owner, breed=breed, name="Milo", age_months=24,
            size="SMALL", is_brachycephalic=False)
        self.day = local_date(self.now)

    def configure(self, seconds=120, day=None, dog=None):
        return configure_target(dog=dog or self.dog, target_active_seconds=seconds, effective_from=day or self.day)

    def walk(self, seconds=60, dogs=None, request_id=None):
        start = self.now + timedelta(minutes=1)
        self.now = start + timedelta(seconds=seconds)
        return create_walk(owner=self.owner, request_id=request_id or uuid4(), started_at=start,
            ended_at=self.now, dog_ids=[dog.pk for dog in (dogs or [self.dog])],
            samples=[dict(latitude=0, longitude=i * 0.0001, recorded_at=start + timedelta(seconds=i * 10),
                accuracy_m=5, is_simulated=False) for i in range(seconds // 10 + 1)])

    def progress(self):
        return goal_progress(owner=self.owner, now=self.now)[0]

    def reserve(self):
        # Only a test fixture supplies a future approved qualification. No
        # production path reserves one until the client confirms multi-dog rules.
        return QuestAward.objects.create(owner=self.owner, kind="DAILY_GOAL",
            qualification_key=f"test-approved:{self.owner.pk}:{self.day}", qualified_on=self.day,
            qualified_at=self.now, promised_points=20, rules_version="test-approved-only",
            claim_expires_at=local_midnight(self.day + timedelta(days=1)),
            eligibility_snapshot={"approved_policy_version": "test-only", "reward_scope": "test-only",
                "required_goal_ids": list(DogDailyGoal.objects.filter(owner=self.owner, local_date=self.day).values_list("pk", flat=True))})

    def credit(self, amount, category):
        return credit_points(user=self.owner, amount=amount, type="EARN", earn_category=category,
            earned_on=self.day, rules_version="test", source_reference=str(uuid4()))


class DailyGoalTests(GoalFixture, TestCase):
    def test_paused_today_breaks_the_current_streak(self):
        self.configure(60)
        self.walk()
        self.configure(None, self.day + timedelta(days=1))
        self.now += timedelta(days=1)
        self.assertEqual(self.progress()["current_streak"], 0)

    def test_transfer_back_does_not_reactivate_old_configuration(self):
        self.configure(60)
        self.walk()
        self.progress()
        other = get_user_model().objects.create_user(email="transfer@example.com", display_name="Other")
        self.dog.owner = other
        self.dog.save(update_fields=("owner",))
        self.assertIsNone(goal_progress(owner=other, now=self.now)[0]["target_seconds"])
        self.dog.owner = self.owner
        self.dog.save(update_fields=("owner",))
        self.assertIsNone(self.progress()["target_seconds"])
        self.assertEqual(self.progress()["active_seconds"], 0)
        self.assertEqual(DogGoalTarget.objects.count(), 1)
        self.assertEqual(DogDailyGoal.objects.count(), 1)

    def test_dormant_settlement_rejects_transferred_dog(self):
        self.configure(60)
        self.walk()
        self.progress()
        award = self.reserve()
        other = get_user_model().objects.create_user(email="settlement-transfer@example.com", display_name="Other")
        self.dog.owner = other
        self.dog.save(update_fields=("owner",))
        with self.assertRaises(ValidationError):
            settle_reserved_goal(owner=self.owner, qualification_id=award.pk, now=self.now)
        self.assertFalse(PointEntry.objects.filter(earn_category="DAILY_GOAL").exists())

    def test_admin_form_rejects_duplicate_effective_date(self):
        from dogs.admin import GoalTargetForm
        day = self.day + timedelta(days=1)
        self.configure(60, day)
        form = GoalTargetForm(data={"dog": self.dog.pk, "effective_from": day, "target_active_seconds": 120})
        self.assertFalse(form.is_valid())

    def test_future_revisions_use_effective_order_and_pause_cannot_bridge_runs(self):
        self.configure(60)
        self.walk()
        self.configure(180, self.day + timedelta(days=3))
        self.configure(None, self.day + timedelta(days=1))
        self.configure(120, self.day + timedelta(days=2))
        self.now += timedelta(days=2)
        self.walk(120)
        result = self.progress()
        self.assertEqual(result["current_streak"], 1)
        self.assertEqual(result["target_seconds"], 120)
        self.assertEqual([day["state"] for day in result["days"][-3:]], ["COMPLETED", "NOT_ELIGIBLE", "COMPLETED"])
        self.assertEqual([day["date"] for day in result["days"]],
                         [local_date(self.now) - timedelta(days=offset) for offset in range(6, -1, -1)])
        self.now += timedelta(days=1)
        self.assertEqual(self.progress()["target_seconds"], 180)

    def test_new_owner_needs_new_target_and_gets_only_new_walking_time(self):
        old_target = self.configure(60)
        self.walk()
        self.progress()
        original = self.owner
        self.owner = get_user_model().objects.create_user(email="new-owner@example.com", display_name="New")
        self.dog.owner = self.owner
        self.dog.save(update_fields=("owner",))
        self.assertIsNone(self.progress()["target_seconds"])
        target = self.configure(120, self.day + timedelta(days=1))
        self.assertNotEqual(target.owner_version, old_target.owner_version)
        self.now += timedelta(days=1)
        self.walk(60)
        result = self.progress()
        self.assertEqual((result["active_seconds"], result["completed"]), (60, False))
        self.assertEqual(result["days"][-2]["state"], "NOT_ELIGIBLE")
        self.assertEqual(DogDailyGoal.objects.get(local_date=self.day).owner, original)

    def test_configuration_rejects_a_stale_owner_reference(self):
        stale = Dog.objects.get(pk=self.dog.pk)
        self.dog.owner = get_user_model().objects.create_user(email="stale-owner@example.com", display_name="New")
        self.dog.save(update_fields=("owner",))
        with self.assertRaises(ModelValidationError):
            self.configure(dog=stale)
        self.assertFalse(DogGoalTarget.objects.exists())

    def test_stale_owner_edit_cannot_transfer_the_dog_back(self):
        from types import SimpleNamespace
        from django.http import Http404
        from dogs.serializers import DogSerializer
        stale = Dog.objects.get(pk=self.dog.pk)
        other = get_user_model().objects.create_user(email="stale-edit@example.com", display_name="Other")
        self.dog.owner = other
        self.dog.save(update_fields=("owner",))
        serializer = DogSerializer(stale, data={"name": "Stale rename"}, partial=True,
            context={"request": SimpleNamespace(user=self.owner)})
        self.assertTrue(serializer.is_valid(), serializer.errors)
        with self.assertRaises(Http404):
            serializer.save()
        self.dog.refresh_from_db()
        self.assertEqual(self.dog.owner_id, other.pk)

    def test_stale_owner_delete_cannot_delete_transferred_dog(self):
        from types import SimpleNamespace
        from django.http import Http404
        from dogs.views import DogDetailView
        stale = Dog.objects.get(pk=self.dog.pk)
        other = get_user_model().objects.create_user(email="stale-delete@example.com", display_name="Other")
        self.dog.owner = other
        self.dog.save(update_fields=("owner",))
        view = DogDetailView()
        view.request = SimpleNamespace(user=self.owner)
        with self.assertRaises(Http404):
            view.perform_destroy(stale)
        self.assertTrue(Dog.objects.filter(pk=self.dog.pk, owner=other).exists())

    def test_target_save_and_delete_cannot_rewrite_history(self):
        target = self.configure(60)
        target.target_active_seconds = 1
        with self.assertRaises(ModelValidationError):
            target.save()
        with self.assertRaises(ModelValidationError):
            target.delete()
        target.refresh_from_db()
        self.assertEqual(target.target_active_seconds, 60)

    def test_exact_configuration_start_and_unselected_dogs_do_not_qualify(self):
        self.configure(60)
        self.now -= timedelta(minutes=1)  # fixture walk starts exactly when configured
        self.walk()
        self.assertEqual(self.progress()["active_seconds"], 0)
        other = Dog.objects.create(owner=self.owner, breed=self.dog.breed, name="Other", age_months=12,
            size="SMALL", is_brachycephalic=False)
        self.configure(60, dog=other)
        self.walk(dogs=[other])
        result = goal_progress(owner=self.owner, now=self.now)
        self.assertEqual([row["active_seconds"] for row in result], [0, 60])

    def test_upload_deadline_uses_elapsed_time_across_both_dst_changes(self):
        from datetime import UTC
        from walks.services import validated_activity
        for start in (datetime(2026, 10, 4, 0, 30, tzinfo=MELBOURNE),
                      datetime(2026, 4, 5, 0, 30, tzinfo=MELBOURNE)):
            samples = [dict(latitude=0, longitude=i * 0.0001,
                recorded_at=start + timedelta(seconds=i * 10), accuracy_m=5, is_simulated=False) for i in range(7)]
            self.now = (start.astimezone(UTC) + timedelta(hours=12)).astimezone(MELBOURNE)
            self.assertEqual(validated_activity(started_at=start, ended_at=start + timedelta(seconds=60), samples=samples).active_seconds, 60)
            self.now += timedelta(microseconds=1)
            with self.assertRaises(ValidationError):
                validated_activity(started_at=start, ended_at=start + timedelta(seconds=60), samples=samples)

    def test_frozen_results_are_not_recomputed(self):
        self.configure(60)
        walk = self.walk()
        self.now += timedelta(days=1)
        self.progress()
        goal = DogDailyGoal.objects.get(local_date=self.day)
        self.assertTrue(goal.final_goal_met)
        Walk.objects.filter(pk=walk.pk).update(active_seconds=0)
        result = self.progress()
        self.assertEqual(result["days"][-2]["active_seconds"], 60)
        self.assertEqual(result["days"][-2]["state"], "COMPLETED")

    def test_goal_definition_and_http_requests_cannot_enable_payouts(self):
        from quests.models import QuestDefinition
        QuestDefinition.objects.update_or_create(code="DAILY_GOAL", defaults={"is_enabled": True, "title": "Daily goal"})
        self.configure(60)
        self.walk()
        client = APIClient()
        self.assertEqual(client.get("/api/quests").status_code, 401)
        client.force_authenticate(self.owner)
        self.assertTrue(client.get("/api/quests").data["daily_goals"][0]["completed"])
        self.assertEqual(client.post("/api/quests", {"required_goal_ids": [1]}).status_code, 405)
        self.assertEqual(client.post("/api/quests/goals/collect/", {}).status_code, 404)
        self.assertFalse(QuestAward.objects.filter(kind="DAILY_GOAL").exists())
        self.assertFalse(PointEntry.objects.filter(earn_category="DAILY_GOAL").exists())

    def test_admin_duplicate_returns_form_error_and_history_is_read_only(self):
        from django.urls import reverse
        self.owner.is_staff = self.owner.is_superuser = True
        self.owner.save(update_fields=("is_staff", "is_superuser"))
        self.client.force_login(self.owner)
        day = self.day + timedelta(days=1)
        target = self.configure(60, day)
        response = self.client.post(reverse("admin:dogs_doggoaltarget_add"), {
            "dog": self.dog.pk, "effective_from": day.isoformat(), "target_active_seconds": 120, "_save": "Save"})
        self.assertEqual(response.status_code, 200)
        self.assertContains(response, "A target revision already exists")
        self.assertEqual(self.client.post(reverse("admin:dogs_doggoaltarget_change", args=[target.pk]), {}).status_code, 403)
        self.assertEqual(self.client.post(reverse("admin:dogs_doggoaltarget_delete", args=[target.pk]), {"post": "yes"}).status_code, 403)
        self.assertEqual(DogGoalTarget.objects.count(), 1)
        self.owner.is_superuser = False
        self.owner.save(update_fields=("is_superuser",))
        self.assertEqual(self.client.get(reverse("admin:dogs_doggoaltarget_add")).status_code, 403)

    def test_dormant_settlement_rejects_malformed_expired_or_foreign_qualifications(self):
        self.configure(60)
        self.walk()
        self.progress()
        award = self.reserve()
        original = award.eligibility_snapshot
        for snapshot in ([1], {**original, "required_goal_ids": [[1]]}, {**original, "required_goal_ids": [True]},
                         {**original, "reward_scope": {}}, {**original, "approved_policy_version": " "}):
            QuestAward.objects.filter(pk=award.pk).update(eligibility_snapshot=snapshot)
            with self.subTest(snapshot=snapshot), self.assertRaises(ValidationError):
                settle_reserved_goal(owner=self.owner, qualification_id=award.pk, now=self.now)
        QuestAward.objects.filter(pk=award.pk).update(eligibility_snapshot=original, claim_expires_at=self.now)
        with self.assertRaises(ValidationError):
            settle_reserved_goal(owner=self.owner, qualification_id=award.pk, now=self.now)
        other = get_user_model().objects.create_user(email="foreign-award@example.com", display_name="Other")
        with self.assertRaises(ValidationError):
            settle_reserved_goal(owner=other, qualification_id=award.pk, now=self.now)
        self.assertFalse(PointEntry.objects.filter(earn_category="DAILY_GOAL").exists())

    def test_dormant_settlement_rejects_deleted_or_returned_dog(self):
        self.configure(60)
        self.walk()
        self.progress()
        award = self.reserve()
        other = get_user_model().objects.create_user(email="return-award@example.com", display_name="Other")
        for owner in (other, self.owner):
            self.dog.owner = owner
            self.dog.save(update_fields=("owner",))
        with self.assertRaises(ValidationError):
            settle_reserved_goal(owner=self.owner, qualification_id=award.pk, now=self.now)
        self.dog.delete()
        with self.assertRaises(ValidationError):
            settle_reserved_goal(owner=self.owner, qualification_id=award.pk, now=self.now)

    def test_dormant_full_reward_fits_exact_baseline_and_retry_after_expiry_is_not_a_new_credit(self):
        self.configure(60)
        self.walk()
        self.progress()
        self.credit(40, "WALK")
        self.credit(12, "CHECK_IN")
        award = self.reserve()
        self.assertTrue(settle_reserved_goal(owner=self.owner, qualification_id=award.pk, now=self.now)["created"])
        self.assertEqual(daily_activity_points(self.owner, self.day), 72)
        self.now += timedelta(days=2)
        self.assertFalse(settle_reserved_goal(owner=self.owner, qualification_id=award.pk, now=self.now)["created"])
        self.assertEqual(PointEntry.objects.filter(earn_category="DAILY_GOAL").count(), 1)

    def test_unconfigured_and_new_days_are_not_missed(self):
        result = self.progress()
        self.assertIsNone(result["target_seconds"])
        self.assertFalse(result["completed"])
        self.assertEqual({day["state"] for day in result["days"]}, {"NOT_ELIGIBLE"})
        self.configure()
        result = self.progress()
        self.assertEqual(result["days"][-1]["state"], "INCOMPLETE")
        self.assertEqual(result["days"][-2]["state"], "NOT_ELIGIBLE")

    def test_multiple_walks_and_shared_dogs_do_not_multiply_time_or_points(self):
        other = Dog.objects.create(owner=self.owner, breed=self.dog.breed, name="Pip", age_months=12,
            size="SMALL", is_brachycephalic=False)
        self.configure()
        self.configure(dog=other)
        self.walk(dogs=[self.dog, other])
        self.assertEqual(self.progress()["active_seconds"], 60)
        self.walk(dogs=[self.dog, other])
        results = goal_progress(owner=self.owner, now=self.now)
        self.assertEqual([r["active_seconds"] for r in results], [120, 120])
        self.assertTrue(all(r["completed"] for r in results))
        self.assertEqual(self.progress()["current_streak"], 1)
        # Reads and repeated refreshes never enable pending rewards.
        self.progress()
        self.assertFalse(QuestAward.objects.filter(kind="DAILY_GOAL").exists())
        self.assertFalse(PointEntry.objects.filter(earn_category="DAILY_GOAL").exists())

    def test_repeat_upload_is_one_duration(self):
        self.configure()
        walk = self.walk()
        # Repeat the exact original validated request, not a second duration.
        start = walk.started_at
        args = dict(owner=self.owner, request_id=walk.request_id, started_at=start, ended_at=walk.ended_at,
            dog_ids=[self.dog.pk], samples=[dict(latitude=0, longitude=i * 0.0001,
                recorded_at=start + timedelta(seconds=i * 10), accuracy_m=5, is_simulated=False) for i in range(7)])
        self.assertEqual(create_walk(**args).pk, walk.pk)
        self.assertEqual(self.progress()["active_seconds"], 60)

    def test_incomplete_today_keeps_yesterday_then_closed_app_missed_day_resets(self):
        self.configure(60)
        self.walk()
        self.now += timedelta(days=1)
        self.assertEqual(self.progress()["current_streak"], 1)
        self.assertEqual(self.progress()["days"][-1]["state"], "INCOMPLETE")
        self.now += timedelta(days=1)
        result = self.progress()
        self.assertEqual(result["current_streak"], 0)
        self.assertEqual(result["days"][-2]["state"], "MISSED")
        self.walk()
        self.assertEqual(self.progress()["current_streak"], 1)

    def test_configuration_changes_preserve_targets_without_prior_reads(self):
        self.configure(60)
        self.walk()
        self.configure(180, day=self.day + timedelta(days=1))
        self.assertEqual(self.progress()["target_seconds"], 60)
        self.now += timedelta(days=1)
        result = self.progress()
        self.assertEqual(result["target_seconds"], 180)
        yesterday = DogDailyGoal.objects.get(local_date=self.day, dog=self.dog)
        self.assertEqual(yesterday.target_active_seconds, 60)
        self.assertTrue(yesterday.final_goal_met)
        self.configure(None, day=self.day + timedelta(days=2))
        self.now += timedelta(days=1)
        self.assertIsNone(self.progress()["target_seconds"])
        self.assertFalse(self.progress()["completed"])

    def test_targets_cannot_be_rewritten_or_backdated(self):
        target = self.configure()
        with self.assertRaises(ModelValidationError):
            self.configure(180)
        target.target_active_seconds = 1
        with self.assertRaises(ModelValidationError):
            target.full_clean()
        with self.assertRaises(ModelValidationError):
            self.configure(0, self.day + timedelta(days=1))

    def test_midnight_uses_melbourne_end_date_once_even_with_utc_input(self):
        from datetime import UTC
        self.configure(60)
        self.now = local_midnight(self.day + timedelta(days=1)) - timedelta(seconds=90)
        self.walk(seconds=60)  # starts at 23:59:30, ends at 00:00:30
        self.now = self.now.astimezone(UTC)
        result = self.progress()
        self.assertEqual(result["active_seconds"], 60)
        self.assertEqual(result["days"][-2]["active_seconds"], 0)
        self.assertEqual(result["days"][-1]["state"], "COMPLETED")

    def test_late_upload_can_complete_yesterday_before_finalisation(self):
        self.configure(60)
        original_now = self.now
        self.now = local_midnight(self.day + timedelta(days=1)) + timedelta(hours=1)
        self.progress()  # yesterday must remain open for a permitted late upload
        self.assertIsNone(DogDailyGoal.objects.get(local_date=self.day).finalised_at)
        start = local_midnight(self.day + timedelta(days=1)) - timedelta(minutes=3)
        samples = [dict(latitude=0, longitude=i * 0.0001, recorded_at=start + timedelta(seconds=i * 10),
            accuracy_m=5, is_simulated=False) for i in range(7)]
        create_walk(owner=self.owner, request_id=uuid4(), started_at=start,
            ended_at=start + timedelta(seconds=60), dog_ids=[self.dog.pk], samples=samples)
        self.assertGreater(start, original_now)
        self.assertEqual(self.progress()["current_streak"], 1)

    def test_pre_configuration_legacy_and_unselected_dogs_do_not_count(self):
        self.walk()
        self.configure(60)
        self.assertEqual(self.progress()["active_seconds"], 0)
        walk = self.walk()
        Walk.objects.filter(pk=walk.pk).update(rules_version=None)
        self.assertEqual(self.progress()["active_seconds"], 0)
        other = get_user_model().objects.create_user(email="other-goal@example.com", display_name="Other")
        self.assertEqual(goal_progress(owner=other, now=self.now), [])

    def test_net_interval_never_recounts_base_walk_duration(self):
        self.configure(60)
        walk = self.walk()
        partner = get_user_model().objects.create_user(email="partner@example.com", display_name="Partner")
        sessions = [WalkSession.objects.create(owner=owner, request_id=uuid4(),
            walk=walk if owner == self.owner else None, state="FINISHED", started_at=walk.started_at,
            ended_at=walk.ended_at, heartbeat_at=walk.ended_at, net_consent_at=walk.started_at,
            validation_version="test") for owner in (self.owner, partner)]
        for _ in range(2):
            store_verified_net_interval(first_session_id=sessions[0].pk, second_session_id=sessions[1].pk,
                started_at=walk.started_at, ended_at=walk.ended_at, first_distance_m=60,
                second_distance_m=60, rules_version="test", validation_summary={"verified": True})
        self.assertEqual(self.progress()["active_seconds"], 60)
        self.assertFalse(PointEntry.objects.filter(earn_category="NET_WALK").exists())
        self.assertEqual(goal_progress(owner=partner, now=self.now), [])

    def test_dst_finalisation_waits_twelve_elapsed_hours(self):
        from datetime import UTC
        self.now = datetime(2026, 10, 3, 15, tzinfo=MELBOURNE)
        self.day = local_date(self.now)
        Dog.objects.filter(pk=self.dog.pk).update(created_at=self.now)
        self.configure(60)
        self.now = datetime(2026, 10, 4, 12, 30, tzinfo=MELBOURNE)
        self.progress()
        goal = DogDailyGoal.objects.get(local_date=self.day)
        # Clocks sprang forward: 12:30 local is only 11.5 elapsed hours.
        self.assertIsNone(goal.finalised_at)
        self.now = self.now.astimezone(UTC) + timedelta(minutes=31)
        self.progress()
        goal.refresh_from_db()
        self.assertIsNotNone(goal.finalised_at)
        self.assertFalse(goal.final_goal_met)

    def test_deleted_dog_keeps_target_and_daily_history(self):
        self.configure(60)
        self.walk()
        self.progress()
        dog_id = self.dog.pk
        self.dog.delete()
        target = DogGoalTarget.objects.get(dog_id_snapshot=dog_id)
        goal = DogDailyGoal.objects.get(dog_id_snapshot=dog_id)
        self.assertIsNone(target.dog_id)
        self.assertIsNone(goal.dog_id)
        self.assertEqual(goal.target_active_seconds, 60)

    def test_dormant_legacy_goal_does_not_imply_approved_configuration(self):
        DogDailyGoal.objects.create(dog=self.dog, dog_id_snapshot=self.dog.pk, owner=self.owner,
            local_date=self.day, target_active_seconds=50, inputs_snapshot={}, rules_version="dormant")
        self.assertIsNone(self.progress()["target_seconds"])
        self.assertFalse(self.progress()["completed"])

    def test_admin_form_uses_approved_target_without_owner_input(self):
        from dogs.admin import GoalTargetForm
        form = GoalTargetForm(data={"dog": self.dog.pk, "effective_from": self.day, "target_active_seconds": 120})
        self.assertTrue(form.is_valid(), form.errors)
        self.assertEqual(form.instance.owner_id, self.owner.pk)
        self.assertEqual(form.instance.dog_id_snapshot, self.dog.pk)

    def test_walking_seconds_use_elapsed_time_across_both_dst_changes(self):
        from datetime import UTC
        from walks.services import validated_activity
        for day in (datetime(2026, 10, 4, 1, 59, 30, tzinfo=MELBOURNE),
                    datetime(2026, 4, 5, 2, 59, 30, tzinfo=MELBOURNE)):
            with self.subTest(day=day):
                start = day.astimezone(UTC)
                self.now = start + timedelta(seconds=60)
                samples = [dict(latitude=0, longitude=i * 0.0001,
                    recorded_at=(start + timedelta(seconds=i * 10)).astimezone(MELBOURNE),
                    accuracy_m=5, is_simulated=False) for i in range(7)]
                activity = validated_activity(started_at=day, ended_at=self.now.astimezone(MELBOURNE), samples=samples)
                self.assertEqual(activity.active_seconds, 60)
                self.assertEqual(activity.accepted_segments, 6)

    def test_read_api_returns_labels_without_awards(self):
        client = APIClient()
        client.force_authenticate(self.owner)
        response = client.get("/api/quests")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.data["timezone"], "Australia/Melbourne")
        self.assertEqual(response.data["daily_goals"][0]["days"][-1]["state"], "NOT_ELIGIBLE")
        self.assertEqual(response.data["goal_rewards_status"], "PENDING_MULTI_DOG_POLICY")
        self.assertEqual(PointEntry.objects.count(), 0)

    def test_reserved_reward_retries_and_all_point_sources_share_ledger(self):
        self.configure(60)
        self.walk()
        self.progress()
        award = self.reserve()
        first = settle_reserved_goal(owner=self.owner, qualification_id=award.pk, now=self.now)
        second = settle_reserved_goal(owner=self.owner, qualification_id=award.pk, now=self.now)
        self.assertTrue(first["created"])
        self.assertFalse(second["created"])
        self.assertEqual(first["award"].point_entry_id, second["award"].point_entry_id)
        self.credit(12, "CHECK_IN")
        self.credit(60, "BIRTHDAY")
        self.credit(200, "DOCUMENT")
        self.credit(20, "STREAK")
        self.credit(2, "NET_WALK")  # historical awards always consume the shared cap
        self.assertEqual(daily_activity_points(self.owner, self.day), 34)
        self.assertEqual(get_balance(self.owner), 314)
        client = APIClient()
        client.force_authenticate(self.owner)
        self.assertEqual(client.get("/api/wallet").data["balance"], 314)
        self.assertEqual(PointEntry.objects.filter(earn_category="DAILY_GOAL").count(), 1)

    def test_full_reward_respects_combined_cap_and_incomplete_goal(self):
        self.configure(120)
        self.walk()
        self.progress()
        award = self.reserve()
        with self.assertRaises(ValidationError):
            settle_reserved_goal(owner=self.owner, qualification_id=award.pk, now=self.now)
        self.walk()
        self.credit(39, "WALK")  # the two short walks already earned one point
        self.credit(24, "CHECK_IN")
        with self.assertRaises(ValidationError):
            settle_reserved_goal(owner=self.owner, qualification_id=award.pk, now=self.now)
        self.assertEqual(daily_activity_points(self.owner, self.day), 64)
        self.assertFalse(PointEntry.objects.filter(earn_category="DAILY_GOAL").exists())


@skipUnless(connection.vendor == "mysql", "Requires MySQL row locks; SQLite cannot verify concurrency")
class GoalConcurrencyTests(GoalFixture, TransactionTestCase):
    def parallel(self, operation):
        barrier = Barrier(2)
        def worker(index):
            close_old_connections()
            try:
                barrier.wait(timeout=10)
                return operation(index)
            finally:
                close_old_connections()
        with ThreadPoolExecutor(max_workers=2) as pool:
            futures = [pool.submit(worker, index) for index in range(2)]
            return [future.result(timeout=20) for future in futures]

    def test_competing_configurations_create_one_revision(self):
        def configure(index):
            try:
                self.configure(60 + index)
                return "created"
            except ModelValidationError:
                return "invalid"
        self.assertCountEqual(self.parallel(configure), ["created", "invalid"])
        self.assertEqual(DogGoalTarget.objects.count(), 1)

    def test_parallel_reads_create_one_snapshot(self):
        self.configure(60)
        self.parallel(lambda _: self.progress())
        self.assertEqual(DogDailyGoal.objects.count(), 1)

    def test_upload_and_snapshot_read_are_serialized(self):
        self.configure(60)
        start = self.now + timedelta(minutes=1)
        self.now = start + timedelta(minutes=1)
        args = dict(owner=self.owner, request_id=uuid4(), started_at=start, ended_at=self.now, dog_ids=[self.dog.pk],
            samples=[dict(latitude=0, longitude=i * 0.0001, recorded_at=start + timedelta(seconds=i * 10),
                          accuracy_m=5, is_simulated=False) for i in range(7)])
        self.parallel(lambda index: create_walk(**args) if index == 0 else self.progress())
        self.assertEqual(self.progress()["active_seconds"], 60)
        self.assertEqual(DogDailyGoal.objects.count(), 1)

    def test_transfer_and_configuration_do_not_leak_targets(self):
        other = get_user_model().objects.create_user(email="concurrent-transfer@example.com", display_name="Other")
        def operation(index):
            if index == 0:
                dog = Dog.objects.get(pk=self.dog.pk)
                dog.owner = other
                dog.save(update_fields=("owner",))
            else:
                try:
                    self.configure(60)
                except ModelValidationError:
                    pass
        self.parallel(operation)
        self.assertIsNone(goal_progress(owner=other, now=self.now)[0]["target_seconds"])

    def test_competing_reserved_qualifications_cannot_exceed_combined_cap(self):
        self.configure(60)
        self.walk()
        self.progress()
        self.credit(40, "WALK")
        self.credit(12, "CHECK_IN")
        first = self.reserve()
        second = QuestAward.objects.get(pk=first.pk)
        second.pk = None
        second.qualification_key += ":second-synthetic-scope"
        second.save()
        def settle(index):
            try:
                settle_reserved_goal(owner=self.owner, qualification_id=(first.pk, second.pk)[index], now=self.now)
                return "created"
            except ValidationError:
                return "cap"
        self.assertCountEqual(self.parallel(settle), ["created", "cap"])
        self.assertEqual(daily_activity_points(self.owner, self.day), 72)

    def test_concurrent_reserved_award_settlement_creates_one_credit(self):
        self.configure(60)
        self.walk()
        self.progress()
        award = self.reserve()
        barrier = Barrier(2)
        def worker():
            close_old_connections()
            try:
                barrier.wait(timeout=10)
                return settle_reserved_goal(owner=self.owner, qualification_id=award.pk, now=self.now)["award"].point_entry_id
            finally:
                close_old_connections()
        with ThreadPoolExecutor(max_workers=2) as pool:
            futures = [pool.submit(worker) for _ in range(2)]
            ids = [future.result(timeout=20) for future in futures]
        self.assertEqual(ids[0], ids[1])
        self.assertEqual(PointEntry.objects.filter(earn_category="DAILY_GOAL").count(), 1)
