from django.urls import path

from .views import FriendsLeaderboardView, UserStatisticsView

urlpatterns = [
    path("", UserStatisticsView.as_view(), name="statistics"),
    path("leaderboard/", FriendsLeaderboardView.as_view(), name="leaderboard"),
]
