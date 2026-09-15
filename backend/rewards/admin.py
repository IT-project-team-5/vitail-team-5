from django import forms
from django.contrib import admin, messages
from django.contrib.auth import get_user_model
from django.db import transaction
from django.utils import timezone

from .models import PointEntry, Redemption, Reward, default_point_expiry
from .services import cancel_redemption


class PointGrantForm(forms.ModelForm):
    """Admin only grants positive credits; spending/refunds use services."""

    amount = forms.IntegerField(min_value=1)

    class Meta:
        model = PointEntry
        fields = ("user", "amount", "expires_at")

    def clean_user(self):
        user = self.cleaned_data["user"]
        if user.role != user.Role.OWNER:
            raise forms.ValidationError("Only dog owners can receive points.")
        return user

    def clean_expires_at(self):
        expiry = self.cleaned_data.get("expires_at")
        if expiry is None or expiry <= timezone.now():
            raise forms.ValidationError("Choose an expiry in the future.")
        return expiry


@admin.register(PointEntry)
class PointEntryAdmin(admin.ModelAdmin):
    form = PointGrantForm
    list_display = ("user", "amount", "remaining_points", "type", "expires_at", "created_at")
    list_filter = ("type",)
    search_fields = ("user__email", "user__display_name", "source_reference")
    autocomplete_fields = ("user",)

    def get_fields(self, request, obj=None):
        if obj:
            return [field.name for field in PointEntry._meta.fields]
        return ("user", "amount", "expires_at")

    def get_readonly_fields(self, request, obj=None):
        return [field.name for field in PointEntry._meta.fields] if obj else ()

    def get_changeform_initial_data(self, request):
        return {"expires_at": default_point_expiry()}

    def save_model(self, request, obj, form, change):
        if change:
            return
        with transaction.atomic():
            get_user_model().objects.select_for_update().get(pk=obj.user_id)
            obj.type = PointEntry.Type.ADMIN
            obj.remaining_points = obj.amount
            obj.full_clean()
            super().save_model(request, obj, form, change)

    def has_delete_permission(self, request, obj=None):
        return False


@admin.register(Reward)
class RewardAdmin(admin.ModelAdmin):
    list_display = ("name", "cafe_user", "point_cost", "is_available")
    list_filter = ("is_available",)
    search_fields = ("name", "cafe_user__email", "cafe_user__display_name")
    autocomplete_fields = ("cafe_user",)


@admin.register(Redemption)
class RedemptionAdmin(admin.ModelAdmin):
    list_display = ("reference_number", "owner_user", "cafe_user", "reward_name_snapshot", "status", "point_cost_snapshot", "created_at")
    list_filter = ("status",)
    search_fields = ("reference_number", "owner_user__email", "cafe_user__email")
    readonly_fields = [field.name for field in Redemption._meta.fields]
    actions = ("cancel_and_refund",)

    def has_add_permission(self, request):
        return False

    def has_delete_permission(self, request, obj=None):
        return False

    @admin.action(description="Cancel pending orders and refund points", permissions=["change"])
    def cancel_and_refund(self, request, queryset):
        count = sum(cancel_redemption(redemption_id=pk) for pk in queryset.values_list("pk", flat=True))
        self.message_user(request, f"{count} pending order(s) refunded. Completed/refunded orders were unchanged.", messages.SUCCESS)
