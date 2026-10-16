from datetime import datetime, timedelta
from decimal import Decimal
from unittest.mock import patch
from uuid import uuid4
from zoneinfo import ZoneInfo

from django.contrib.auth import get_user_model
from django.test import override_settings
from rest_framework.test import APITestCase

from dogs.goals import configure_target
from dogs.models import Breed, Dog, DogDailyGoal, DogGoalTarget
from rewards.models import PointEntry
from rewards.policy import local_date, local_midnight
from social.models import Friendship, UserBlock
from walks.models import Walk, WalkDog

User = get_user_model()


class StatisticsApiTests(APITestCase):
    @classmethod
    def setUpTestData(cls):
        cls.owner = User.objects.create_user(
            email="owner-private@example.com", display_name="Owner public name",
            public_id="1" * 32,
        )
        cls.friend = User.objects.create_user(
            email="friend-private@example.com", display_name="Friend public name",
            public_id="2" * 32, leaderboard_visible=True,
        )

    def setUp(self):
        # Melbourne has already moved to the next day while UTC has not.
        self.now = datetime(2026, 10, 16, 0, 5, tzinfo=ZoneInfo("Australia/Melbourne"))
        self.today = local_date(self.now)
        clock = patch("activity_stats.views.timezone.now", return_value=self.now)
        clock.start()
        self.addCleanup(clock.stop)
        self.client.force_authenticate(self.owner)

    def friend_pair(self, other=None, *, status="ACCEPTED"):
        other = other or self.friend
        low, high = sorted((self.owner.pk, other.pk))
        return Friendship.objects.create(
            user_low_id=low, user_high_id=high, requested_by=self.owner,
            status=status, responded_at=None if status == "PENDING" else self.now,
        )

    def walk(self, owner=None, *, day=None, seconds=600, metres="500.00", **changes):
        day = day or self.today
        ended = local_midnight(day) + timedelta(minutes=4)
        values = {
            "owner": owner or self.owner, "request_id": uuid4(),
            "request_fingerprint": "statistics-fixture", "point_date": day,
            "started_at": ended - timedelta(seconds=max(seconds or 0, 1)),
            "ended_at": ended, "distance_m": Decimal(metres),
            "active_seconds": seconds, "rules_version": "walk-gps-v2",
            "validation_summary": {"accepted_moving_segments": 1},
        }
        values.update(changes)
        return Walk.objects.create(**values)

    def leaderboard(self):
        response = self.client.get("/api/statistics/leaderboard/")
        self.assertEqual(response.status_code, 200, response.data)
        self.assertEqual(response["Cache-Control"], "private, no-store")
        return response.data

    def test_statistics_empty_state_is_private_and_does_not_award_points(self):
        response = self.client.get("/api/statistics/")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response["Cache-Control"], "private, no-store")
        self.assertEqual(response.data["today_walking_minutes"], 0)
        self.assertEqual(response.data["today_distance_km"], 0)
        self.assertEqual(response.data["daily_goal_progress"], 0)
        self.assertEqual(response.data["daily_goal_target_seconds"], 0)
        self.assertEqual(response.data["dog_daily_goals"], [])
        self.assertFalse(response.data["leaderboard_visible"])
        self.assertEqual([day["date"] for day in response.data["seven_day_goals"]], [
            (self.today - timedelta(days=offset)).isoformat() for offset in range(6, -1, -1)
        ])
        self.assertFalse(any(day["completed"] for day in response.data["seven_day_goals"]))
        self.assertEqual(PointEntry.objects.count(), 0)

    def test_anonymous_cafe_admin_inactive_and_deleted_accounts_cannot_read_or_patch(self):
        paths = ("/api/statistics/", "/api/statistics/leaderboard/")
        self.client.force_authenticate(None)
        for path in paths:
            response = self.client.get(path)
            self.assertEqual(response.status_code, 401)
            self.assertEqual(response["Cache-Control"], "private, no-store")
        for changes in ({"role": "CAFE"}, {"role": "ADMIN"}, {"is_active": False}, {"deleted_at": self.now}):
            with self.subTest(changes=changes):
                User.objects.filter(pk=self.owner.pk).update(
                    role="OWNER", is_active=True, deleted_at=None, **{
                        key: value for key, value in changes.items() if key not in {"role", "is_active", "deleted_at"}
                    },
                )
                User.objects.filter(pk=self.owner.pk).update(**changes)
                self.owner.refresh_from_db()
                self.client.force_authenticate(self.owner)
                for path in paths:
                    self.assertEqual(self.client.get(path).status_code, 403)
                self.assertEqual(self.client.patch("/api/statistics/", {"leaderboard_visible": True}, format="json").status_code, 403)

    @override_settings(TIME_ZONE="UTC")
    def test_personal_totals_use_valid_completed_walks_and_melbourne_end_date(self):
        self.walk(seconds=125, metres="1200.00")
        self.walk(seconds=59, metres="300.00")
        self.walk(day=self.today - timedelta(days=1), seconds=600)
        self.walk(owner=self.friend, seconds=600)
        self.walk(rules_version=None)
        self.walk(validation_summary={"accepted_moving_segments": 0})
        self.walk(active_seconds=None)
        self.walk(metres="0.00")
        self.walk(ended_at=self.now + timedelta(minutes=2))
        self.walk(point_date=self.today - timedelta(days=1))
        self.walk(started_at=self.now - timedelta(seconds=30), ended_at=self.now, active_seconds=600)
        response = self.client.get("/api/statistics/")
        self.assertEqual(response.status_code, 200, response.data)
        self.assertEqual(response.data["today_walking_minutes"], 3)
        self.assertEqual(response.data["today_distance_km"], 1.5)
        self.assertEqual(response.data["seven_day_goals"][-1]["date"], "2026-10-16")

    def test_per_dog_progress_caps_each_dog_and_does_not_reuse_owner_walking_time(self):
        self.walk(seconds=3600)
        def day(state):
            return {"date": self.today, "state": state}
        goals = [
            {"dog_id": 1, "dog_name": "Milo", "active_seconds": 2400,
             "target_seconds": 1200, "completed": True, "days": [day("COMPLETED")]},
            {"dog_id": 2, "dog_name": "Pip", "active_seconds": 0,
             "target_seconds": 1800, "completed": False, "days": [day("INCOMPLETE")]},
            {"dog_id": 3, "dog_name": "Rest", "active_seconds": 0,
             "target_seconds": None, "completed": False, "days": [day("NOT_ELIGIBLE")]},
        ]
        with patch("activity_stats.views.goal_progress", return_value=goals) as progress:
            response = self.client.get("/api/statistics/")
        progress.assert_called_once_with(owner=self.owner, now=self.now)
        self.assertEqual(response.data["today_walking_minutes"], 60)
        self.assertEqual(response.data["daily_goal_minutes"], 50)
        self.assertEqual(response.data["daily_goal_active_seconds"], 1200)
        self.assertEqual(response.data["daily_goal_target_seconds"], 3000)
        self.assertEqual(response.data["daily_goal_progress"], 0.4)
        self.assertFalse(response.data["seven_day_goals"][-1]["completed"])
        self.assertEqual(len(response.data["dog_daily_goals"]), 3)
        self.assertEqual(PointEntry.objects.count(), 0)

    def test_real_dog_targets_and_walk_participation_feed_statistics_without_awards(self):
        created_at = local_midnight(self.today)
        with patch("django.utils.timezone.now", return_value=created_at):
            breed = Breed.objects.create(name="Statistics breed", energy_level="LOW", default_size="SMALL")
            dogs = [Dog.objects.create(owner=self.owner, breed=breed, name=name, age_months=24,
                                       size="SMALL", is_brachycephalic=False)
                    for name in ("Milo", "Pip")]
            configure_target(dog=dogs[0], target_active_seconds=120, effective_from=self.today)
            configure_target(dog=dogs[1], target_active_seconds=240, effective_from=self.today)
        walk = self.walk(seconds=180)
        WalkDog.objects.create(walk=walk, dog=dogs[0], active_seconds=180, distance_m=Decimal("500"))
        WalkDog.objects.create(walk=walk, dog=dogs[1], active_seconds=60, distance_m=Decimal("150"))

        response = self.client.get("/api/statistics/")
        self.assertEqual(response.status_code, 200, response.data)
        self.assertEqual(response.data["today_walking_minutes"], 3)
        self.assertEqual(response.data["daily_goal_minutes"], 6)
        self.assertEqual(response.data["daily_goal_active_seconds"], 180)
        self.assertEqual(response.data["daily_goal_target_seconds"], 360)
        self.assertEqual(response.data["daily_goal_progress"], 0.5)
        self.assertEqual(response.data["dog_daily_goals"], [
            {"dog_id": dogs[0].pk, "dog_name": "Milo", "active_seconds": 180,
             "target_seconds": 120, "completed": True},
            {"dog_id": dogs[1].pk, "dog_name": "Pip", "active_seconds": 60,
             "target_seconds": 240, "completed": False},
        ])
        self.assertFalse(response.data["seven_day_goals"][-1]["completed"])
        repeated = self.client.get("/api/statistics/")
        self.assertEqual(repeated.data, response.data)
        self.assertEqual(DogGoalTarget.objects.count(), 2)
        self.assertEqual(DogDailyGoal.objects.count(), 2)
        self.assertEqual(PointEntry.objects.count(), 0)

    def test_goal_calendar_requires_all_eligible_dogs_and_does_not_invent_missing_goals(self):
        yesterday = self.today - timedelta(days=1)
        goals = [
            {"dog_id": 1, "dog_name": "Milo", "active_seconds": 61,
             "target_seconds": 61, "completed": True, "days": [
                 {"date": yesterday, "state": "COMPLETED"}, {"date": self.today, "state": "COMPLETED"}]},
            {"dog_id": 2, "dog_name": "Pip", "active_seconds": 0,
             "target_seconds": None, "completed": False, "days": [
                 {"date": yesterday, "state": "NOT_ELIGIBLE"}, {"date": self.today, "state": "NOT_ELIGIBLE"}]},
        ]
        with patch("activity_stats.views.goal_progress", return_value=goals):
            response = self.client.get("/api/statistics/")
        self.assertEqual(response.data["daily_goal_minutes"], 2)
        self.assertEqual(response.data["daily_goal_progress"], 1)
        self.assertTrue(response.data["seven_day_goals"][-1]["completed"])
        self.assertTrue(response.data["seven_day_goals"][-2]["completed"])
        self.assertFalse(response.data["seven_day_goals"][-3]["completed"])

    def test_own_private_row_always_shown_and_public_identity_has_no_email(self):
        data = self.leaderboard()
        self.assertEqual(data["my_rank"], 1)
        self.assertEqual(len(data["entries"]), 1)
        self.assertEqual(data["entries"][0], {
            "public_id": self.owner.public_id, "display_name": "Owner public name",
            "rank": 1, "value": 0, "is_current_user": True,
        })
        self.assertNotIn("@", str(data))
        self.assertNotIn("user_id", data["entries"][0])

    def test_accepted_visible_friend_only_and_pending_declined_strangers_hidden(self):
        self.friend_pair()
        for index, status in enumerate(("PENDING", "DECLINED", None), start=3):
            peer = User.objects.create_user(email=f"private{index}@example.com", display_name=f"Peer {index}", leaderboard_visible=True)
            if status:
                self.friend_pair(peer, status=status)
            self.walk(owner=peer)
        self.walk(owner=self.friend)
        data = self.leaderboard()
        self.assertEqual({row["public_id"] for row in data["entries"]}, {self.owner.public_id, self.friend.public_id})
        self.assertEqual(data["entries"][0]["display_name"], "Friend public name")
        self.assertNotIn("@", str(data))

    def test_default_private_friend_and_withdrawn_visibility_are_hidden_immediately(self):
        self.friend_pair()
        User.objects.filter(pk=self.friend.pk).update(leaderboard_visible=False)
        self.assertEqual(len(self.leaderboard()["entries"]), 1)
        self.client.force_authenticate(self.friend)
        response = self.client.patch("/api/statistics/", {"leaderboard_visible": True}, format="json")
        self.assertEqual(response.status_code, 200)
        self.client.force_authenticate(self.owner)
        self.assertEqual(len(self.leaderboard()["entries"]), 2)
        self.client.force_authenticate(self.friend)
        self.assertEqual(self.client.patch("/api/statistics/", {"leaderboard_visible": False}, format="json").status_code, 200)
        self.client.force_authenticate(self.owner)
        self.assertEqual(len(self.leaderboard()["entries"]), 1)

    def test_both_block_directions_hide_a_friend_even_if_stale_friendship_exists(self):
        self.friend_pair()
        for blocker, blocked in ((self.owner, self.friend), (self.friend, self.owner)):
            with self.subTest(blocker=blocker.pk):
                block = UserBlock.objects.create(blocker=blocker, blocked=blocked)
                self.assertEqual(len(self.leaderboard()["entries"]), 1)
                block.delete()
        self.assertEqual(len(self.leaderboard()["entries"]), 2)

    def test_removed_friend_disappears(self):
        friendship = self.friend_pair()
        self.assertEqual(len(self.leaderboard()["entries"]), 2)
        friendship.delete()
        self.assertEqual(len(self.leaderboard()["entries"]), 1)

    def test_nonowner_inactive_and_deleted_friends_hidden(self):
        self.friend_pair()
        for changes in ({"role": "CAFE"}, {"role": "ADMIN"}, {"is_active": False}, {"deleted_at": self.now}):
            with self.subTest(changes=changes):
                User.objects.filter(pk=self.friend.pk).update(role="OWNER", is_active=True, deleted_at=None)
                User.objects.filter(pk=self.friend.pk).update(**changes)
                self.assertEqual(len(self.leaderboard()["entries"]), 1)

    def test_rolling_period_includes_both_melbourne_endpoints_not_eighth_day(self):
        self.friend_pair()
        self.walk(owner=self.friend, day=self.today - timedelta(days=6), seconds=60)
        self.walk(owner=self.friend, day=self.today, seconds=120)
        self.walk(owner=self.friend, day=self.today - timedelta(days=7), seconds=600)
        self.walk(owner=self.friend, day=self.today + timedelta(days=1), seconds=600)
        data = self.leaderboard()
        self.assertEqual(data["entries"][0]["value"], 3)
        self.assertEqual(data["start_date"], "2026-10-10")
        self.assertEqual(data["end_date"], "2026-10-16")
        self.assertEqual(data["timezone"], "Australia/Melbourne")
        self.assertEqual(data["unit"], "min")

    def test_ties_use_exact_seconds_competition_ranks_and_stable_public_id(self):
        self.friend_pair()
        third = User.objects.create_user(email="third-private@example.com", display_name="Third", public_id="3" * 32, leaderboard_visible=True)
        self.friend_pair(third)
        self.walk(seconds=121)
        self.walk(owner=self.friend, seconds=121)
        self.walk(owner=third, seconds=120)
        data = self.leaderboard()
        self.assertEqual([row["rank"] for row in data["entries"]], [1, 1, 3])
        self.assertEqual([row["public_id"] for row in data["entries"]], [self.owner.public_id, self.friend.public_id, third.public_id])
        self.assertEqual(data["my_rank"], 1)
        self.assertEqual(data, self.leaderboard())

    def test_leaderboard_excludes_unvalidated_zero_future_and_corrupt_walks(self):
        self.friend_pair()
        self.walk(owner=self.friend, seconds=60)
        self.walk(owner=self.friend, rules_version="legacy")
        self.walk(owner=self.friend, validation_summary={})
        self.walk(owner=self.friend, validation_summary={"accepted_moving_segments": True})
        self.walk(owner=self.friend, metres="0.00")
        self.walk(owner=self.friend, seconds=0)
        self.walk(owner=self.friend, ended_at=self.now + timedelta(minutes=2))
        self.walk(owner=self.friend, point_date=self.today - timedelta(days=1))
        self.walk(owner=self.friend, started_at=self.now - timedelta(seconds=30), ended_at=self.now, active_seconds=600)
        self.assertEqual(self.leaderboard()["entries"][0]["value"], 1)
        self.assertEqual(PointEntry.objects.count(), 0)

    def test_opt_in_patch_changes_only_authenticated_owners_visibility_and_is_repeat_safe(self):
        self.owner.location_visibility = "FRIENDS"
        self.owner.net_matching_enabled = True
        self.owner.save(update_fields=("location_visibility", "net_matching_enabled"))
        for _ in range(2):
            response = self.client.patch("/api/statistics/", {"leaderboard_visible": True}, format="json")
            self.assertEqual(response.status_code, 200)
            self.assertTrue(response.data["leaderboard_visible"])
            self.assertEqual(response["Cache-Control"], "private, no-store")
        self.owner.refresh_from_db()
        self.assertTrue(self.owner.location_visibility == "FRIENDS")
        self.assertTrue(self.owner.net_matching_enabled)
        self.assertEqual(PointEntry.objects.count(), 0)

    def test_opt_in_patch_rejects_nonbooleans_missing_unknown_and_other_account_fields(self):
        for payload in ({}, [], {"leaderboard_visible": "true"}, {"leaderboard_visible": 1},
                        {"leaderboard_visible": None}, {"leaderboard_visible": True, "user_id": self.friend.pk},
                        {"leaderboard_visible": True, "location_visibility": "FRIENDS"}):
            with self.subTest(payload=payload):
                response = self.client.patch("/api/statistics/", payload, format="json")
                self.assertEqual(response.status_code, 400, response.data)
                self.assertEqual(response["Cache-Control"], "private, no-store")
        self.owner.refresh_from_db()
        self.assertFalse(self.owner.leaderboard_visible)
