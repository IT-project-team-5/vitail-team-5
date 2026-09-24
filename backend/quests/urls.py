from django.urls import re_path

from .views import BirthdayCollectionView, LeaderboardView, QuestDashboardView


urlpatterns = [
    re_path(r"^quests/?$", QuestDashboardView.as_view(), name="quest-dashboard"),
    re_path(r"^leaderboard/?$", LeaderboardView.as_view(), name="leaderboard"),
    re_path(r"^quests/birthdays/(?P<dog_id>[0-9]+)/collect/?$", BirthdayCollectionView.as_view(), name="birthday-collect"),
]
