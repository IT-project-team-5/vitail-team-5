from rest_framework.response import Response
from rest_framework.views import APIView

from rewards.permissions import IsOwnerRole

from .serializers import BirthdayCollectionSerializer, LeaderboardQuerySerializer, LeaderboardSerializer, QuestDashboardSerializer
from .services import BirthdayClaimError, collect_birthday, leaderboard, quest_dashboard


class QuestDashboardView(APIView):
    permission_classes = [IsOwnerRole]

    def get(self, request):
        return Response(QuestDashboardSerializer(quest_dashboard(owner=request.user, request=request)).data)


class LeaderboardView(APIView):
    permission_classes = [IsOwnerRole]

    def get(self, request):
        query = LeaderboardQuerySerializer(data=request.query_params)
        query.is_valid(raise_exception=True)
        return Response(LeaderboardSerializer(leaderboard(
            owner=request.user, request=request, period=query.validated_data["period"],
        )).data)


class BirthdayCollectionView(APIView):
    permission_classes = [IsOwnerRole]

    def post(self, request, dog_id):
        try:
            result = collect_birthday(owner=request.user, dog_id=dog_id)
        except BirthdayClaimError as exc:
            return Response({"code": exc.code, "message": exc.message}, status=exc.status_code)
        return Response(BirthdayCollectionSerializer(result).data, status=201 if result["created"] else 200)
