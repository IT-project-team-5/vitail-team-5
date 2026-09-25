from rest_framework import serializers


class QuestTaskSerializer(serializers.Serializer):
    id = serializers.CharField()
    kind = serializers.ChoiceField(choices=("BIRTHDAY", "COUNCIL_REGISTRATION", "MICROCHIP_REGISTRATION", "VET_CHECKUP", "DAILY_GOAL", "STREAK"))
    status = serializers.ChoiceField(choices=("IN_PROGRESS", "READY", "COLLECTED"))
    title = serializers.CharField()
    subtitle = serializers.CharField()
    subject_name = serializers.CharField()
    photo = serializers.CharField(allow_null=True)
    icon = serializers.CharField()
    detail = serializers.CharField()
    reward_points = serializers.IntegerField()
    progress = serializers.FloatField(allow_null=True)
    dog_id = serializers.IntegerField(allow_null=True)
    entitlement_id = serializers.IntegerField(allow_null=True)
    collected_at = serializers.DateTimeField(allow_null=True)
    current_days = serializers.IntegerField(required=False)
    milestone_days = serializers.IntegerField(required=False)
    run_start_date = serializers.DateField(required=False, allow_null=True)


class QuestDashboardSerializer(serializers.Serializer):
    server_time = serializers.DateTimeField()
    timezone = serializers.CharField()
    local_date = serializers.DateField()
    next_reset_at = serializers.DateTimeField()
    tasks = QuestTaskSerializer(many=True)


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


class StreakCollectionRequestSerializer(serializers.Serializer):
    run_start_date = serializers.DateField()
    milestone_days = serializers.IntegerField()


class StreakAwardSerializer(serializers.Serializer):
    id = serializers.IntegerField()
    kind = serializers.CharField()
    run_start_date = serializers.DateField()
    milestone_days = serializers.IntegerField()
    points = serializers.IntegerField(source="point_entry.amount")
    awarded_at = serializers.DateTimeField()


class StreakCollectionSerializer(serializers.Serializer):
    award = StreakAwardSerializer()
    balance = serializers.IntegerField()
    created = serializers.BooleanField()
