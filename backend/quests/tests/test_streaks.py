from concurrent.futures import ThreadPoolExecutor
from datetime import date, datetime, time, timedelta
from threading import Barrier
from unittest import skipUnless
from unittest.mock import patch
from uuid import uuid4

from django.contrib.auth import get_user_model
from django.db import close_old_connections, connection
from django.test import TransactionTestCase, override_settings
from django.test.utils import CaptureQueriesContext
from django.utils import timezone
from rest_framework.test import APIClient, APITestCase

from quests.models import QuestAward, QuestDefinition
from quests.streaks import STREAK_RULES_VERSION, StreakClaimError, collect_streak
from rewards.models import PointEntry
from rewards.policy import MELBOURNE
from rewards.services import get_balance
from walks.models import Walk
from walks.services import create_walk

User = get_user_model()


def add_walk(owner, day, **changes):
    end = datetime.combine(day, time(10), tzinfo=MELBOURNE)
    fields = dict(owner=owner, request_id=uuid4(), request_fingerprint="a" * 64,
                  started_at=end - timedelta(minutes=10), ended_at=end, point_date=day,
                  distance_m="500.00", active_seconds=300, points_awarded=0,
                  rules_version="walk-gps-v2", validation_summary={"accepted_moving_segments": 5})
    fields.update(changes)
    return Walk.objects.create(**fields)


def add_run(owner, start, count):
    return [add_walk(owner, start + timedelta(days=offset)) for offset in range(count)]


@override_settings(PASSWORD_HASHERS=["django.contrib.auth.hashers.MD5PasswordHasher"])
class StreakApiTests(APITestCase):
    @classmethod
    def setUpTestData(cls):
        cls.owner = User.objects.create_user(email="streak-owner@example.com", display_name="Walker")
        cls.other = User.objects.create_user(email="streak-other@example.com", display_name="Other")
        cls.cafe = User.objects.create_user(email="streak-cafe@example.com", display_name="Cafe", role="CAFE")
        cls.admin = User.objects.create_user(email="streak-admin@example.com", display_name="Admin", role="ADMIN")

    def setUp(self):
        self.now = datetime(2026, 9, 26, 12, tzinfo=MELBOURNE)
        clock = patch("django.utils.timezone.now", side_effect=lambda: self.now)
        clock.start()
        self.addCleanup(clock.stop)
        self.client.force_authenticate(self.owner)

    def task(self):
        response = self.client.get("/api/quests")
        self.assertEqual(response.status_code, 200)
        rows = [task for task in response.data["tasks"] if task["kind"] == "STREAK"]
        self.assertEqual(len(rows), 1)
        return rows[0]

    def claim(self, start, milestone=7, trailing_slash=False):
        return self.client.post("/api/quests/streaks/collect" + ("/" if trailing_slash else ""),
                                {"run_start_date": str(start), "milestone_days": milestone}, format="json")

    def test_idle_task_requires_no_dog_or_daily_goal_and_get_never_writes(self):
        with CaptureQueriesContext(connection) as queries:
            task = self.task()
            self.task()
        self.assertEqual(task["id"], "streak:idle:7")
        self.assertEqual((task["status"], task["current_days"], task["milestone_days"], task["reward_points"]), ("IN_PROGRESS", 0, 7, 20))
        self.assertEqual(task["progress"], 0)
        self.assertIsNone(task["run_start_date"])
        self.assertTrue(all(not query["sql"].lstrip().upper().startswith(("INSERT", "UPDATE", "DELETE")) for query in queries))
        self.assertEqual(QuestAward.objects.count(), 0)
        self.assertEqual(PointEntry.objects.count(), 0)

    def test_valid_zero_point_walks_count_once_per_melbourne_day(self):
        start = date(2026, 9, 20)
        add_run(self.owner, start, 7)
        for _ in range(3):
            add_walk(self.owner, date(2026, 9, 26))
        task = self.task()
        self.assertEqual((task["current_days"], task["status"], task["progress"]), (7, "READY", 1))
        self.assertEqual(task["run_start_date"], "2026-09-20")
        self.assertEqual(PointEntry.objects.count(), 0)
        self.assertFalse(QuestAward.objects.exists())
        response = self.claim(start)
        self.assertEqual(response.status_code, 201)
        self.assertEqual(response.data["award"]["points"], 20)
        self.assertEqual(response.data["award"]["run_start_date"], "2026-09-20")
        self.assertEqual(PointEntry.objects.get().earned_on, date(2026, 9, 26))
        self.assertEqual(PointEntry.objects.get().earn_category, "STREAK")
        task = self.task()
        self.assertEqual((task["status"], task["current_days"], task["milestone_days"], task["reward_points"]), ("IN_PROGRESS", 7, 30, 100))

    def test_stationary_unverified_unknown_and_invalid_movement_never_count(self):
        day = self.now.date()
        invalid = [
            {"distance_m": 0}, {"active_seconds": 0}, {"active_seconds": None},
            {"active_seconds": 601}, {"rules_version": None}, {"rules_version": "walk-gps-v1"},
            {"validation_summary": None}, {"validation_summary": []},
            {"validation_summary": {"accepted_moving_segments": 0}},
            {"validation_summary": {"accepted_moving_segments": "5"}},
            {"validation_summary": {"accepted_moving_segments": True}},
            {"point_date": day - timedelta(days=1)},
            {"started_at": self.now, "ended_at": self.now + timedelta(minutes=10)},
        ]
        for changes in invalid:
            with self.subTest(changes=changes):
                add_walk(self.owner, day, **changes)
        add_run(self.other, day - timedelta(days=6), 7)
        self.assertEqual(self.task()["current_days"], 0)
        response = self.claim(day - timedelta(days=6))
        self.assertEqual((response.status_code, response.data["code"]), (409, "STREAK_NOT_READY"))
        self.assertFalse(PointEntry.objects.exists())

    def test_yesterday_run_remains_live_until_missed_day_finishes_then_restarts(self):
        start = date(2026, 9, 23)
        add_run(self.owner, start, 3)
        self.assertEqual(self.task()["current_days"], 3)
        self.now = datetime(2026, 9, 26, 23, 59, tzinfo=MELBOURNE)
        self.assertEqual(self.task()["run_start_date"], "2026-09-23")
        self.now = datetime(2026, 9, 27, 0, 0, tzinfo=MELBOURNE)
        self.assertEqual(self.task()["current_days"], 0)
        self.now = self.now.replace(hour=12)
        add_walk(self.owner, self.now.date())
        task = self.task()
        self.assertEqual((task["current_days"], task["run_start_date"], task["milestone_days"]), (1, "2026-09-27", 7))

    @override_settings(TIME_ZONE="UTC")
    def test_dst_spring_and_autumn_count_local_days_not_twenty_four_hour_windows(self):
        for start in (date(2026, 4, 2), date(2026, 10, 1)):
            with self.subTest(start=start):
                owner = User.objects.create_user(email=f"streak-dst-{start}@example.com", display_name="DST")
                self.client.force_authenticate(owner)
                add_run(owner, start, 7)
                self.now = datetime.combine(start + timedelta(days=6), time(12), tzinfo=MELBOURNE)
                self.assertEqual(self.task()["current_days"], 7)
                self.assertEqual(self.claim(start).status_code, 201)

    def test_walk_ending_after_midnight_counts_only_its_melbourne_end_day(self):
        self.now = datetime(2026, 9, 26, 0, 20, tzinfo=MELBOURNE)
        add_walk(self.owner, date(2026, 9, 26), started_at=self.now - timedelta(minutes=30), ended_at=self.now - timedelta(minutes=10))
        task = self.task()
        self.assertEqual((task["current_days"], task["run_start_date"]), (1, "2026-09-26"))

    def test_bar_stays_full_until_collect_then_advances_through_all_milestones(self):
        start = date(2026, 6, 29)
        add_run(self.owner, start, 90)
        self.assertEqual((self.task()["current_days"], self.task()["milestone_days"]), (90, 7))
        self.assertEqual(self.claim(start, 30).status_code, 409)
        for milestone, reward in ((7, 20), (30, 100), (60, 100), (90, 100)):
            task = self.task()
            self.assertEqual((task["status"], task["milestone_days"], task["progress"]), ("READY", milestone, 1))
            response = self.claim(start, milestone)
            self.assertEqual(response.status_code, 201)
            self.assertEqual(response.data["award"]["points"], reward)
        task = self.task()
        self.assertEqual((task["status"], task["current_days"], task["milestone_days"]), ("IN_PROGRESS", 90, 120))
        self.assertEqual(get_balance(self.owner), 320)
        self.assertEqual(QuestAward.objects.count(), 4)

    def test_earned_unclaimed_old_runs_survive_break_and_are_collected_oldest_first(self):
        old = date(2026, 8, 1)
        recent = date(2026, 9, 20)
        add_run(self.owner, old, 30)
        add_run(self.owner, recent, 7)
        self.assertEqual((self.task()["run_start_date"], self.task()["current_days"]), ("2026-08-01", 30))
        self.assertEqual(self.claim(recent).status_code, 409)
        self.assertEqual(self.claim(old).status_code, 201)
        self.assertEqual(self.task()["milestone_days"], 30)
        self.assertEqual(self.claim(old, 30).status_code, 201)
        self.assertEqual((self.task()["run_start_date"], self.task()["milestone_days"]), ("2026-09-20", 7))
        self.assertEqual(self.claim(recent).status_code, 201)
        self.assertEqual(get_balance(self.owner), 140)

    def test_old_earned_milestone_has_no_claim_expiry_and_then_idle_resets_target(self):
        start = date(2020, 1, 1)
        add_run(self.owner, start, 7)
        self.assertEqual(self.task()["status"], "READY")
        self.assertEqual(self.claim(start).status_code, 201)
        self.assertEqual(self.task()["id"], "streak:idle:7")
        self.assertIsNone(QuestAward.objects.get().claim_expires_at)

    def test_replay_after_disable_clock_change_and_new_wallet_activity_never_recredits(self):
        start = date(2026, 9, 20)
        add_run(self.owner, start, 7)
        original = self.claim(start)
        QuestDefinition.objects.filter(code="STREAK").update(is_enabled=False)
        self.now += timedelta(days=400)
        replay = self.claim(start, trailing_slash=True)
        self.assertEqual(replay.status_code, 200)
        self.assertFalse(replay.data["created"])
        self.assertEqual(replay.data["award"], original.data["award"])
        self.assertEqual(PointEntry.objects.count(), 1)
        self.assertFalse(any(task["kind"] == "STREAK" for task in self.client.get("/api/quests").data["tasks"]))
        denied = self.claim(start, 30)
        self.assertEqual((denied.status_code, denied.data["code"]), (409, "QUEST_DISABLED"))

    def test_permissions_input_validation_and_no_other_owners_progress_leaks(self):
        start = date(2026, 9, 20)
        add_run(self.owner, start, 7)
        self.client.force_authenticate(self.other)
        self.assertEqual(self.claim(start).status_code, 409)
        self.assertEqual(self.task()["current_days"], 0)
        for user in (self.cafe, self.admin):
            self.client.force_authenticate(user)
            self.assertEqual(self.claim(start).status_code, 403)
        self.client.force_authenticate(None)
        self.assertEqual(self.claim(start).status_code, 401)
        self.client.force_authenticate(self.owner)
        for milestone in (0, -30, 1, 14, 31):
            response = self.claim(start, milestone)
            self.assertEqual((response.status_code, response.data["code"]), (400, "INVALID_STREAK_MILESTONE"))
        for payload in ({}, {"run_start_date": "bad", "milestone_days": 7}, {"run_start_date": str(start), "milestone_days": "seven"}):
            response = self.client.post("/api/quests/streaks/collect", payload, format="json")
            self.assertEqual((response.status_code, response.data["code"]), (400, "INVALID_STREAK_REQUEST"))
        self.assertFalse(PointEntry.objects.exists())

    def test_late_award_write_failure_rolls_back_wallet_and_retry_succeeds_once(self):
        start = date(2026, 9, 20)
        add_run(self.owner, start, 7)
        with patch("quests.streaks.QuestAward.objects.create", side_effect=RuntimeError("late failure")):
            with self.assertRaises(RuntimeError):
                self.claim(start)
        self.assertEqual(PointEntry.objects.count(), 0)
        self.assertEqual(QuestAward.objects.count(), 0)
        self.assertEqual(self.task()["status"], "READY")
        self.assertEqual(self.claim(start).status_code, 201)
        self.assertEqual(self.claim(start).status_code, 200)
        self.assertEqual(PointEntry.objects.count(), 1)

    def test_existing_qualified_award_is_reused_and_explicit_expiry_is_respected(self):
        start = date(2026, 9, 20)
        walks = add_run(self.owner, start, 7)
        award = QuestAward.objects.create(
            owner=self.owner, kind="STREAK", qualification_key=f"streak:{self.owner.pk}:{start}:7",
            run_start_date=start, milestone_days=7, promised_points=20,
            qualified_at=walks[-1].ended_at, qualified_on=walks[-1].point_date,
            rules_version=STREAK_RULES_VERSION, claim_expires_at=self.now,
        )
        self.assertEqual(self.claim(start).data["code"], "QUALIFICATION_UNAVAILABLE")
        self.assertEqual(PointEntry.objects.count(), 0)
        award.claim_expires_at = None
        award.save(update_fields=["claim_expires_at"])
        response = self.claim(start)
        self.assertEqual(response.status_code, 201)
        self.assertEqual(response.data["award"]["id"], award.pk)
        self.assertEqual(QuestAward.objects.count(), 1)

    def test_real_validated_walk_can_complete_streak_after_daily_activity_cap(self):
        from rewards.services import credit_points

        start = date(2026, 9, 20)
        add_run(self.owner, start, 6)
        credit_points(user=self.owner, amount=72, type="EARN", source_reference="streak-test-cap",
                      earn_category="CHECK_IN", earned_on=self.now.date(), rules_version="test")
        ended_at = self.now - timedelta(minutes=1)
        started_at = ended_at - timedelta(seconds=30)
        samples = [dict(recorded_at=started_at, latitude=-37.81, longitude=144.96, accuracy_m=5, is_simulated=False),
                   dict(recorded_at=ended_at, latitude=-37.8098, longitude=144.96, accuracy_m=5, is_simulated=False)]
        walk = create_walk(owner=self.owner, request_id=uuid4(), started_at=started_at,
                           ended_at=ended_at, dog_ids=[], samples=samples)
        self.assertEqual(walk.points_awarded, 0)
        self.assertGreater(walk.active_seconds, 0)
        self.assertEqual(self.task()["status"], "READY")
        self.assertEqual(self.claim(start).data["award"]["points"], 20)
        self.assertEqual(get_balance(self.owner), 92)

    def test_late_yesterday_upload_joins_new_run_without_repeating_collected_seven_day_reward(self):
        self.now = datetime(2026, 9, 26, 0, 20, tzinfo=MELBOURNE)
        start = date(2026, 9, 18)
        add_run(self.owner, start, 7)
        add_walk(self.owner, self.now.date(), started_at=self.now - timedelta(minutes=20),
                 ended_at=self.now - timedelta(minutes=15))
        self.assertEqual(self.claim(start).status_code, 201)
        self.assertEqual((self.task()["current_days"], self.task()["run_start_date"]), (1, "2026-09-26"))
        ended_at = self.now - timedelta(minutes=30)
        started_at = ended_at - timedelta(seconds=30)
        samples = [dict(recorded_at=started_at, latitude=-37.81, longitude=144.96, accuracy_m=5, is_simulated=False),
                   dict(recorded_at=ended_at, latitude=-37.8098, longitude=144.96, accuracy_m=5, is_simulated=False)]
        create_walk(owner=self.owner, request_id=uuid4(), started_at=started_at, ended_at=ended_at,
                    dog_ids=[], samples=samples)
        task = self.task()
        self.assertEqual((task["current_days"], task["run_start_date"], task["milestone_days"]), (9, "2026-09-18", 30))
        self.assertEqual(self.claim(date(2026, 9, 26)).status_code, 409)
        self.assertFalse(self.claim(start).data["created"])
        self.assertEqual(QuestAward.objects.count(), 1)
        self.assertEqual(get_balance(self.owner), 20)


@skipUnless(connection.vendor == "mysql", "Requires MySQL row-lock semantics")
class StreakConcurrencyTests(TransactionTestCase):
    def test_parallel_collections_share_one_award_and_point_entry(self):
        QuestDefinition.objects.update_or_create(code="STREAK", defaults={"title": "Walking streak", "is_enabled": True})
        owner = User.objects.create_user(email="streak-concurrent@example.com", display_name="Walker")
        now = timezone.now()
        start = now.astimezone(MELBOURNE).date() - timedelta(days=7)
        add_run(owner, start, 7)
        barrier = Barrier(2)

        def collect(_):
            close_old_connections()
            try:
                barrier.wait(timeout=10)
                return collect_streak(owner=owner, run_start_date=start, milestone_days=7, now=now)
            finally:
                close_old_connections()

        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(collect, range(2)))
        self.assertEqual(sorted(result["created"] for result in results), [False, True])
        self.assertEqual(results[0]["award"].pk, results[1]["award"].pk)
        self.assertEqual(QuestAward.objects.count(), 1)
        self.assertEqual(PointEntry.objects.count(), 1)
        self.assertEqual(get_balance(owner), 20)

    def test_final_day_walk_submission_and_collection_are_serialized(self):
        QuestDefinition.objects.update_or_create(code="STREAK", defaults={"title": "Walking streak", "is_enabled": True})
        owner = User.objects.create_user(email="streak-walk-race@example.com", display_name="Walker")
        now = datetime(2026, 9, 26, 12, tzinfo=MELBOURNE)
        start = now.date() - timedelta(days=6)
        add_run(owner, start, 6)
        ended_at = now - timedelta(minutes=1)
        started_at = ended_at - timedelta(seconds=30)
        samples = [dict(recorded_at=started_at, latitude=-37.81, longitude=144.96, accuracy_m=5, is_simulated=False),
                   dict(recorded_at=ended_at, latitude=-37.8098, longitude=144.96, accuracy_m=5, is_simulated=False)]
        barrier = Barrier(2)

        def act(action):
            close_old_connections()
            try:
                barrier.wait(timeout=10)
                if action == "walk":
                    return create_walk(owner=owner, request_id=uuid4(), started_at=started_at,
                                       ended_at=ended_at, dog_ids=[], samples=samples)
                try:
                    return collect_streak(owner=owner, run_start_date=start, milestone_days=7, now=now)
                except StreakClaimError as exc:
                    self.assertEqual(exc.code, "STREAK_NOT_READY")
                    return None
            finally:
                close_old_connections()

        with patch("django.utils.timezone.now", return_value=now), ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(act, ("walk", "collect")))
            retry = collect_streak(owner=owner, run_start_date=start, milestone_days=7, now=now)
            self.assertEqual(retry["created"], results[1] is None)
            self.assertEqual(get_balance(owner), 20)
        self.assertEqual(Walk.objects.count(), 7)
        self.assertEqual(QuestAward.objects.count(), 1)
        self.assertEqual(PointEntry.objects.count(), 1)
