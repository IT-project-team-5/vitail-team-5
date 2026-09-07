from django.conf import settings
from django.core.exceptions import ValidationError
from django.db import models, router, transaction


class Venue(models.Model):
    class VenueType(models.TextChoices):
        VET = "VET", "Vet"
        DOG_PARK = "DOG_PARK", "Dog park"
        CAFE = "CAFE", "Café"
        RESTAURANT = "RESTAURANT", "Restaurant"
        OTHER = "OTHER", "Other"

    name = models.CharField(max_length=150)
    venue_type = models.CharField(
        max_length=20,
        choices=VenueType.choices,
        default=VenueType.CAFE,
    )
    description = models.TextField(blank=True)
    address = models.CharField(max_length=255, blank=True)
    latitude = models.DecimalField(
        max_digits=9,
        decimal_places=6,
        null=True,
        blank=True,
    )
    longitude = models.DecimalField(
        max_digits=9,
        decimal_places=6,
        null=True,
        blank=True,
    )
    checkin_radius_m = models.PositiveIntegerField(default=100)
    required_dwell_s = models.PositiveIntegerField(default=600)
    opening_hours = models.JSONField(default=dict, blank=True)
    photo = models.URLField(blank=True)
    is_active = models.BooleanField(default=True)
    account = models.OneToOneField(
        settings.AUTH_USER_MODEL,
        related_name="managed_venue",
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        limit_choices_to={"role": "CAFE"},
    )
    order_feed_cursor = models.PositiveBigIntegerField(default=0, editable=False)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ("name", "id")

    def clean(self):
        super().clean()
        if self.account_id and self.account.role != "CAFE":
            raise ValidationError(
                {"account": "Only a café account can be attached to a venue."}
            )

    def __str__(self):
        return self.name


class VenueOffer(models.Model):
    venue = models.ForeignKey(
        Venue,
        related_name="offers",
        on_delete=models.CASCADE,
    )
    name = models.CharField(max_length=150)
    description = models.TextField(blank=True)
    photo = models.URLField(blank=True)
    point_price = models.PositiveIntegerField()
    is_available = models.BooleanField(default=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ("name", "id")
        constraints = [
            models.CheckConstraint(
                condition=models.Q(point_price__gt=0),
                name="venue_offer_point_price_positive",
            )
        ]

    def clean(self):
        super().clean()
        if not self.pk:
            return

        previous_venue_id = (
            type(self)
            .objects.filter(pk=self.pk)
            .values_list("venue_id", flat=True)
            .first()
        )
        if (
            previous_venue_id is not None
            and previous_venue_id != self.venue_id
            and self.redemption_order_items.exists()
        ):
            raise ValidationError(
                {
                    "venue": (
                        "An offer's venue cannot change after the offer appears "
                        "in an order."
                    )
                }
            )

    def save(self, *args, **kwargs):
        database = kwargs.get("using") or router.db_for_write(
            type(self),
            instance=self,
        )

        with transaction.atomic(using=database):
            if not self._state.adding and self.pk:
                previous_venue_id = (
                    type(self)
                    .objects.using(database)
                    .select_for_update()
                    .filter(pk=self.pk)
                    .values_list("venue_id", flat=True)
                    .first()
                )
                update_fields = kwargs.get("update_fields")
                venue_is_being_saved = update_fields is None or bool(
                    {"venue", "venue_id"}.intersection(update_fields)
                )
                if (
                    previous_venue_id is not None
                    and venue_is_being_saved
                    and previous_venue_id != self.venue_id
                    and self.redemption_order_items.using(database).exists()
                ):
                    raise ValidationError(
                        {
                            "venue": (
                                "An offer's venue cannot change after the offer "
                                "appears in an order."
                            )
                        }
                    )

            return super().save(*args, **kwargs)

    def __str__(self):
        return f"{self.venue}: {self.name}"
