from django.db import transaction
from rest_framework import serializers
from rest_framework.response import Response
from rest_framework.views import APIView

from rewards.permissions import IsCafeRole

from .models import CafeProfile, User
from .photos import ImageUploadSerializer, PhotoJSONParser, photo_url, replace_photo
from .venues import google_maps_url, validate_google_maps_url


class CafeProfileSerializer(serializers.ModelSerializer):
    name = serializers.CharField(source="user.display_name", max_length=100, required=False)
    email = serializers.EmailField(source="user.email", read_only=True)
    photo = serializers.SerializerMethodField()
    maps_link = serializers.SerializerMethodField()

    class Meta:
        model = CafeProfile
        fields = ("name", "email", "address", "description", "opening_hours", "photo", "google_maps_url", "maps_link")

    def get_photo(self, profile):
        return photo_url(profile.user.photo, self.context.get("request"))

    def get_maps_link(self, profile):
        return google_maps_url(profile.user, profile)

    def validate_google_maps_url(self, value):
        return validate_google_maps_url(value)

    def validate_name(self, value):
        value = value.strip()
        if not value:
            raise serializers.ValidationError("Café name cannot be blank.")
        return value

    @transaction.atomic
    def update(self, instance, validated_data):
        user = User.objects.select_for_update().get(pk=instance.user_id)
        profile = CafeProfile.objects.select_for_update().get(pk=instance.pk)
        user_data = validated_data.pop("user", {})
        if "display_name" in user_data:
            user.display_name = user_data["display_name"]
            user.save(update_fields=["display_name"])
        profile = super().update(profile, validated_data)
        profile.user = user
        return profile


class CafeProfileView(APIView):
    permission_classes = [IsCafeRole]

    def profile(self, request):
        profile, _ = CafeProfile.objects.get_or_create(user=request.user)
        profile.user = request.user
        return profile

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
            user = User.objects.select_for_update().get(pk=request.user.pk)
            replace_photo(user, "photo", serializer.validated_data["image_base64"])
            profile, _ = CafeProfile.objects.get_or_create(user=user)
            profile.user = user
        return Response(CafeProfileSerializer(profile, context={"request": request}).data)
