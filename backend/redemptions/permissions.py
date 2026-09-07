from rest_framework.permissions import BasePermission

from accounts.models import User


class IsCafeUser(BasePermission):
    message = "Only café accounts can view the café order feed."

    def has_permission(self, request, view):
        return request.user.role == User.Role.CAFE
