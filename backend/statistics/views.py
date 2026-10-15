
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
        return Response(
            {
                "detail": "Leaderboard data integration is pending."
            },
            status=501,
        )

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


