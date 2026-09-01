from django.contrib import admin

from .models import PointLedger, PointLot


@admin.register(PointLot)
class PointLotAdmin(admin.ModelAdmin):
    """Points cannot be earned yet — walks and check-ins are not built.
    Until then, an admin can hand-grant a lot here (source = ADMIN_GRANT) to
    put test points on an account. Set amount_remaining equal to
    amount_earned unless you are deliberately seeding a partially-spent lot.
    """

    list_display = ("owner", "source", "amount_earned", "amount_remaining", "earned_at", "expires_at")
    list_filter = ("source",)
    search_fields = ("owner__email", "owner__display_name")
    autocomplete_fields = ("owner",)


@admin.register(PointLedger)
class PointLedgerAdmin(admin.ModelAdmin):
    list_display = ("owner", "amount", "entry_type", "created_at")
    list_filter = ("entry_type",)
    search_fields = ("owner__email",)
    readonly_fields = [f.name for f in PointLedger._meta.fields]

    def has_add_permission(self, request):
        return False

    def has_change_permission(self, request, obj=None):
        return False
