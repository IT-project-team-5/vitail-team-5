import random
import string

from django.conf import settings
from django.db import models

from venues.models import Venue, VenueOffer

REFERENCE_NUMBER_ALPHABET = string.ascii_uppercase + string.digits
REFERENCE_NUMBER_LENGTH = 8


def generate_reference_number() -> str:
    return "".join(random.choices(REFERENCE_NUMBER_ALPHABET, k=REFERENCE_NUMBER_LENGTH))


class RedemptionOrder(models.Model):
    """One partner-offer redemption (README.md, "Redeeming Points").

    Points are deducted at order creation, not at collection. An order not
    collected by end of day should move to EXPIRED with a refund, and an
    admin can CANCELLED one manually — neither of those jobs is built yet;
    only PENDING -> COLLECTED is implemented.
    """

    class Status(models.TextChoices):
        PENDING = "PENDING", "Pending"
        COLLECTED = "COLLECTED", "Collected"
        EXPIRED = "EXPIRED", "Expired"
        CANCELLED = "CANCELLED", "Cancelled"

    owner = models.ForeignKey(
        settings.AUTH_USER_MODEL, on_delete=models.CASCADE, related_name="redemption_orders"
    )
    venue = models.ForeignKey(Venue, on_delete=models.PROTECT, related_name="redemption_orders")
    reference_number = models.CharField(max_length=12, unique=True)
    status = models.CharField(max_length=10, choices=Status.choices, default=Status.PENDING)
    total_points = models.PositiveIntegerField()
    created_at = models.DateTimeField(auto_now_add=True)
    collected_at = models.DateTimeField(null=True, blank=True)
    expires_at = models.DateTimeField()

    class Meta:
        ordering = ["-created_at"]

    def __str__(self):
        return f"{self.reference_number} ({self.status})"


class RedemptionOrderItem(models.Model):
    """A snapshotted line item. Name and price are copied at order time so
    history stays correct after a venue edits its catalogue.
    """

    order = models.ForeignKey(RedemptionOrder, on_delete=models.CASCADE, related_name="items")
    venue_offer = models.ForeignKey(VenueOffer, on_delete=models.PROTECT, related_name="order_items")
    item_name_snapshot = models.CharField(max_length=150)
    point_price_snapshot = models.PositiveIntegerField()
    quantity = models.PositiveIntegerField(default=1)

    @property
    def subtotal(self) -> int:
        return self.point_price_snapshot * self.quantity

    def __str__(self):
        return f"{self.quantity} x {self.item_name_snapshot}"
