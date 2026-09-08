"""Point balance and spend/credit logic, shared by every feature that earns
or spends points. Do not write to PointEntry directly from a view — go
through these functions so a balance change always keeps a credit entry's
remaining_points and its matching debit entry in sync (see
PointEntry.clean()).
"""
from django.db import transaction
from django.db.models import Sum
from django.utils import timezone

from .models import PointEntry, Redemption, Reward, default_point_expiry


class InsufficientPointsError(Exception):
    """Raised when a user's unexpired balance cannot cover a spend."""


class RewardUnavailableError(Exception):
    """Raised when a reward id does not resolve to an available reward."""


class RedemptionNotCollectibleError(Exception):
    """Raised when Collect is tapped on a redemption that isn't PENDING."""


def get_balance(user) -> int:
    total = PointEntry.objects.filter(
        user=user,
        amount__gt=0,
        remaining_points__gt=0,
        expires_at__gt=timezone.now(),
    ).aggregate(total=Sum("remaining_points"))["total"]
    return total or 0


@transaction.atomic
def spend_points(*, user, amount, source_reference=None):
    """Deduct `amount` points from `user`, soonest-to-expire entry first
    (FIFO). Raises InsufficientPointsError, and touches nothing, if the
    unexpired balance is short. Caller should run this inside its own
    atomic block so a failed spend rolls back everything else in the same
    request.
    """
    if amount <= 0:
        raise ValueError("amount must be positive")

    entries = list(
        PointEntry.objects.select_for_update()
        .filter(
            user=user,
            amount__gt=0,
            remaining_points__gt=0,
            expires_at__gt=timezone.now(),
        )
        .order_by("expires_at", "created_at")
    )

    remaining_to_spend = amount
    planned = []
    for entry in entries:
        if remaining_to_spend <= 0:
            break
        take = min(entry.remaining_points, remaining_to_spend)
        planned.append((entry, take))
        remaining_to_spend -= take

    if remaining_to_spend > 0:
        raise InsufficientPointsError("Not enough points to complete this redemption.")

    for entry, take in planned:
        entry.remaining_points -= take
        entry.save(update_fields=["remaining_points"])

    PointEntry.objects.create(
        user=user,
        amount=-amount,
        remaining_points=0,
        type=PointEntry.Type.SPEND,
        expires_at=None,
        source_reference=source_reference,
    )


@transaction.atomic
def credit_points(
    *, user, amount, type=PointEntry.Type.ADMIN, expires_at=None, source_reference=None
):
    """Create a new credit PointEntry with its full amount available to
    spend."""
    if amount <= 0:
        raise ValueError("amount must be positive")

    return PointEntry.objects.create(
        user=user,
        amount=amount,
        remaining_points=amount,
        type=type,
        expires_at=expires_at or default_point_expiry(),
        source_reference=source_reference,
    )


@transaction.atomic
def create_redemption(*, owner, reward_id):
    """Redeem `reward_id` for `owner`, deducting points immediately."""
    reward = Reward.objects.select_for_update().filter(id=reward_id, is_available=True).first()
    if reward is None:
        raise RewardUnavailableError("This reward is not available.")

    redemption = Redemption.objects.create(
        owner_user=owner,
        reward=reward,
        reward_name_snapshot=reward.name,
        point_cost_snapshot=reward.point_cost,
    )

    # Raises InsufficientPointsError, rolling back the redemption too,
    # since this whole function is one transaction.
    spend_points(
        user=owner,
        amount=reward.point_cost,
        source_reference=f"redemption:{redemption.reference_number}",
    )

    return redemption


@transaction.atomic
def collect_redemption(*, owner, redemption_id):
    """Mark a redemption COLLECTED. Returns None if no such redemption
    exists for this owner. Returns it unchanged if already COLLECTED — a
    repeated Collect tap must not error or re-apply the change.
    """
    redemption = (
        Redemption.objects.select_for_update()
        .filter(id=redemption_id, owner_user=owner)
        .first()
    )
    if redemption is None:
        return None

    if redemption.status == Redemption.Status.COLLECTED:
        return redemption

    if redemption.status != Redemption.Status.PENDING:
        raise RedemptionNotCollectibleError(
            f"This redemption is {redemption.get_status_display().lower()} "
            "and can no longer be collected."
        )

    redemption.status = Redemption.Status.COLLECTED
    redemption.collected_at = timezone.now()
    redemption.save(update_fields=["status", "collected_at"])
    return redemption
