

from django.urls import path
from .views import UserStatisticsView, FriendsLeaderboardView

urlpatterns = [
    path("", UserStatisticsView.as_view(), name="statistics"),
    path("leaderboard", FriendsLeaderboardView.as_view(), name="leaderboard"),
]
