from django import forms
from django.contrib.auth.forms import UserChangeForm, UserCreationForm

from .models import User


class AdminUserCreationForm(UserCreationForm):
    class Meta(UserCreationForm.Meta):
        model = User
        fields = ("email", "display_name", "role")


class AdminUserChangeForm(UserChangeForm):
    class Meta:
        model = User
        fields = "__all__"

    def clean_role(self):
        role = self.cleaned_data["role"]
        if self.instance.pk and role != self.instance.role:
            # Existing balances/orders must keep their owner and café meaning.
            # Create a separate account instead of stranding that history.
            relations = ("dogs", "point_entries", "redemptions", "cafe_redemptions", "rewards", "walks")
            if any(
                getattr(self.instance, name, None) is not None
                and getattr(self.instance, name).exists()
                for name in relations
            ):
                raise forms.ValidationError(
                    "This account has role-specific records. Create a separate account for the other role."
                )
        return role
