from django import forms
from django.contrib import admin

from .models import Breed, Dog, DogDailyGoal, DogGoalTarget
from .goals import configure_target


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


class GoalTargetForm(forms.ModelForm):
    class Meta:
        model = DogGoalTarget
        fields = ("dog", "effective_from", "target_active_seconds")

    def clean(self):
        data = super().clean()
        if data.get("dog"):
            self.instance.owner = data["dog"].owner
            self.instance.dog_id_snapshot = data["dog"].pk
        return data


@admin.register(DogGoalTarget)
class GoalTargetAdmin(admin.ModelAdmin):
    form = GoalTargetForm
    list_display = ("dog", "owner", "effective_from", "target_active_seconds")

    def has_change_permission(self, request, obj=None):
        return False

    def has_delete_permission(self, request, obj=None):
        return False

    def save_model(self, request, obj, form, change):
        saved = configure_target(dog=obj.dog, target_active_seconds=obj.target_active_seconds,
            effective_from=obj.effective_from)
        obj.pk = saved.pk
        obj._state = saved._state


@admin.register(DogDailyGoal)
class DailyGoalAdmin(admin.ModelAdmin):
    list_display = ("dog", "local_date", "target_active_seconds", "final_active_seconds", "final_goal_met")

    def has_add_permission(self, request):
        return False

    def has_change_permission(self, request, obj=None):
        return False

    def has_delete_permission(self, request, obj=None):
        return False
