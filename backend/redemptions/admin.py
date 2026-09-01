from django.contrib import admin

from .models import RedemptionOrder, RedemptionOrderItem


class RedemptionOrderItemInline(admin.TabularInline):
    model = RedemptionOrderItem
    extra = 0
    readonly_fields = ("venue_offer", "item_name_snapshot", "point_price_snapshot", "quantity")
    can_delete = False

    def has_add_permission(self, request, obj=None):
        return False


@admin.register(RedemptionOrder)
class RedemptionOrderAdmin(admin.ModelAdmin):
    """Read-only oversight. Orders are created and collected only through
    the API so wallet deduction always stays in sync (see services.py).
    """

    list_display = ("reference_number", "owner", "venue", "status", "total_points", "created_at")
    list_filter = ("status", "venue")
    search_fields = ("reference_number", "owner__email")
    inlines = [RedemptionOrderItemInline]
    readonly_fields = [f.name for f in RedemptionOrder._meta.fields]

    def has_add_permission(self, request):
        return False
