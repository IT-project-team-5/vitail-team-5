from django.db import transaction
from django.shortcuts import get_object_or_404
from rest_framework import serializers
from rest_framework.response import Response
from rest_framework.views import APIView

from rewards.permissions import IsCafeRole
from venues.models import Venue
from venues.services import venue_for
from .photos import ImageUploadSerializer, PhotoJSONParser, photo_url, replace_photo
from .venues import google_maps_url, validate_google_maps_url


class CafeProfileSerializer(serializers.ModelSerializer):
    name = serializers.CharField(max_length=100, required=False)
    email = serializers.EmailField(source="manager_user.email", read_only=True)
    venue_id = serializers.IntegerField(source="id", read_only=True)
    photo = serializers.SerializerMethodField()
    maps_link = serializers.SerializerMethodField()

    class Meta:
        model = Venue
        fields = ("venue_id", "name", "email", "address", "description", "opening_hours", "photo", "google_maps_url", "maps_link")

    def get_photo(self, venue):
        return photo_url(venue.photo, self.context.get("request"))

    def get_maps_link(self, venue):
        return google_maps_url(venue)

    def validate_google_maps_url(self, value):
        return validate_google_maps_url(value)

    def validate_name(self, value):
        value = value.strip()
        if not value:
            raise serializers.ValidationError("Café name cannot be blank.")
        return value

    @transaction.atomic
    def update(self, instance, validated_data):
        user = self.context["request"].user
        venue = get_object_or_404(Venue.objects.select_for_update(), pk=instance.pk, manager_user=user)
        return super().update(venue, validated_data)


class CafeProfileView(APIView):
    permission_classes = [IsCafeRole]

    def profile(self, request):
        return venue_for(request.user)

    def get(self, request):
        return Response(CafeProfileSerializer(self.profile(request), context={"request": request}).data)

    def patch(self, request):
        serializer = CafeProfileSerializer(self.profile(request), data=request.data, partial=True, context={"request": request})
        serializer.is_valid(raise_exception=True)
        return Response(CafeProfileSerializer(serializer.save(), context={"request": request}).data)


class CafePhotoView(CafeProfileView):
    parser_classes = [PhotoJSONParser]
    http_method_names = ["post", "options"]

    def post(self, request):
        serializer = ImageUploadSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        with transaction.atomic():
            venue = self.profile(request)
            venue = get_object_or_404(Venue.objects.select_for_update(), pk=venue.pk, manager_user=request.user)
            replace_photo(venue, "photo", serializer.validated_data["image_base64"])
        return Response(CafeProfileSerializer(venue, context={"request": request}).data)
