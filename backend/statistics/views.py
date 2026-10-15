
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response
from rest_framework.views import APIView
from django.utils import timezone


class UserStatisticsView(APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request):
        today = timezone.localdate()
        totals = calculate_walking_totals(
            request.user,
            today,
        )

        return Response({
            "today_walking_minutes": totals["walking_minutes"],
            "today_distance_km": totals["distance_km"],
            "daily_goal_minutes": calculate_daily_goal_minutes(request.user),
            "seven_day_goals": calculate_seven_day_goals(request.user),
        })


class FriendsLeaderboardView(APIView):
    permission_classes = [IsAuthenticated]

    def get(self, request):
        from datetime import timedelta
        from django.contrib.auth import get_user_model
        from django.db.models import Q, Sum
        from social.models import Friendship
        from walks.models import Walk

        user = request.user
        today = timezone.localdate()
        start_date = today - timedelta(days=6)

        # Find accepted friendships only
        friendships = Friendship.objects.filter(
            Q(user_low=user) | Q(user_high=user),
            status=Friendship.Status.ACCEPTED,
        )

        friend_ids = set()

        for friendship in friendships:
            if friendship.user_low_id == user.id:
                friend_ids.add(friendship.user_high_id)
            else:
                friend_ids.add(friendship.user_low_id)

        # Include the current user
        user_ids = friend_ids | {user.id}

        User = get_user_model()
        users = User.objects.filter(id__in=user_ids)

        # Total walking seconds over the last 7 days
        walking_totals = (
            Walk.objects.filter(
                owner_id__in=user_ids,
                point_date__range=(start_date, today),
            )
            .values("owner_id")
            .annotate(total_seconds=Sum("active_seconds"))
        )

        seconds_by_user = {
            item["owner_id"]: item["total_seconds"] or 0
            for item in walking_totals
        }

        leaderboard = []

        for member in users:
            minutes = round(
                seconds_by_user.get(member.id, 0) / 60,
                2,
            )

            display_name = member.get_username()

            leaderboard.append({
                "user_id": member.id,
                "display_name": display_name,
                "value": minutes,
                "is_current_user": member.id == user.id,
            })

        # Highest walking minutes first
        leaderboard.sort(
            key=lambda entry: (-entry["value"], entry["user_id"])
        )

        entries = []
        my_rank = None

        for rank, entry in enumerate(leaderboard, start=1):
            entry["rank"] = rank
            entries.append(entry)

            if entry["is_current_user"]:
                my_rank = rank

        return Response({
            "metric": "Walking minutes",
            "period": "Last 7 days",
            "my_rank": my_rank,
            "entries": entries,
        })

def calculate_walking_totals(user, date):
    from django.db.models import Sum
    from walks.models import Walk

    totals = Walk.objects.filter(
        owner=user,
        point_date=date,
    ).aggregate(
        seconds=Sum("active_seconds"),
        metres=Sum("distance_m"),
    )

    return {
        "walking_minutes": int(
            (totals["seconds"] or 0) / 60
        ),
        "distance_km": round(
            float(totals["metres"] or 0) / 1000,
            2,
        ),
    }

def calculate_seven_day_goals(user):
    from datetime import timedelta
    from dogs.goals import goal_progress
    from rewards.policy import local_date

    today = local_date()
    dog_goals = goal_progress(owner=user)

    results = []

    for days_ago in range(6, -1, -1):
        day = today - timedelta(days=days_ago)
        date_string = day.isoformat()

        eligible_goals = [
            entry
            for dog in dog_goals
            for entry in dog["days"]
            if entry["date"] == day
            and entry["state"] != "NOT_ELIGIBLE"
        ]

        completed = (
            len(eligible_goals) > 0
            and all(
                entry["state"] == "COMPLETED"
                for entry in eligible_goals
            )
        )

        results.append({
            "date": date_string,
            "completed": completed,
        })

    return results

def calculate_daily_goal_minutes(user):
    from dogs.goals import goal_progress

    dog_goals = goal_progress(owner=user)

    targets = [
        dog["target_seconds"]
        for dog in dog_goals
        if dog["target_seconds"] is not None
        and dog["target_seconds"] > 0
    ]

    if not targets:
        return 0

    return max(targets) // 60


