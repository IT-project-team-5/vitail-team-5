from decimal import Decimal
import hashlib
import json

from django.db import transaction
from django.shortcuts import get_object_or_404
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


class GoalRequestSerializer(serializers.Serializer):
    request_id = serializers.UUIDField(required=False)
    owner_adjustment = serializers.DecimalField(max_digits=3, decimal_places=2,
        min_value=Decimal("0.50"), max_value=Decimal("2.00"), default=Decimal("1.00"))
    effective_from = serializers.DateField(required=False)

    def validate(self, attrs):
        unknown = set(self.initial_data) - set(self.fields)
        if unknown:
            raise serializers.ValidationError({key: "Unexpected field." for key in sorted(unknown)})
        return attrs


class DogSerializer(serializers.ModelSerializer):
    request_id = serializers.UUIDField(required=False, write_only=True)
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
            "request_id",
            "photo",
            "breed",
            "breed_id",
            "age_months",
            "date_of_birth",
            "size",
            "weight_kg",
            "is_brachycephalic",
            "created_at",
        )
        read_only_fields = ("id", "breed", "created_at")
        extra_kwargs = {
            "name": {"allow_blank": False},
            "photo": {"required": False, "allow_null": True, "allow_blank": True},
            "age_months": {"min_value": 0, "required": False},
            "size": {"required": False},
        }

    def to_representation(self, instance):
        data = super().to_representation(instance)
        data["age_months"] = instance.current_age_months
        if instance.uploaded_photo:
            data["photo"] = photo_url(instance.uploaded_photo, self.context.get("request"))
        return data

    def validate(self, attrs):
        if self.instance is None and attrs.get("weight_kg") is None:
            raise serializers.ValidationError({"weight_kg": "Enter your dog's weight in kilograms."})
        if "weight_kg" in attrs and attrs["weight_kg"] is None and self.instance and self.instance.weight_kg is not None:
            raise serializers.ValidationError({"weight_kg": "Enter a positive weight in kilograms."})
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
        # Reuse the established breed size; weight only drives the existing goal formula.
        validated_data["size"] = breed.default_size
        request_id = validated_data.pop("request_id", None)
        fingerprint = hashlib.sha256(json.dumps({key: value for key, value in self.initial_data.items()
            if key in self.fields and key != "request_id"}, sort_keys=True, default=str).encode()).hexdigest()

        with transaction.atomic():
            type(owner).objects.select_for_update().get(pk=owner.pk)
            if request_id:
                previous = Dog.objects.filter(owner=owner, creation_request_id=request_id).first()
                if previous:
                    if previous.creation_fingerprint != fingerprint:
                        raise serializers.ValidationError({"request_id": "Retry the original details or start a new dog profile."})
                    return previous
            if Dog.objects.filter(owner=owner).count() >= 2:
                raise serializers.ValidationError(
                    {"detail": "An account can have at most two dogs."}
                )
            return Dog.objects.create(owner=owner, creation_request_id=request_id,
                creation_fingerprint=fingerprint, **validated_data)

    @transaction.atomic
    def update(self, instance, validated_data):
        owner = self.context["request"].user
        type(owner).objects.select_for_update().get(pk=owner.pk)
        # The initial API lookup can predate an Admin transfer. Never save its
        # stale owner field back over the current owner or goal ownership version.
        instance = get_object_or_404(Dog.objects.select_for_update(), pk=instance.pk, owner=owner)
        validated_data.pop("request_id", None)
        validated_data.pop("size", None)
        if "breed" in validated_data:
            validated_data["size"] = validated_data["breed"].default_size
        return super().update(instance, validated_data)
