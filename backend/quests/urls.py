from django.urls import re_path

from .views import BirthdayCollectionView, QuestDashboardView, QuestTestResetView, StreakCollectionView, DailyGoalCollectionView


urlpatterns = [
    re_path(r"^quests/goals/(?P<dog_id>[0-9]+)/collect/?$", DailyGoalCollectionView.as_view(), name="daily-goal-collect"),
    re_path(r"^quests/?$", QuestDashboardView.as_view(), name="quest-dashboard"),
    re_path(r"^quests/birthdays/(?P<dog_id>[0-9]+)/collect/?$", BirthdayCollectionView.as_view(), name="birthday-collect"),
    re_path(r"^quests/streaks/collect/?$", StreakCollectionView.as_view(), name="streak-collect"),
    re_path(r"^quests/reset/?$", QuestTestResetView.as_view(), name="quest-test-reset"),
]
