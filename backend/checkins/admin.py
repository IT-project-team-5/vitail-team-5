from django.contrib import admin

from .models import CheckIn


@admin.register(CheckIn)
class CheckInAdmin(admin.ModelAdmin):
    list_display = ("owner", "venue", "local_date", "category_slot", "verified_seconds", "status")
    list_filter = ("category_slot", "local_date")
    readonly_fields = tuple(field.name for field in CheckIn._meta.fields)

    def has_add_permission(self, request):
        return False

    def has_delete_permission(self, request, obj=None):
        return False
