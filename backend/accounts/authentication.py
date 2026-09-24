from rest_framework.exceptions import AuthenticationFailed
from rest_framework_simplejwt.authentication import JWTAuthentication


class AccountJWTAuthentication(JWTAuthentication):
    """A version bump revokes all tokens, including tokens issued before this field existed."""

    def get_user(self, validated_token):
        user = super().get_user(validated_token)
        if user.deleted_at or validated_token.get("av", 1) != user.auth_version:
            raise AuthenticationFailed("This session has ended. Please sign in again.", code="session_revoked")
        return user
