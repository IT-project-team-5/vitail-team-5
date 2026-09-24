from rest_framework import serializers


class DogIdentitySerializer(serializers.Serializer):
    dog_id = serializers.IntegerField()
    name = serializers.CharField()
    photo = serializers.CharField(allow_null=True)


class GoalDogSerializer(DogIdentitySerializer):
    distance_m = serializers.DecimalField(max_digits=16, decimal_places=2, coerce_to_string=True)
    target_distance_m = serializers.DecimalField(max_digits=16, decimal_places=2, allow_null=True, coerce_to_string=True)
    active_seconds = serializers.IntegerField(allow_null=True)
    target_active_seconds = serializers.IntegerField(allow_null=True)
    progress = serializers.FloatField(allow_null=True)


class DailyGoalSerializer(serializers.Serializer):
    status = serializers.CharField()
    dogs = GoalDogSerializer(many=True)
    reward_points = serializers.IntegerField(allow_null=True)
    message = serializers.CharField()


class StreakMilestoneSerializer(serializers.Serializer):
    days = serializers.IntegerField()
    reward_points = serializers.IntegerField()


class StreakSerializer(serializers.Serializer):
    status = serializers.CharField()
    current_days = serializers.IntegerField()
    longest_days = serializers.IntegerField()
    active_today = serializers.BooleanField()
    milestones = StreakMilestoneSerializer(many=True)
    next_milestone = StreakMilestoneSerializer()
    award_status = serializers.CharField()


class BirthdayDogSerializer(DogIdentitySerializer):
    date_of_birth = serializers.DateField(allow_null=True)
    next_birthday = serializers.DateField(allow_null=True)
    is_birthday_today = serializers.BooleanField()
    status = serializers.CharField()


class BirthdaySerializer(serializers.Serializer):
    status = serializers.CharField()
    reward_points = serializers.IntegerField(allow_null=True)
    dogs = BirthdayDogSerializer(many=True)
    message = serializers.CharField()


class UnavailableTasksSerializer(serializers.Serializer):
    status = serializers.CharField()
    items = serializers.ListField(child=serializers.DictField())
    message = serializers.CharField()


class QuestDashboardSerializer(serializers.Serializer):
    server_time = serializers.DateTimeField()
    timezone = serializers.CharField()
    local_date = serializers.DateField()
    next_reset_at = serializers.DateTimeField()
    daily_goal = DailyGoalSerializer()
    streak = StreakSerializer()
    birthdays = BirthdaySerializer()
    check_ins = UnavailableTasksSerializer()
    documents = UnavailableTasksSerializer()


class BirthdayAwardSerializer(serializers.Serializer):
    id = serializers.IntegerField()
    kind = serializers.CharField()
    dog_id = serializers.IntegerField(source="dog_id_snapshot")
    year = serializers.IntegerField()
    points = serializers.IntegerField(source="point_entry.amount")
    awarded_at = serializers.DateTimeField()


class BirthdayCollectionSerializer(serializers.Serializer):
    award = BirthdayAwardSerializer()
    balance = serializers.IntegerField()
    created = serializers.BooleanField()


class LeaderboardQuerySerializer(serializers.Serializer):
    period = serializers.ChoiceField(choices=("week", "all_time"), default="week")


class LeaderboardEntrySerializer(serializers.Serializer):
    rank = serializers.IntegerField()
    user_id = serializers.IntegerField()
    display_name = serializers.CharField()
    photo = serializers.CharField(allow_null=True)
    is_current_user = serializers.BooleanField()
    distance_m = serializers.DecimalField(max_digits=16, decimal_places=2, coerce_to_string=True)
    walk_count = serializers.IntegerField()
    walking_points = serializers.IntegerField()


class LeaderboardSerializer(serializers.Serializer):
    server_time = serializers.DateTimeField()
    timezone = serializers.CharField()
    period = serializers.CharField()
    starts_at = serializers.DateTimeField(allow_null=True)
    ends_at = serializers.DateTimeField()
    scope = serializers.CharField()
    friends_available = serializers.BooleanField()
    message = serializers.CharField()
    entries = LeaderboardEntrySerializer(many=True)
