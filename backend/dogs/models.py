from django.conf import settings
from django.core.validators import MinValueValidator
from django.db import models


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
    breed = models.ForeignKey(Breed, on_delete=models.PROTECT, related_name="dogs")
    age_months = models.PositiveIntegerField(validators=[MinValueValidator(0)])
    size = models.CharField(max_length=10, choices=Size.choices)
    is_brachycephalic = models.BooleanField()
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ("created_at", "id")

    def __str__(self):
        return self.name
