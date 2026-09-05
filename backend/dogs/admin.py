from django.contrib import admin

from .models import Breed, Dog


@admin.register(Breed)
class BreedAdmin(admin.ModelAdmin):
    list_display = (
        "name",
        "energy_level",
        "default_size",
        "is_brachycephalic",
    )
    list_filter = ("energy_level", "default_size", "is_brachycephalic")
    search_fields = ("name",)


@admin.register(Dog)
class DogAdmin(admin.ModelAdmin):
    list_display = ("name", "owner", "breed", "age_months", "size", "created_at")
    list_filter = ("size", "breed", "is_brachycephalic")
    search_fields = ("name", "owner__email")
