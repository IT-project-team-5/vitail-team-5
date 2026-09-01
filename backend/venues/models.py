from django.conf import settings
from django.db import models

from accounts.models import User


class Venue(models.Model):
    """A partner location an owner can check into or redeem points at.

    Created and edited by Vitail admins only (TECH_STACK.md, section 6).
    `account` is the CAFE-role account that signs in for this venue on the
    café order screen; it stays null for venues with no staff login, such as
    dog parks.
    """

    class VenueType(models.TextChoices):
        VET = "VET", "Vet"
        DOG_PARK = "DOG_PARK", "Dog park"
        CAFE = "CAFE", "Café"
        RESTAURANT = "RESTAURANT", "Restaurant"
        OTHER = "OTHER", "Other"

    name = models.CharField(max_length=150)
    venue_type = models.CharField(max_length=20, choices=VenueType.choices)
    description = models.TextField(blank=True)
    address = models.CharField(max_length=255, blank=True)
    latitude = models.DecimalField(max_digits=9, decimal_places=6)
    longitude = models.DecimalField(max_digits=9, decimal_places=6)
    checkin_radius_m = models.PositiveIntegerField(
        default=50, help_text="Used by venue check-ins, not by redemption."
    )
    required_dwell_s = models.PositiveIntegerField(
        default=0, help_text="Used by venue check-ins, not by redemption."
    )
    opening_hours = models.CharField(max_length=255, blank=True)
    photo = models.URLField(blank=True)
    is_active = models.BooleanField(default=True)
    account = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        related_name="staffed_venues",
        limit_choices_to={"role": User.Role.CAFE},
        help_text="The CAFE account that signs in for this venue, if any.",
    )
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["name"]

    def __str__(self):
        return self.name


class VenueOffer(models.Model):
    """A redeemable item a venue sells for points."""

    venue = models.ForeignKey(Venue, on_delete=models.CASCADE, related_name="offers")
    name = models.CharField(max_length=150)
    description = models.TextField(blank=True)
    photo = models.URLField(blank=True)
    point_price = models.PositiveIntegerField()
    is_available = models.BooleanField(default=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["name"]

    def __str__(self):
        return f"{self.name} ({self.venue.name})"
