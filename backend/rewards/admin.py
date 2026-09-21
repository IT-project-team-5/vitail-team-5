from django import forms
from django.contrib import admin

from .models import PointEntry, Redemption, Reward, default_point_expiry


class PointEntryAdminForm(forms.ModelForm):
    """Manual entries created here are always positive admin grants.

    Spend, refund and expiry rows are debit-shaped (negative amount,
    remaining_points=0) and only make sense when they are paired with the
    matching change to a credit entry's remaining_points — that pairing is
    exactly what services.spend_points/expire_stale_redemptions do. A
    negative row created by hand here would satisfy PointEntry.clean()
    (it's a valid debit shape on its own) but would not actually decrement
    any credit entry, so the wallet balance would not move even though a
    debit now sits in the ledger. Restricting this form to positive grants
    closes that gap.
    """

    class Meta:
        model = PointEntry
        fields = "__all__"

    def clean_amount(self):
        amount = self.cleaned_data["amount"]
        if amount <= 0:
            raise forms.ValidationError(
                "Only positive admin grants can be created here. Spend, "
                "refund and expiry entries are created by the app itself."
            )
        return amount

    def clean_type(self):
        type_ = self.cleaned_data["type"]
        if type_ != PointEntry.Type.ADMIN:
            raise forms.ValidationError(
                "Manual entries must be type = Admin grant."
            )
        return type_


@admin.register(PointEntry)
class PointEntryAdmin(admin.ModelAdmin):
    """Points aren't earned automatically yet (no walk/check-in tracking),
    so an admin hand-grants a credit here: pick the user, a positive
    amount, and an expiry (defaults to 12 months out). Type is locked to
    Admin grant and the amount must be positive — see PointEntryAdminForm.
    Leave "remaining points" at 0 for a new grant — it is filled in to
    match the amount automatically on save. Existing rows are locked
    read-only: editing a past entry after the fact would desync the
    running balance, so corrections should be a new entry instead.
    """

    form = PointEntryAdminForm
    list_display = ("user", "amount", "remaining_points", "type", "expires_at", "created_at")
    list_filter = ("type",)
    search_fields = ("user__email", "user__display_name", "source_reference")
    autocomplete_fields = ("user",)

    def get_changeform_initial_data(self, request):
        return {"expires_at": default_point_expiry(), "type": PointEntry.Type.ADMIN}

    def get_form(self, request, obj=None, **kwargs):
        form = super().get_form(request, obj, **kwargs)
        if obj is None:
            # Only "Admin grant" is a valid manual entry; hide the other
            # types instead of just rejecting them on save.
            form.base_fields["type"].choices = [
                choice
                for choice in form.base_fields["type"].choices
                if choice[0] in ("", PointEntry.Type.ADMIN)
            ]
        return form

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
