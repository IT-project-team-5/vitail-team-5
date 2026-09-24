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
