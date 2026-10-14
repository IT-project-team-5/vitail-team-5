from collections.abc import Mapping
from uuid import UUID

from rest_framework import serializers
from rest_framework.exceptions import PermissionDenied, ValidationError
from rest_framework.permissions import BasePermission, IsAuthenticated
from rest_framework.response import Response
from rest_framework.views import APIView

from .shop import AvatarShopError, equip_product, purchase_product, shop_state


class IsActiveOwner(BasePermission):
    message = "Only active dog owner accounts can access the avatar shop."

    def has_permission(self, request, view):
        user = request.user
        return bool(user.is_authenticated and user.role == "OWNER" and user.is_active and not user.deleted_at)


class ShopRequestSerializer(serializers.Serializer):
    def to_internal_value(self, data):
        if not isinstance(data, Mapping) or set(data) - set(self.fields):
            raise ValidationError({"non_field_errors": ["Use only the documented avatar shop request fields."]})
        return super().to_internal_value(data)


class RequestUUIDField(serializers.UUIDField):
    def to_internal_value(self, data):
        if not isinstance(data, (str, UUID)):
            self.fail("invalid")
        return super().to_internal_value(data)


class PurchaseSerializer(ShopRequestSerializer):
    product_code = serializers.CharField(max_length=40)
    request_id = RequestUUIDField()


class OutfitSerializer(ShopRequestSerializer):
    category = serializers.CharField(max_length=20)
    product_code = serializers.CharField(max_length=40, allow_null=True)


class AvatarShopView(APIView):
    permission_classes = [IsAuthenticated, IsActiveOwner]

    def finalize_response(self, request, response, *args, **kwargs):
        response = super().finalize_response(request, response, *args, **kwargs)
        response["Cache-Control"] = "private, no-store"
        return response

    def handle_exception(self, exc):
        if isinstance(exc, AvatarShopError):
            return Response({"code": exc.code, "message": str(exc)}, status=exc.status)
        if isinstance(exc, ValidationError):
            return Response({"code": "INVALID_REQUEST", "message": "Provide the documented fields with a valid UUID for purchases.", "errors": exc.detail}, status=400)
        if isinstance(exc, PermissionDenied):
            return Response({"code": "OWNER_REQUIRED", "message": str(exc.detail)}, status=403)
        return super().handle_exception(exc)

    def get(self, request):
        return Response(shop_state(request.user))


class AvatarPurchaseView(AvatarShopView):
    def post(self, request):
        serializer = PurchaseSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        return Response(purchase_product(owner=request.user, **serializer.validated_data))

    def get(self, request):
        return self.http_method_not_allowed(request)


class AvatarOutfitView(AvatarShopView):
    def patch(self, request):
        serializer = OutfitSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        return Response(equip_product(owner=request.user, **serializer.validated_data))

    def get(self, request):
        return self.http_method_not_allowed(request)
