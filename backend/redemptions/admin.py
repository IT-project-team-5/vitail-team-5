from django.contrib import admin

from .models import RedemptionOrder, RedemptionOrderItem


class RedemptionOrderItemInline(admin.TabularInline):
    model = RedemptionOrderItem
    extra = 0


@admin.register(RedemptionOrder)
class RedemptionOrderAdmin(admin.ModelAdmin):
    list_display = (
        "reference_number",
        "owner",
        "venue",
        "status",
        "total_points",
        "created_at",
    )
    list_filter = ("status", "venue")
    search_fields = (
        "reference_number",
        "owner__email",
        "owner__display_name",
        "venue__name",
    )
    autocomplete_fields = ("owner", "venue")
    readonly_fields = ("reference_number", "created_at", "updated_at")
    inlines = (RedemptionOrderItemInline,)


@admin.register(RedemptionOrderItem)
class RedemptionOrderItemAdmin(admin.ModelAdmin):
    list_display = (
        "item_name_snapshot",
        "order",
        "quantity",
        "point_price_snapshot",
    )
    search_fields = ("item_name_snapshot", "order__reference_number")
    autocomplete_fields = ("order", "venue_offer")
