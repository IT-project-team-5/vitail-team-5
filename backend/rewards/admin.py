from django.contrib import admin

from .models import PointEntry, Redemption, Reward, default_point_expiry


@admin.register(PointEntry)
class PointEntryAdmin(admin.ModelAdmin):
    """Points aren't earned automatically yet (no walk/check-in tracking),
    so an admin hand-grants a credit here: pick the user, a positive
    amount, type = Admin grant, and an expiry (defaults to 12 months out).
    Leave "remaining points" at 0 for a new grant — it is filled in to
    match the amount automatically on save. Existing rows are locked
    read-only: editing a past entry after the fact would desync the
    running balance, so corrections should be a new entry instead.
    """

    list_display = ("user", "amount", "remaining_points", "type", "expires_at", "created_at")
    list_filter = ("type",)
    search_fields = ("user__email", "user__display_name", "source_reference")
    autocomplete_fields = ("user",)

    def get_changeform_initial_data(self, request):
        return {"expires_at": default_point_expiry(), "type": PointEntry.Type.ADMIN}

    def save_model(self, request, obj, form, change):
        if not change and obj.amount and obj.amount > 0 and not obj.remaining_points:
            obj.remaining_points = obj.amount
        super().save_model(request, obj, form, change)

    def get_readonly_fields(self, request, obj=None):
        if obj is not None:
            return [f.name for f in self.model._meta.fields]
        return ()

    def has_delete_permission(self, request, obj=None):
        return False


@admin.register(Reward)
class RewardAdmin(admin.ModelAdmin):
    list_display = ("name", "cafe_user", "point_cost", "is_available", "created_at")
    list_filter = ("is_available",)
    search_fields = ("name", "cafe_user__email", "cafe_user__display_name")
    autocomplete_fields = ("cafe_user",)


@admin.register(Redemption)
class RedemptionAdmin(admin.ModelAdmin):
    """Read-only oversight. Redemptions are created and collected only
    through the API so the point ledger always stays in sync (see
    services.py).
    """

    list_display = (
        "reference_number",
        "owner_user",
        "reward_name_snapshot",
        "status",
        "point_cost_snapshot",
        "created_at",
    )
    list_filter = ("status",)
    search_fields = ("reference_number", "owner_user__email")
    readonly_fields = [f.name for f in Redemption._meta.fields]

    def has_add_permission(self, request):
        return False
