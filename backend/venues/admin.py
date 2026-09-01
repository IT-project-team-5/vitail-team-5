from django.contrib import admin

from .models import Venue, VenueOffer


class VenueOfferInline(admin.TabularInline):
    model = VenueOffer
    extra = 1


@admin.register(Venue)
class VenueAdmin(admin.ModelAdmin):
    list_display = ("name", "venue_type", "is_active", "account")
    list_filter = ("venue_type", "is_active")
    search_fields = ("name",)
    autocomplete_fields = ("account",)
    inlines = [VenueOfferInline]


@admin.register(VenueOffer)
class VenueOfferAdmin(admin.ModelAdmin):
    list_display = ("name", "venue", "point_price", "is_available")
    list_filter = ("is_available", "venue")
    search_fields = ("name", "venue__name")
