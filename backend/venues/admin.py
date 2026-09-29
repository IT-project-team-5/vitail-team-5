from django.contrib import admin

from .models import CheckIn, Venue


@admin.register(Venue)
class VenueAdmin(admin.ModelAdmin):
    list_display = ("name", "venue_type", "checkin_radius_m", "required_dwell_s", "is_active")
    list_filter = ("venue_type", "is_active")
    search_fields = ("name", "address")

    def has_delete_permission(self, request, obj=None):
        return False  # Deactivate instead; check-ins keep protected references.


@admin.register(CheckIn)
class CheckInAdmin(admin.ModelAdmin):
    list_display = ("owner", "venue", "status", "awarded_points", "entered_at")
    list_filter = ("status", "venue")
    search_fields = ("owner__email", "venue__name")
    readonly_fields = [field.name for field in CheckIn._meta.fields]

    def has_add_permission(self, request):
        return False

    def has_delete_permission(self, request, obj=None):
        return False
