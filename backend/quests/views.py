from django.conf import settings
from django.http import Http404
from rest_framework.response import Response
from rest_framework.views import APIView

from rewards.permissions import IsOwnerRole

from .serializers import BirthdayCollectionSerializer, QuestDashboardSerializer, StreakCollectionRequestSerializer, StreakCollectionSerializer
from .debug_reset import reset_quest_test_state
from .services import BirthdayClaimError, collect_birthday, quest_dashboard
from .streaks import StreakClaimError, collect_streak


class QuestDashboardView(APIView):
    permission_classes = [IsOwnerRole]

    def get(self, request):
        return Response(QuestDashboardSerializer(quest_dashboard(owner=request.user, request=request)).data)


class BirthdayCollectionView(APIView):
    permission_classes = [IsOwnerRole]

    def post(self, request, dog_id):
        try:
            result = collect_birthday(owner=request.user, dog_id=dog_id)
        except BirthdayClaimError as exc:
            return Response({"code": exc.code, "message": exc.message}, status=exc.status_code)
        return Response(BirthdayCollectionSerializer(result).data, status=201 if result["created"] else 200)


class StreakCollectionView(APIView):
    permission_classes = [IsOwnerRole]

    def post(self, request):
        serializer = StreakCollectionRequestSerializer(data=request.data)
        if not serializer.is_valid():
            return Response({"code": "INVALID_STREAK_REQUEST", "message": "Provide a run start date and an integer milestone."}, status=400)
        try:
            result = collect_streak(owner=request.user, **serializer.validated_data)
        except StreakClaimError as exc:
            return Response({"code": exc.code, "message": exc.message}, status=exc.status_code)
        return Response(StreakCollectionSerializer(result).data, status=201 if result["created"] else 200)


class QuestTestResetView(APIView):
    permission_classes = [IsOwnerRole]

    def post(self, request):
        if not (settings.DEBUG or getattr(settings, "TESTING", False)):
            raise Http404
        return Response(reset_quest_test_state(owner=request.user))
