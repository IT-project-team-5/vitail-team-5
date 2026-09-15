from django.contrib.auth import authenticate, password_validation
from django.core.exceptions import ValidationError as DjangoValidationError
from django.db import IntegrityError, connection, transaction
from rest_framework import serializers
from rest_framework.exceptions import AuthenticationFailed
from rest_framework_simplejwt.tokens import RefreshToken

from .models import User


class UserSerializer(serializers.ModelSerializer):
    class Meta:
        model = User
        fields = ("id", "email", "display_name", "role")
        read_only_fields = fields


class UserProfileUpdateSerializer(serializers.ModelSerializer):
    display_name = serializers.CharField(max_length=100, allow_blank=False)

    class Meta:
        model = User
        fields = ("display_name",)

    def validate_display_name(self, value):
        value = value.strip()
        if not value:
            raise serializers.ValidationError("Display name cannot be blank.")
        return value


class RegisterSerializer(serializers.Serializer):
    email = serializers.EmailField(max_length=254)
    password = serializers.CharField(
        write_only=True, min_length=8, max_length=128, trim_whitespace=False
    )
    display_name = serializers.CharField(max_length=100, allow_blank=False)

    def validate_email(self, value):
        email = value.strip().lower()
        if User.objects.filter(email__iexact=email).exists():
            raise serializers.ValidationError("An account with this email already exists.")
        return email

    def validate_display_name(self, value):
        value = value.strip()
        if not value:
            raise serializers.ValidationError("Display name cannot be blank.")
        return value

    def validate_password(self, value):
        try:
            password_validation.validate_password(value)
        except DjangoValidationError as exc:
            raise serializers.ValidationError(exc.messages) from exc
        return value

    def create(self, validated_data):
        try:
            with transaction.atomic():
                return User.objects.create_user(**validated_data, role=User.Role.OWNER)
        except IntegrityError as exc:
            # Catch outside atomic so the failed insert is rolled back first.
            duplicate_email = (
                connection.vendor == "mysql"
                and len(exc.args) == 2
                and exc.args[0] == 1062
                and exc.args[1].endswith(
                    ("for key 'email'", "for key 'accounts_user.email'")
                )
            ) or (
                connection.vendor == "sqlite"
                and exc.args == ("UNIQUE constraint failed: accounts_user.email",)
            )
            if not duplicate_email:
                raise
            raise serializers.ValidationError(
                {"email": ["An account with this email already exists."]}
            ) from exc


class LoginSerializer(serializers.Serializer):
    email = serializers.EmailField(max_length=254)
    password = serializers.CharField(write_only=True, trim_whitespace=False)

    def validate(self, attrs):
        email = attrs["email"].strip().lower()
        user = authenticate(
            request=self.context.get("request"),
            username=email,
            password=attrs["password"],
        )
        if user is None or not user.is_active:
            raise AuthenticationFailed("Invalid email or password.")
        attrs["user"] = user
        return attrs


def token_response(user: User) -> dict:
    refresh = RefreshToken.for_user(user)
    return {
        "access": str(refresh.access_token),
        "refresh": str(refresh),
        "user": UserSerializer(user).data,
    }
