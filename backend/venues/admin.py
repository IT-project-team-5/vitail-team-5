from django.contrib import admin

from .models import Venue, VenueOffer


class VenueOfferInline(admin.TabularInline):
    model = VenueOffer
    extra = 0


@admin.register(Venue)
class VenueAdmin(admin.ModelAdmin):
    list_display = ("name", "venue_type", "account", "is_active")
    list_filter = ("venue_type", "is_active")
    search_fields = ("name", "address", "account__email")
    autocomplete_fields = ("account",)
    inlines = (VenueOfferInline,)


@admin.register(VenueOffer)
class VenueOfferAdmin(admin.ModelAdmin):
    list_display = ("name", "venue", "point_price", "is_available")
    list_filter = ("is_available", "venue__venue_type")
    search_fields = ("name", "venue__name")
    autocomplete_fields = ("venue",)
