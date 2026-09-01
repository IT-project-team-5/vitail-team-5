"""Point balance and spend/credit logic, shared by every feature that earns
or spends points. Do not write to PointLot/PointLedger directly from a view —
go through these functions so a balance change always carries its ledger
entry (TECH_STACK.md, section 6 and 12).
"""
from django.db import transaction
from django.db.models import Sum
from django.utils import timezone

from .models import PointLedger, PointLot


class InsufficientPointsError(Exception):
    """Raised when an owner's unexpired balance cannot cover a spend."""


def get_balance(owner) -> int:
    total = PointLot.objects.filter(
        owner=owner, expires_at__gt=timezone.now(), amount_remaining__gt=0
    ).aggregate(total=Sum("amount_remaining"))["total"]
    return total or 0


@transaction.atomic
def spend_points(*, owner, amount, entry_type, reason="", redemption_order=None):
    """Deduct `amount` points from `owner`, oldest-expiry lot first (FIFO).

    Raises InsufficientPointsError, and touches nothing, if the unexpired
    balance is short. Caller should run this inside its own atomic block so
    a failed spend rolls back everything else in the same request.
    """
    if amount <= 0:
        raise ValueError("amount must be positive")

    lots = list(
        PointLot.objects.select_for_update()
        .filter(owner=owner, amount_remaining__gt=0, expires_at__gt=timezone.now())
        .order_by("expires_at", "earned_at")
    )

    remaining_to_spend = amount
    planned = []
    for lot in lots:
        if remaining_to_spend <= 0:
            break
        take = min(lot.amount_remaining, remaining_to_spend)
        planned.append((lot, take))
        remaining_to_spend -= take

    if remaining_to_spend > 0:
        raise InsufficientPointsError("Not enough points to complete this redemption.")

    for lot, take in planned:
        lot.amount_remaining -= take
        lot.save(update_fields=["amount_remaining"])
        PointLedger.objects.create(
            owner=owner,
            amount=-take,
            entry_type=entry_type,
            lot=lot,
            redemption_order=redemption_order,
            reason=reason,
        )


@transaction.atomic
def credit_points(
    *, owner, amount, entry_type, expires_at, source=PointLot.Source.REFUND, reason="", redemption_order=None
):
    """Create a new PointLot and its matching ledger entry."""
    if amount <= 0:
        raise ValueError("amount must be positive")

    lot = PointLot.objects.create(
        owner=owner,
        source=source,
        amount_earned=amount,
        amount_remaining=amount,
        expires_at=expires_at,
    )
    PointLedger.objects.create(
        owner=owner,
        amount=amount,
        entry_type=entry_type,
        lot=lot,
        redemption_order=redemption_order,
        reason=reason,
    )
    return lot
