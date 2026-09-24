from django.db import transaction
from django.utils import timezone
from rest_framework import serializers

from accounts.photos import photo_url

from .models import Breed, Dog, age_in_months


class BreedSerializer(serializers.ModelSerializer):
    class Meta:
        model = Breed
        fields = (
            "id",
            "name",
            "energy_level",
            "default_size",
            "is_brachycephalic",
        )
        read_only_fields = fields


class DogSerializer(serializers.ModelSerializer):
    breed = BreedSerializer(read_only=True)
    breed_id = serializers.PrimaryKeyRelatedField(
        queryset=Breed.objects.all(),
        source="breed",
        write_only=True,
    )
    is_brachycephalic = serializers.BooleanField(required=False)

    class Meta:
        model = Dog
        fields = (
            "id",
            "name",
            "photo",
            "breed",
            "breed_id",
            "age_months",
            "date_of_birth",
            "size",
            "is_brachycephalic",
            "created_at",
        )
        read_only_fields = ("id", "breed", "created_at")
        extra_kwargs = {
            "name": {"allow_blank": False},
            "photo": {"required": False, "allow_null": True, "allow_blank": True},
            "age_months": {"min_value": 0, "required": False},
        }

    def to_representation(self, instance):
        data = super().to_representation(instance)
        data["age_months"] = instance.current_age_months
        if instance.uploaded_photo:
            data["photo"] = photo_url(instance.uploaded_photo, self.context.get("request"))
        return data

    def validate(self, attrs):
        birthday = attrs.get("date_of_birth", self.instance.date_of_birth if self.instance else None)
        if birthday is not None:
            # DOB is authoritative; stale age-only clients cannot overwrite it.
            attrs["age_months"] = age_in_months(birthday, timezone.localdate())
        elif self.instance is None and "age_months" not in attrs:
            raise serializers.ValidationError({"date_of_birth": ["Enter your dog's birthday."]})
        elif self.instance is not None and "date_of_birth" in attrs and "age_months" not in attrs:
            # An explicit clear preserves the last known age, never infers a DOB.
            attrs["age_months"] = self.instance.current_age_months
        return attrs

    def validate_name(self, value):
        value = value.strip()
        if not value:
            raise serializers.ValidationError("Dog name cannot be blank.")
        return value

    def create(self, validated_data):
        owner = self.context["request"].user
        breed = validated_data["breed"]
        validated_data.setdefault("is_brachycephalic", breed.is_brachycephalic)

        with transaction.atomic():
            type(owner).objects.select_for_update().get(pk=owner.pk)
            if Dog.objects.filter(owner=owner).count() >= 10:
                raise serializers.ValidationError(
                    {"detail": "An account can have at most 10 dogs."}
                )
            return Dog.objects.create(owner=owner, **validated_data)
