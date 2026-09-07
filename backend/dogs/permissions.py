from rest_framework.permissions import BasePermission

from accounts.models import User


class IsOwner(BasePermission):
    message = "Only dog owner accounts can manage dogs."

    def has_permission(self, request, view):
        return bool(
            request.user
            and request.user.is_authenticated
            and request.user.role == User.Role.OWNER
        )
