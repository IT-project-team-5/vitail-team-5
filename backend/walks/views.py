from rest_framework import status
from rest_framework.response import Response
from rest_framework.views import APIView

from rewards.permissions import IsOwnerRole

from .models import Walk
from .serializers import CreateWalkSerializer, WalkSerializer
from .services import WalkConflictError, create_walk


class WalkListCreateView(APIView):
    permission_classes = [IsOwnerRole]

    def get(self, request):
        walks = Walk.objects.filter(owner=request.user).prefetch_related("dogs")
        return Response(WalkSerializer(walks, many=True).data)

    def post(self, request):
        serializer = CreateWalkSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        try:
            walk = create_walk(owner=request.user, **serializer.validated_data)
        except WalkConflictError as exc:
            return Response({"code": "IDEMPOTENCY_CONFLICT", "message": str(exc)}, status=409)
        return Response(WalkSerializer(walk).data, status=status.HTTP_201_CREATED)
