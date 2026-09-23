from django.db import transaction
from django.shortcuts import get_object_or_404

from accounts.photos import ImageUploadSerializer, PhotoJSONParser, replace_photo
from rest_framework import generics, status
from rest_framework.response import Response
from rest_framework.views import APIView

from .goals import DogGoalService
from .models import Breed, Dog
from .permissions import IsOwner
from .serializers import BreedSerializer, DogSerializer


class BreedListView(generics.ListAPIView):
    permission_classes = [IsOwner]
    queryset = Breed.objects.all()
    serializer_class = BreedSerializer


class DogListCreateView(generics.ListCreateAPIView):
    permission_classes = [IsOwner]
    serializer_class = DogSerializer

    def get_queryset(self):
        return Dog.objects.filter(owner=self.request.user).select_related("breed")


class DogDetailView(generics.RetrieveUpdateDestroyAPIView):
    permission_classes = [IsOwner]
    serializer_class = DogSerializer
    http_method_names = ["patch", "delete", "options"]

    def get_queryset(self):
        return Dog.objects.filter(owner=self.request.user).select_related("breed")


class DogGoalView(APIView):
    permission_classes = [IsOwner]
    service_class = DogGoalService

    def get(self, request, pk):
        dog = get_object_or_404(
            Dog.objects.select_related("breed"),
            pk=pk,
            owner=request.user,
        )
        return Response(
            {"dog_id": dog.id, **self.service_class().calculate(dog)},
            status=status.HTTP_200_OK,
        )


class DogPhotoView(APIView):
    parser_classes = [PhotoJSONParser]
    permission_classes = [IsOwner]

    def post(self, request, pk):
        # Check ownership before decoding a potentially large image.
        with transaction.atomic():
            dog = get_object_or_404(Dog.objects.select_for_update(), pk=pk, owner=request.user)
            serializer = ImageUploadSerializer(data=request.data)
            serializer.is_valid(raise_exception=True)
            replace_photo(dog, "uploaded_photo", serializer.validated_data["image_base64"])
        return Response(DogSerializer(dog, context={"request": request}).data)
