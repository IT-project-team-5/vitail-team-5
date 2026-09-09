from rest_framework.permissions import BasePermission


class IsOwnerRole(BasePermission):
    message = "Only dog owner accounts can access this."

    def has_permission(self, request, view):
        return bool(request.user.is_authenticated and request.user.role == "OWNER")


class IsCafeRole(BasePermission):
    message = "Only café accounts can access this."

    def has_permission(self, request, view):
        return bool(request.user.is_authenticated and request.user.role == "CAFE")
