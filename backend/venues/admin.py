from django.contrib import admin
from .models import Venue


@admin.register(Venue)
class VenueAdmin(admin.ModelAdmin):
    list_display = ("name", "kind", "manager_user", "is_partner", "is_active", "checkin_enabled")
    list_filter = ("kind", "is_partner", "is_active", "checkin_enabled")
    search_fields = ("name", "address", "manager_user__email")
    autocomplete_fields = ("manager_user",)
    readonly_fields = ("created_at", "updated_at")

    def formfield_for_foreignkey(self, db_field, request, **kwargs):
        if db_field.name == "manager_user":
            from accounts.models import User
            kwargs["queryset"] = User.objects.filter(role="CAFE", is_active=True)
        return super().formfield_for_foreignkey(db_field, request, **kwargs)
