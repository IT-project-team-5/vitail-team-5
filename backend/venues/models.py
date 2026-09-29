from django.conf import settings
from django.core.exceptions import ValidationError
from django.core.validators import MaxValueValidator, MinValueValidator
from django.db import models


class Venue(models.Model):
    """Partner place an owner can check in at. Created and edited in Admin only."""

    class VenueType(models.TextChoices):
        VET = "VET", "Vet"
        DOG_PARK = "DOG_PARK", "Dog park"
        CAFE = "CAFE", "Café"
        RESTAURANT = "RESTAURANT", "Restaurant"
        OTHER = "OTHER", "Other"

    # README "Check-in Dwell Times". OTHER has no agreed dwell, so Admin must set one.
    DEFAULT_DWELL_SECONDS = {
        VenueType.VET: 3 * 60,
        VenueType.DOG_PARK: 5 * 60,
        VenueType.CAFE: 10 * 60,
        VenueType.RESTAURANT: 20 * 60,
    }

    name = models.CharField(max_length=100)
    venue_type = models.CharField(max_length=12, choices=VenueType.choices)
    description = models.TextField(max_length=2000, blank=True)
    address = models.CharField(max_length=255, blank=True)
    opening_hours = models.CharField(max_length=500, blank=True)
    latitude = models.FloatField(validators=[MinValueValidator(-90), MaxValueValidator(90)])
    longitude = models.FloatField(validators=[MinValueValidator(-180), MaxValueValidator(180)])
    checkin_radius_m = models.PositiveSmallIntegerField(
        default=100, validators=[MinValueValidator(30), MaxValueValidator(1000)],
        help_text="Metres from the venue coordinate. Must exceed the 30 m GPS accuracy floor.",
    )
    required_dwell_s = models.PositiveIntegerField(
        null=True, blank=True, validators=[MinValueValidator(60)],
        help_text="Leave blank to use the default for the venue type (not available for Other).",
    )
    is_active = models.BooleanField(default=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ("name", "id")

    @property
    def dwell_seconds(self):
        return self.required_dwell_s or self.DEFAULT_DWELL_SECONDS[self.venue_type]

    def clean(self):
        super().clean()
        if not self.required_dwell_s and self.venue_type not in self.DEFAULT_DWELL_SECONDS:
            raise ValidationError({"required_dwell_s": "Set a dwell time for this venue type."})

    def __str__(self):
        return self.name


class CheckIn(models.Model):
    class Status(models.TextChoices):
        IN_PROGRESS = "IN_PROGRESS", "In progress"
        COMPLETED = "COMPLETED", "Completed"
        ABANDONED = "ABANDONED", "Abandoned"

    class Reason(models.TextChoices):
        LEFT_RADIUS = "LEFT_RADIUS", "Left the venue radius"
        SIGNAL_LOST = "SIGNAL_LOST", "Location reports stopped"
        SIMULATED = "SIMULATED", "Simulated location"
        CANCELLED = "CANCELLED", "Cancelled by the owner"
        REPLACED = "REPLACED", "Replaced by a newer check-in"

    owner = models.ForeignKey(
        settings.AUTH_USER_MODEL, on_delete=models.PROTECT, related_name="check_ins"
    )
    venue = models.ForeignKey(Venue, on_delete=models.PROTECT, related_name="check_ins")
    status = models.CharField(max_length=12, choices=Status.choices, default=Status.IN_PROGRESS)
    abandon_reason = models.CharField(max_length=12, choices=Reason.choices, blank=True)
    entered_at = models.DateTimeField()
    last_report_at = models.DateTimeField()
    dwell_completed_at = models.DateTimeField(null=True, blank=True)
    awarded_points = models.PositiveSmallIntegerField(default=0)
    completed_local_date = models.DateField(null=True, blank=True)

    class Meta:
        ordering = ("-entered_at", "-id")
        constraints = [
            # NULLs never collide, so abandoned/in-progress retries are unrestricted
            # while only one completed check-in exists per venue and local day.
            models.UniqueConstraint(
                fields=("owner", "venue", "completed_local_date"),
                name="checkin_owner_venue_date_unique",
            ),
            models.CheckConstraint(
                condition=models.Q(status="COMPLETED", completed_local_date__isnull=False,
                                   dwell_completed_at__isnull=False)
                | (~models.Q(status="COMPLETED") & models.Q(completed_local_date__isnull=True)),
                name="checkin_completed_fields_match_status",
            ),
            models.CheckConstraint(
                condition=models.Q(awarded_points__lte=12), name="checkin_points_at_most_12"
            ),
        ]

    def __str__(self):
        return f"{self.owner} at {self.venue}: {self.status}"
