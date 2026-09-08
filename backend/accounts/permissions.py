from rest_framework.permissions import BasePermission

from .models import User


class IsOwnerRole(BasePermission):
    """Restricts a view to authenticated dog-owner accounts.

    Café and admin accounts authenticate through the same JWT scheme as
    owners, so without this check a café login could hit owner-only
    endpoints such as the wallet or redemption APIs and spend a dog
    owner's points on their behalf.
    """

    message = "Only dog owner accounts can access this."

    def has_permission(self, request, view):
        return bool(
            request.user
            and request.user.is_authenticated
            and request.user.role == User.Role.OWNER
        )
