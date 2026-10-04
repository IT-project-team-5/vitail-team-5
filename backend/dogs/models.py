import calendar

from django.conf import settings
from django.core.exceptions import ValidationError
from django.core.validators import MinValueValidator
from django.db import models
from django.utils import timezone


def validate_birth_date(value):
    if value > timezone.localdate():
        raise ValidationError("Birthday cannot be in the future.")


def age_in_months(date_of_birth, on_date):
    """Completed calendar months; missing anniversary days use month end.

    This is age calculation only, not a birthday-reward eligibility rule.
    """
    months = (on_date.year - date_of_birth.year) * 12 + on_date.month - date_of_birth.month
    anniversary_day = min(date_of_birth.day, calendar.monthrange(on_date.year, on_date.month)[1])
    return max(0, months - (on_date.day < anniversary_day))


class Breed(models.Model):
    class EnergyLevel(models.TextChoices):
        LOW = "LOW", "Low"
        MODERATE = "MODERATE", "Moderate"
        HIGH = "HIGH", "High"

    class Size(models.TextChoices):
        SMALL = "SMALL", "Small"
        MEDIUM = "MEDIUM", "Medium"
        LARGE = "LARGE", "Large"

    name = models.CharField(max_length=100, unique=True)
    energy_level = models.CharField(max_length=10, choices=EnergyLevel.choices)
    default_size = models.CharField(max_length=10, choices=Size.choices)
    is_brachycephalic = models.BooleanField(default=False)

    class Meta:
        ordering = ("name",)

    def __str__(self):
        return self.name


class Dog(models.Model):
    class Size(models.TextChoices):
        SMALL = "SMALL", "Small"
        MEDIUM = "MEDIUM", "Medium"
        LARGE = "LARGE", "Large"

    owner = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.CASCADE,
        related_name="dogs",
    )
    name = models.CharField(max_length=100)
    photo = models.URLField(blank=True, null=True)
    uploaded_photo = models.FileField(upload_to="avatars/dogs/", blank=True)
    breed = models.ForeignKey(Breed, on_delete=models.PROTECT, related_name="dogs")
    age_months = models.PositiveIntegerField(validators=[MinValueValidator(0)])
    date_of_birth = models.DateField(blank=True, null=True, validators=[validate_birth_date])
    microchip_number = models.CharField(max_length=100, null=True, blank=True)
    microchip_recorded_at = models.DateTimeField(null=True, blank=True)
    archived_at = models.DateTimeField(null=True, blank=True)
    size = models.CharField(max_length=10, choices=Size.choices)
    is_brachycephalic = models.BooleanField()
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ("created_at", "id")

    @property
    def current_age_months(self):
        if self.date_of_birth is None:
            return self.age_months
        return age_in_months(self.date_of_birth, timezone.localdate())

    def __str__(self):
        return self.name


class DogDailyGoal(models.Model):
    """Frozen daily target and result; no inferred personalised formula."""
    dog = models.ForeignKey(Dog, null=True, blank=True, on_delete=models.SET_NULL, related_name="daily_goals")
    dog_id_snapshot = models.BigIntegerField()
    owner = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.PROTECT, related_name="dog_daily_goals")
    local_date = models.DateField()
    target_active_seconds = models.PositiveIntegerField()
    inputs_snapshot = models.JSONField()
    rules_version = models.CharField(max_length=40)
    created_at = models.DateTimeField(auto_now_add=True)
    finalised_at = models.DateTimeField(null=True, blank=True)
    final_active_seconds = models.PositiveIntegerField(null=True, blank=True)
    final_goal_met = models.BooleanField(null=True, blank=True)

    class Meta:
        constraints = [
            models.UniqueConstraint(fields=("dog_id_snapshot", "local_date"), name="dog_goal_date_unique"),
            models.CheckConstraint(condition=models.Q(dog_id_snapshot__gt=0), name="dog_goal_identity_positive"),
            models.CheckConstraint(condition=models.Q(target_active_seconds__gt=0), name="dog_goal_target_positive"),
            models.CheckConstraint(
                condition=models.Q(finalised_at__isnull=True, final_active_seconds__isnull=True, final_goal_met__isnull=True)
                | (models.Q(finalised_at__isnull=False, final_active_seconds__isnull=False, final_goal_met__isnull=False)
                   & (models.Q(final_goal_met=True, final_active_seconds__gte=models.F("target_active_seconds"))
                      | models.Q(final_goal_met=False, final_active_seconds__lt=models.F("target_active_seconds")))),
                name="dog_goal_final_result_shape",
            ),
        ]
        indexes = [models.Index(fields=("owner", "local_date"), name="dog_goal_owner_date")]

    def clean(self):
        super().clean()
        if self.dog_id and self.dog_id_snapshot != self.dog_id:
            raise ValidationError({"dog_id_snapshot": "The snapshot must identify the same dog."})
        if self._state.adding and self.dog_id and self.owner_id != self.dog.owner_id:
            raise ValidationError({"owner": "The goal belongs to the dog's owner when created."})


class DogGoalTarget(models.Model):
    """Append-only, manually approved targets configured through existing Admin."""
    dog = models.ForeignKey(Dog, null=True, on_delete=models.SET_NULL, related_name="goal_targets")
    dog_id_snapshot = models.BigIntegerField(editable=False)
    owner = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.PROTECT)
    effective_from = models.DateField()
    target_active_seconds = models.PositiveIntegerField(null=True, blank=True,
        help_text="Approved daily walking seconds. Leave empty to pause goals; no default formula.")
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ("effective_from", "pk")
        constraints = [
            models.UniqueConstraint(fields=("dog_id_snapshot", "effective_from"), name="dog_target_effective_unique"),
            models.CheckConstraint(condition=models.Q(dog_id_snapshot__gt=0), name="dog_target_identity_positive"),
            models.CheckConstraint(condition=models.Q(target_active_seconds__isnull=True)
                | models.Q(target_active_seconds__gt=0), name="dog_target_positive"),
        ]

    def clean(self):
        from datetime import timedelta
        from rewards.policy import local_date
        super().clean()
        if not self._state.adding:
            raise ValidationError("Targets are immutable. Add a new effective-dated target.")
        if self.dog_id:
            if self.dog_id_snapshot != self.dog_id:
                raise ValidationError("The target must identify the same dog.")
            if self.owner_id != self.dog.owner_id:
                raise ValidationError("The target must belong to the dog's current owner.")
            earliest = local_date()
            if type(self).objects.filter(dog_id=self.dog_id).exists():
                earliest += timedelta(days=1)
            if self.effective_from and self.effective_from < earliest:
                raise ValidationError({"effective_from": f"Choose {earliest} or later to preserve today's target."})
