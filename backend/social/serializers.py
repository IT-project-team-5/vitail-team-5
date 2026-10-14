import math

from rest_framework import serializers

from accounts.models import User

from .models import VIRTUAL_AVATAR_KEYS


class PublicIDSerializer(serializers.Serializer):
    public_id = serializers.RegexField(r"^[0-9a-f]{32}$", max_length=32)


class ResponseSerializer(serializers.Serializer):
    accept = serializers.BooleanField()


class PreferencesSerializer(serializers.Serializer):
    location_visibility = serializers.ChoiceField(choices=("OFF", "FRIENDS"), required=False)
    net_matching_enabled = serializers.BooleanField(required=False)
    virtual_avatar_key = serializers.ChoiceField(choices=VIRTUAL_AVATAR_KEYS, required=False)
    dog_avatar_breed = serializers.ChoiceField(choices=User.DogAvatarBreed.choices, required=False)
    bandana_color = serializers.ChoiceField(choices=User.BandanaColor.choices, required=False)
    public_dog_id = serializers.IntegerField(min_value=1, max_value=9_223_372_036_854_775_807, allow_null=True, required=False)


class StartSessionSerializer(serializers.Serializer):
    request_id = serializers.UUIDField()
    started_at = serializers.DateTimeField()


class SessionStateSerializer(serializers.Serializer):
    state = serializers.ChoiceField(choices=("RECORDING", "PAUSED", "FINISHED", "CANCELLED"))


class PresenceSerializer(serializers.Serializer):
    latitude = serializers.FloatField(min_value=-90, max_value=90)
    longitude = serializers.FloatField(min_value=-180, max_value=180)
    accuracy_m = serializers.FloatField(min_value=0, max_value=10000)
    recorded_at = serializers.DateTimeField()
    is_simulated = serializers.BooleanField(default=False)

    def validate(self, attrs):
        if not all(math.isfinite(attrs[key]) for key in ("latitude", "longitude", "accuracy_m")):
            raise serializers.ValidationError("Location values must be finite.")
        return attrs
