from django import forms
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


class DogAdminForm(forms.ModelForm):
    age_months = forms.IntegerField(
        required=False, min_value=0, label="Recorded age (months)",
        help_text="Only needed for legacy profiles without a known birthday.",
    )

    class Meta:
        model = Dog
        fields = "__all__"

    def clean(self):
        cleaned = super().clean()
        if cleaned.get("date_of_birth") is not None:
            self.instance.date_of_birth = cleaned["date_of_birth"]
            cleaned["age_months"] = self.instance.current_age_months
        elif cleaned.get("age_months") is None:
            self.add_error("age_months", "Enter a birthday or the recorded age for this legacy profile.")
        return cleaned


@admin.register(Dog)
class DogAdmin(admin.ModelAdmin):
    form = DogAdminForm
    list_display = ("name", "owner", "breed", "date_of_birth", "current_age", "size", "created_at")
    list_filter = ("size", "breed", "is_brachycephalic")
    search_fields = ("name", "owner__email")

    @admin.display(description="Age (months)")
    def current_age(self, dog):
        return dog.current_age_months
