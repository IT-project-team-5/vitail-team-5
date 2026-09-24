from django.conf import settings
from django.core.exceptions import ValidationError
from django.db import models


class Venue(models.Model):
    class Kind(models.TextChoices):
        CAFE = "CAFE", "Café"
        RESTAURANT = "RESTAURANT", "Restaurant"
        PARK = "PARK", "Park"
        VET = "VET", "Vet"

    manager_user = models.OneToOneField(settings.AUTH_USER_MODEL, null=True, blank=True,
        on_delete=models.SET_NULL, related_name="managed_venue")
    kind = models.CharField(max_length=16, choices=Kind.choices, default=Kind.CAFE)
    name = models.CharField(max_length=100)
    description = models.TextField(max_length=2000, blank=True)
    photo = models.FileField(upload_to="avatars/venues/", max_length=255, blank=True)
    address = models.CharField(max_length=255, blank=True)
    latitude = models.DecimalField(max_digits=9, decimal_places=6, null=True, blank=True)
    longitude = models.DecimalField(max_digits=9, decimal_places=6, null=True, blank=True)
    opening_hours = models.CharField(max_length=500, blank=True)
    google_maps_url = models.URLField(max_length=2048, blank=True)
    is_partner = models.BooleanField(default=False)
    is_active = models.BooleanField(default=True)
    checkin_enabled = models.BooleanField(default=False)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ("name", "id")
        indexes = [models.Index(fields=("is_active", "kind"), name="venue_active_kind_idx"),
                   models.Index(fields=("latitude", "longitude"), name="venue_coordinates_idx")]
        constraints = [
            models.CheckConstraint(condition=(models.Q(latitude__isnull=True, longitude__isnull=True)
                | models.Q(latitude__isnull=False, longitude__isnull=False)), name="venue_coordinates_paired"),
            models.CheckConstraint(condition=models.Q(latitude__isnull=True) | models.Q(latitude__gte=-90, latitude__lte=90), name="venue_latitude_range"),
            models.CheckConstraint(condition=models.Q(longitude__isnull=True) | models.Q(longitude__gte=-180, longitude__lte=180), name="venue_longitude_range"),
            models.CheckConstraint(condition=models.Q(checkin_enabled=False) | models.Q(latitude__isnull=False, longitude__isnull=False), name="venue_checkin_coordinates"),
        ]

    def clean(self):
        super().clean()
        if self.manager_user_id and (self.manager_user.role != "CAFE" or not self.manager_user.is_active):
            raise ValidationError({"manager_user": "Choose an active café account."})

    def __str__(self):
        return self.name
