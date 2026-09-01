"""Order creation and collection. Both run as a single database transaction
(TECH_STACK.md, section 12, "Atomicity") and never trust a client-supplied
owner — the caller always passes the authenticated request.user.
"""
from django.db import transaction
from django.utils import timezone

from wallets.models import PointLedger
from wallets.services import InsufficientPointsError, spend_points  # noqa: F401 re-exported

from .models import RedemptionOrder, RedemptionOrderItem, generate_reference_number

REFERENCE_NUMBER_ATTEMPTS = 10


class EmptyOrderError(Exception):
    """Raised when an order is created with no items."""


class OfferUnavailableError(Exception):
    """Raised when a requested offer is unavailable or not at this venue."""


class OrderNotCollectibleError(Exception):
    """Raised when Redeem is tapped on an order that isn't PENDING."""


def _unique_reference_number() -> str:
    for _ in range(REFERENCE_NUMBER_ATTEMPTS):
        candidate = generate_reference_number()
        if not RedemptionOrder.objects.filter(reference_number=candidate).exists():
            return candidate
    raise RuntimeError("Could not generate a unique reference number.")


def _end_of_local_day():
    end_of_day = timezone.localtime()
    return end_of_day.replace(hour=23, minute=59, second=59, microsecond=999999)


@transaction.atomic
def create_order(*, owner, venue, items):
    """`items` is a list of {"offer": VenueOffer, "quantity": int}, already
    resolved and validated by the serializer against `venue`.
    """
    if not items:
        raise EmptyOrderError("An order needs at least one item.")

    for entry in items:
        offer = entry["offer"]
        if offer.venue_id != venue.id or not offer.is_available:
            raise OfferUnavailableError(f"'{offer.name}' is not available at this venue.")

    total_points = sum(entry["offer"].point_price * entry["quantity"] for entry in items)

    order = RedemptionOrder.objects.create(
        owner=owner,
        venue=venue,
        reference_number=_unique_reference_number(),
        status=RedemptionOrder.Status.PENDING,
        total_points=total_points,
        expires_at=_end_of_local_day(),
    )

    RedemptionOrderItem.objects.bulk_create(
        RedemptionOrderItem(
            order=order,
            venue_offer=entry["offer"],
            item_name_snapshot=entry["offer"].name,
            point_price_snapshot=entry["offer"].point_price,
            quantity=entry["quantity"],
        )
        for entry in items
    )

    # Raises InsufficientPointsError, rolling back the order and its items
    # too, since this whole function is one transaction.
    spend_points(
        owner=owner,
        amount=total_points,
        entry_type=PointLedger.EntryType.REDEMPTION_SPEND,
        reason=f"Redemption order {order.reference_number}",
        redemption_order=order,
    )

    return order


@transaction.atomic
def collect_order(*, owner, order_id):
    """Mark an order COLLECTED. Returns None if no such order exists for
    this owner. Returns the order unchanged if it is already COLLECTED — a
    repeated Redeem tap must not error or re-apply the change.
    """
    order = (
        RedemptionOrder.objects.select_for_update().filter(id=order_id, owner=owner).first()
    )
    if order is None:
        return None

    if order.status == RedemptionOrder.Status.COLLECTED:
        return order

    if order.status != RedemptionOrder.Status.PENDING:
        raise OrderNotCollectibleError(
            f"This order is {order.get_status_display().lower()} and can no longer be redeemed."
        )

    order.status = RedemptionOrder.Status.COLLECTED
    order.collected_at = timezone.now()
    order.save(update_fields=["status", "collected_at"])
    return order
