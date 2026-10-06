from django.db import transaction
from django.core.exceptions import ValidationError as ModelValidationError
from django.shortcuts import get_object_or_404

from accounts.photos import ImageUploadSerializer, PhotoJSONParser, replace_photo
from rest_framework import generics
from rest_framework.exceptions import ValidationError
from rest_framework.response import Response
from rest_framework.views import APIView

from .models import Breed, Dog
from .permissions import IsOwner
from .serializers import BreedSerializer, DogSerializer, GoalRequestSerializer
from .personalised_goals import owner_goal


class DogGoalView(APIView):
    permission_classes = [IsOwner]

    def get(self, request, pk):
        return self.respond(request, pk, save=False)

    def post(self, request, pk):
        return self.respond(request, pk, save=True)

    def respond(self, request, pk, *, save):
        dog = get_object_or_404(Dog, pk=pk, owner=request.user)
        serializer = GoalRequestSerializer(data=request.data if save else request.query_params)
        serializer.is_valid(raise_exception=True)
        if save and "effective_from" not in serializer.validated_data:
            raise ValidationError({"effective_from": "Choose the previewed effective date."})
        try:
            data = owner_goal(dog=dog, owner=request.user, save=save, **serializer.validated_data)
        except ModelValidationError as error:
            raise ValidationError(error.message_dict if hasattr(error, "message_dict") else error.messages)
        return Response(data, status=201 if save else 200)


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

    @transaction.atomic
    def perform_destroy(self, instance):
        owner = self.request.user
        type(owner).objects.select_for_update().get(pk=owner.pk)
        dog = get_object_or_404(Dog.objects.select_for_update(), pk=instance.pk, owner=owner)
        dog.delete()


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
