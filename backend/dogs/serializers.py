from django.db import transaction
from rest_framework import serializers

from .models import Breed, Dog


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
            "size",
            "is_brachycephalic",
            "created_at",
        )
        read_only_fields = ("id", "breed", "created_at")
        extra_kwargs = {
            "name": {"allow_blank": False},
            "photo": {"required": False, "allow_null": True, "allow_blank": True},
            "age_months": {"min_value": 0},
        }

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
