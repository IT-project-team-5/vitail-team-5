"""Private personal activity and an opt-in friends leaderboard.

The candidate ranking uses completed, validated walking time over seven
Melbourne calendar days. It reads the existing walks and per-dog goal records;
it never creates a second activity counter or awards points.
"""
from collections import defaultdict
from datetime import timedelta
from math import ceil

from django.contrib.auth import get_user_model
from django.db import transaction
from django.db.models import Q
from django.utils import timezone
from rest_framework.exceptions import ValidationError
from rest_framework.permissions import BasePermission
from rest_framework.response import Response
from rest_framework.views import APIView

from dogs.goals import goal_progress
from rewards.policy import local_date
from social.live import blocked_ids
from social.models import Friendship
from walks.eligibility import SUMMARY_FIELDS, TRUSTED_WALK_RULES, has_validated_movement
from walks.models import Walk


class IsActiveOwner(BasePermission):
    message = "Only active dog owner accounts can access statistics."

    def has_permission(self, request, view):
        return bool(request.user.is_authenticated and get_user_model().objects.filter(
            pk=request.user.pk, role="OWNER", is_active=True, deleted_at__isnull=True,
        ).exists())


class StatisticsView(APIView):
    permission_classes = [IsActiveOwner]

    def finalize_response(self, request, response, *args, **kwargs):
        response = super().finalize_response(request, response, *args, **kwargs)
        response["Cache-Control"] = "private, no-store"
        return response


def validated_walks(owner_ids, start_date, end_date, now):
    rows = Walk.objects.filter(
        owner_id__in=owner_ids, point_date__range=(start_date, end_date),
        rules_version__in=TRUSTED_WALK_RULES, active_seconds__gt=0, distance_m__gt=0,
    ).values("owner_id", "distance_m", *SUMMARY_FIELDS)
    return (row for row in rows if has_validated_movement(row, now))


def personal_statistics(owner, *, now):
    today = local_date(now)
    walks = list(validated_walks([owner.pk], today, today, now))
    dog_goals = goal_progress(owner=owner, now=now)
    eligible = [dog for dog in dog_goals if dog["target_seconds"] and dog["target_seconds"] > 0]
    target_seconds = sum(dog["target_seconds"] for dog in eligible)
    active_seconds = sum(min(dog["active_seconds"], dog["target_seconds"]) for dog in eligible)
    calendar = []
    for offset in range(6, -1, -1):
        day = today - timedelta(days=offset)
        goals = [entry for dog in dog_goals for entry in dog["days"]
                 if entry["date"] == day and entry["state"] != "NOT_ELIGIBLE"]
        calendar.append({"date": day.isoformat(), "completed": bool(goals) and all(
            entry["state"] == "COMPLETED" for entry in goals
        )})
    owner.refresh_from_db(fields=("leaderboard_visible",))
    return {
        "today_walking_minutes": sum(row["active_seconds"] for row in walks) // 60,
        "today_distance_km": round(float(sum(row["distance_m"] for row in walks)) / 1000, 2),
        "daily_goal_minutes": ceil(target_seconds / 60),
        "daily_goal_active_seconds": active_seconds,
        "daily_goal_target_seconds": target_seconds,
        "daily_goal_progress": active_seconds / target_seconds if target_seconds else 0,
        "dog_daily_goals": [{key: dog[key] for key in (
            "dog_id", "dog_name", "active_seconds", "target_seconds", "completed",
        )} for dog in dog_goals],
        "seven_day_goals": calendar,
        "leaderboard_visible": owner.leaderboard_visible,
    }


class UserStatisticsView(StatisticsView):
    def get(self, request):
        return Response(personal_statistics(request.user, now=timezone.now()))

    @transaction.atomic
    def patch(self, request):
        if (not isinstance(request.data, dict) or set(request.data) != {"leaderboard_visible"}
                or type(request.data.get("leaderboard_visible")) is not bool):
            raise ValidationError({"leaderboard_visible": "Send only leaderboard_visible as true or false."})
        owner = get_user_model().objects.select_for_update().get(pk=request.user.pk)
        owner.leaderboard_visible = request.data["leaderboard_visible"]
        owner.save(update_fields=("leaderboard_visible",))
        return Response(personal_statistics(owner, now=timezone.now()))


class FriendsLeaderboardView(StatisticsView):
    def get(self, request):
        now = timezone.now()
        today = local_date(now)
        start_date = today - timedelta(days=6)
        friendships = Friendship.objects.filter(
            Q(user_low_id=request.user.pk) | Q(user_high_id=request.user.pk),
            status=Friendship.Status.ACCEPTED,
        ).values_list("user_low_id", "user_high_id")
        friend_ids = {high if low == request.user.pk else low for low, high in friendships}
        visible_ids = friend_ids - blocked_ids(request.user.pk)
        members = list(get_user_model().objects.filter(
            Q(pk=request.user.pk) | Q(pk__in=visible_ids, leaderboard_visible=True),
            role="OWNER", is_active=True, deleted_at__isnull=True,
        ).only("id", "public_id", "display_name"))
        seconds = defaultdict(int)
        for row in validated_walks([member.pk for member in members], start_date, today, now):
            seconds[row["owner_id"]] += row["active_seconds"]
        members.sort(key=lambda member: (-seconds[member.pk], member.public_id))
        entries = []
        my_rank = None
        prior_seconds = None
        rank = 0
        for position, member in enumerate(members, start=1):
            total = seconds[member.pk]
            if total != prior_seconds:
                rank = position
            prior_seconds = total
            is_current_user = member.pk == request.user.pk
            entries.append({
                "public_id": member.public_id, "display_name": member.display_name,
                "rank": rank, "value": round(total / 60, 2),
                "is_current_user": is_current_user,
            })
            if is_current_user:
                my_rank = rank
        return Response({
            "metric": "Walking minutes", "period": "Last 7 days", "unit": "min",
            "start_date": start_date.isoformat(), "end_date": today.isoformat(),
            "timezone": "Australia/Melbourne", "my_rank": my_rank, "entries": entries,
        })
