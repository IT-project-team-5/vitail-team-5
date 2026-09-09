from django.contrib import admin

from .models import Walk


@admin.register(Walk)
class WalkAdmin(admin.ModelAdmin):
    list_display = ("owner", "ended_at", "distance_m", "points_awarded", "point_date")
    list_filter = ("point_date",)
    search_fields = ("owner__email", "owner__display_name")
    readonly_fields = [field.name for field in Walk._meta.fields] + ["dogs"]

    def has_add_permission(self, request):
        return False

    def has_delete_permission(self, request, obj=None):
        return False
