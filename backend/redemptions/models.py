import secrets
from datetime import datetime, time, timedelta

from django.conf import settings
from django.core.exceptions import ValidationError
from django.db import models, router, transaction
from django.utils import timezone

from venues.models import Venue, VenueOffer


def generate_reference_number():
    return f"RDM-{secrets.token_hex(6).upper()}"


def next_local_midnight():
    current_timezone = timezone.get_current_timezone()
    local_now = timezone.localtime(timezone.now(), current_timezone)
    midnight = datetime.combine(local_now.date() + timedelta(days=1), time.min)
    return timezone.make_aware(midnight, current_timezone)


class RedemptionOrder(models.Model):
    class Status(models.TextChoices):
        PENDING = "PENDING", "Pending"
        COLLECTED = "COLLECTED", "Collected"
        EXPIRED = "EXPIRED", "Expired"
        CANCELLED = "CANCELLED", "Cancelled"

    owner = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        related_name="redemption_orders",
        on_delete=models.PROTECT,
        limit_choices_to={"role": "OWNER"},
    )
    owner_name_snapshot = models.CharField(
        max_length=100,
        blank=True,
        editable=False,
    )
    venue = models.ForeignKey(
        Venue,
        related_name="redemption_orders",
        on_delete=models.PROTECT,
    )
    reference_number = models.CharField(
        max_length=16,
        unique=True,
        default=generate_reference_number,
        editable=False,
    )
    status = models.CharField(
        max_length=10,
        choices=Status.choices,
        default=Status.PENDING,
    )
    total_points = models.PositiveIntegerField()
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)
    collected_at = models.DateTimeField(null=True, blank=True)
    expires_at = models.DateTimeField(default=next_local_midnight)

    class Meta:
        ordering = ("-created_at", "-id")
        indexes = [
            models.Index(
                fields=("venue", "status", "created_at"),
                name="redemption_venue_feed_idx",
            )
        ]
        constraints = [
            models.CheckConstraint(
                condition=models.Q(total_points__gt=0),
                name="redemption_total_points_positive",
            )
        ]

    def clean(self):
        super().clean()
        if self.owner_id and self.owner.role != "OWNER":
            raise ValidationError(
                {"owner": "Only a dog owner account can place a redemption order."}
            )

        if self.status == self.Status.COLLECTED and self.collected_at is None:
            raise ValidationError(
                {"collected_at": "A collected order needs a collection time."}
            )
        if self.status != self.Status.COLLECTED and self.collected_at is not None:
            raise ValidationError(
                {"collected_at": "Only a collected order can have a collection time."}
            )

        if self.pk:
            previous = (
                type(self)
                .objects.filter(pk=self.pk)
                .values("owner_id", "venue_id")
                .first()
            )
            if previous and previous["owner_id"] != self.owner_id:
                raise ValidationError(
                    {"owner": "An order's owner cannot be changed."}
                )
            if (
                previous is not None
                and previous["venue_id"] != self.venue_id
                and self.items.exists()
            ):
                raise ValidationError(
                    {"venue": "An order's venue cannot change after items are added."}
                )

    def save(self, *args, **kwargs):
        database = kwargs.get("using") or router.db_for_write(type(self), instance=self)

        # Keep the row mutation and its feed event in one transaction. Locking an
        # existing order also makes the previous feed state reliable when two
        # workers update it concurrently.
        with transaction.atomic(using=database):
            previous = None
            if not self._state.adding and self.pk:
                previous = (
                    type(self)
                    .objects.using(database)
                    .select_for_update()
                    .filter(pk=self.pk)
                    .values("owner_id", "venue_id", "status")
                    .first()
                )

                update_fields = kwargs.get("update_fields")
                owner_is_being_saved = update_fields is None or bool(
                    {"owner", "owner_id"}.intersection(update_fields)
                )
                if (
                    previous is not None
                    and owner_is_being_saved
                    and previous["owner_id"] != self.owner_id
                ):
                    raise ValidationError(
                        {"owner": "An order's owner cannot be changed."}
                    )
                venue_is_being_saved = update_fields is None or bool(
                    {"venue", "venue_id"}.intersection(update_fields)
                )
                if (
                    previous is not None
                    and venue_is_being_saved
                    and previous["venue_id"] != self.venue_id
                    and RedemptionOrderItem.objects.using(database)
                    .filter(order_id=self.pk)
                    .exists()
                ):
                    raise ValidationError(
                        {
                            "venue": (
                                "An order's venue cannot change after items are added."
                            )
                        }
                    )

            persisted_venue_id = (
                previous["venue_id"]
                if previous is not None
                and kwargs.get("update_fields") is not None
                and not {"venue", "venue_id"}.intersection(kwargs["update_fields"])
                else self.venue_id
            )
            affected_venue_ids = {
                venue_id
                for venue_id in (
                    previous["venue_id"] if previous else None,
                    persisted_venue_id,
                )
                if venue_id is not None
            }
            # Lock both sides of a move in a stable order before the UPDATE's
            # foreign-key checks can acquire venue locks in the opposite order.
            list(
                Venue.objects.using(database)
                .select_for_update()
                .filter(pk__in=affected_venue_ids)
                .order_by("pk")
            )

            if self._state.adding:
                self.owner_name_snapshot = self.owner.display_name

            self._previous_cafe_feed_state = previous
            return super().save(*args, **kwargs)

    def __str__(self):
        return self.reference_number


class RedemptionOrderItem(models.Model):
    order = models.ForeignKey(
        RedemptionOrder,
        related_name="items",
        on_delete=models.CASCADE,
    )
    venue_offer = models.ForeignKey(
        VenueOffer,
        related_name="redemption_order_items",
        on_delete=models.PROTECT,
    )
    item_name_snapshot = models.CharField(max_length=150, blank=True, editable=False)
    point_price_snapshot = models.PositiveIntegerField(default=0, editable=False)
    quantity = models.PositiveIntegerField(default=1)

    class Meta:
        ordering = ("id",)
        constraints = [
            models.CheckConstraint(
                condition=models.Q(point_price_snapshot__gt=0),
                name="redemption_item_price_positive",
            ),
            models.CheckConstraint(
                condition=models.Q(quantity__gt=0),
                name="redemption_item_quantity_positive",
            ),
        ]

    def clean(self):
        super().clean()
        errors = {}
        if self.pk:
            previous = (
                type(self)
                .objects.filter(pk=self.pk)
                .values("order_id", "venue_offer_id")
                .first()
            )
            if previous is not None:
                if previous["order_id"] != self.order_id:
                    errors["order"] = "An order item's order cannot be changed."
                if previous["venue_offer_id"] != self.venue_offer_id:
                    errors["venue_offer"] = (
                        "An order item's venue offer cannot be changed."
                    )

        if (
            self.order_id
            and self.venue_offer_id
            and self.order.venue_id != self.venue_offer.venue_id
        ):
            errors["venue_offer"] = "The offer must belong to the order's venue."

        if errors:
            raise ValidationError(errors)

    def save(self, *args, **kwargs):
        database = kwargs.get("using") or router.db_for_write(type(self), instance=self)

        with transaction.atomic(using=database):
            previous = None
            if not self._state.adding and self.pk:
                previous = (
                    type(self)
                    .objects.using(database)
                    .select_for_update()
                    .filter(pk=self.pk)
                    .values("order_id", "venue_offer_id")
                    .first()
                )

                update_fields = kwargs.get("update_fields")
                order_is_being_saved = update_fields is None or bool(
                    {"order", "order_id"}.intersection(update_fields)
                )
                offer_is_being_saved = update_fields is None or bool(
                    {"venue_offer", "venue_offer_id"}.intersection(update_fields)
                )
                errors = {}
                if (
                    previous is not None
                    and order_is_being_saved
                    and previous["order_id"] != self.order_id
                ):
                    errors["order"] = "An order item's order cannot be changed."
                if (
                    previous is not None
                    and offer_is_being_saved
                    and previous["venue_offer_id"] != self.venue_offer_id
                ):
                    errors["venue_offer"] = (
                        "An order item's venue offer cannot be changed."
                    )
                if errors:
                    raise ValidationError(errors)

            persisted_order_id = (
                previous["order_id"]
                if previous is not None
                and kwargs.get("update_fields") is not None
                and not {"order", "order_id"}.intersection(kwargs["update_fields"])
                else self.order_id
            )
            persisted_offer_id = (
                previous["venue_offer_id"]
                if previous is not None
                and kwargs.get("update_fields") is not None
                and not {"venue_offer", "venue_offer_id"}.intersection(
                    kwargs["update_fields"]
                )
                else self.venue_offer_id
            )

            order = (
                RedemptionOrder.objects.using(database)
                .select_for_update()
                .only("venue_id")
                .get(pk=persisted_order_id)
            )
            offer = (
                VenueOffer.objects.using(database)
                .select_for_update()
                .only("venue_id", "name", "point_price")
                .get(pk=persisted_offer_id)
            )
            if order.venue_id != offer.venue_id:
                raise ValidationError(
                    {"venue_offer": "The offer must belong to the order's venue."}
                )

            if self._state.adding:
                if not self.item_name_snapshot:
                    self.item_name_snapshot = offer.name
                if self.point_price_snapshot == 0:
                    self.point_price_snapshot = offer.point_price

            self._previous_order_id = previous["order_id"] if previous else None
            return super().save(*args, **kwargs)

    def __str__(self):
        return f"{self.quantity} × {self.item_name_snapshot}"


class CafeOrderEvent(models.Model):
    """Append-only change log used as the café polling high-water mark."""

    class Kind(models.TextChoices):
        UPSERT = "UPSERT", "Upsert"
        REMOVE = "REMOVE", "Remove"

    cursor = models.PositiveBigIntegerField()
    venue_id = models.PositiveBigIntegerField()
    order_id = models.PositiveBigIntegerField()
    kind = models.CharField(max_length=6, choices=Kind.choices)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ("id",)
        constraints = [
            models.UniqueConstraint(
                fields=("venue_id", "cursor"),
                name="cafe_order_event_venue_cursor_unique",
            )
        ]

    def __str__(self):
        return f"{self.cursor}: {self.kind} order {self.order_id}"
