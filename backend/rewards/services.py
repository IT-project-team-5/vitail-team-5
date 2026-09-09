"""One transactional wallet/order path for the owner app, café feed and admin.

Lock order: owner account → reward/order/point lots → café feed state.
All supported order changes go through these services; audit rows are never
edited or deleted in Admin. A refund is a new credit valid for twelve months.
"""
from django.contrib.auth import get_user_model
from django.db import transaction
from django.db.models import Sum
from django.utils import timezone

from .models import CafeOrderFeedState, PointEntry, Redemption, Reward, default_point_expiry


class InsufficientPointsError(Exception):
    pass


class RewardUnavailableError(Exception):
    pass


class RedemptionNotCollectibleError(Exception):
    pass


class IdempotencyConflictError(Exception):
    pass


def _lock_owner(user):
    owner = get_user_model().objects.select_for_update().get(pk=user.pk)
    if owner.role != owner.Role.OWNER:
        raise ValueError("Points and redemptions belong to dog owner accounts only.")
    return owner


def lock_feed_state(cafe_id):
    """Caller must hold a transaction. Row lock makes cursors commit-ordered."""
    CafeOrderFeedState.objects.get_or_create(cafe_user_id=cafe_id)
    return CafeOrderFeedState.objects.select_for_update().get(cafe_user_id=cafe_id)


def _publish_order(redemption):
    state = lock_feed_state(redemption.cafe_user_id)
    state.cursor += 1
    state.save(update_fields=["cursor"])
    redemption.feed_cursor = state.cursor
    redemption.save(update_fields=["feed_cursor"])


def get_balance(user):
    return PointEntry.objects.filter(
        user=user, remaining_points__gt=0, expires_at__gt=timezone.now()
    ).aggregate(total=Sum("remaining_points"))["total"] or 0


@transaction.atomic
def credit_points(*, user, amount, type=PointEntry.Type.ADMIN, expires_at=None, source_reference=None):
    _lock_owner(user)
    if amount <= 0 or type not in (PointEntry.Type.ADMIN, PointEntry.Type.EARN, PointEntry.Type.REFUND):
        raise ValueError("Credits must be positive and use a credit entry type.")
    if source_reference:
        existing = PointEntry.objects.filter(source_reference=source_reference).first()
        if existing:
            if (existing.user_id, existing.amount, existing.type) != (user.pk, amount, type):
                raise IdempotencyConflictError("This point event was already used for a different credit.")
            return existing
    return PointEntry.objects.create(
        user=user, amount=amount, remaining_points=amount, type=type,
        expires_at=expires_at or default_point_expiry(), source_reference=source_reference,
    )


@transaction.atomic
def spend_points(*, user, amount, source_reference=None):
    _lock_owner(user)
    if amount <= 0:
        raise ValueError("Spend amount must be positive.")
    if source_reference:
        existing = PointEntry.objects.filter(source_reference=source_reference).first()
        if existing:
            if (existing.user_id, existing.amount, existing.type) != (user.pk, -amount, PointEntry.Type.SPEND):
                raise IdempotencyConflictError("This point event was already used for a different spend.")
            return existing
    entries = list(PointEntry.objects.select_for_update().filter(
        user=user, remaining_points__gt=0, expires_at__gt=timezone.now()
    ).order_by("expires_at", "created_at", "id"))
    if sum(entry.remaining_points for entry in entries) < amount:
        raise InsufficientPointsError("Not enough points to complete this redemption.")
    remaining = amount
    for entry in entries:
        take = min(entry.remaining_points, remaining)
        entry.remaining_points -= take
        entry.save(update_fields=["remaining_points"])
        remaining -= take
        if not remaining:
            break
    return PointEntry.objects.create(
        user=user, amount=-amount, type=PointEntry.Type.SPEND,
        source_reference=source_reference,
    )


@transaction.atomic
def create_redemption(*, owner, reward_id, request_id=None):
    owner = _lock_owner(owner)
    if request_id:
        existing = Redemption.objects.filter(owner_user=owner, request_id=request_id).first()
        if existing:
            if existing.reward_id != reward_id:
                raise IdempotencyConflictError("This request ID was already used for another reward.")
            return existing
    reward = Reward.objects.select_for_update().filter(
        pk=reward_id, is_available=True, cafe_user__role="CAFE", cafe_user__is_active=True
    ).first()
    if reward is None:
        raise RewardUnavailableError("This reward is not available.")
    redemption = Redemption.objects.create(
        owner_user=owner, reward=reward, cafe_user=reward.cafe_user,
        owner_name_snapshot=owner.display_name, cafe_name_snapshot=reward.cafe_user.display_name,
        reward_name_snapshot=reward.name, point_cost_snapshot=reward.point_cost, request_id=request_id,
    )
    spend_points(user=owner, amount=reward.point_cost,
                 source_reference=f"redemption:{redemption.reference_number}")
    _publish_order(redemption)
    return redemption


def _refund_pending(redemption, status):
    """Caller holds owner/order locks. Status and refund commit together."""
    if redemption.status != Redemption.Status.PENDING:
        return False
    credit_points(
        user=redemption.owner_user, amount=redemption.point_cost_snapshot,
        type=PointEntry.Type.REFUND,
        source_reference=f"refund:{redemption.reference_number}",
    )
    redemption.status = status
    redemption.save(update_fields=["status"])
    _publish_order(redemption)
    return True


def collect_redemption(*, owner, redemption_id):
    # Raise only after committing an expired order's refund; raising inside
    # atomic would roll back the very expiry the user needs to see.
    with transaction.atomic():
        _lock_owner(owner)
        redemption = Redemption.objects.select_for_update().filter(
            pk=redemption_id, owner_user=owner
        ).first()
        if redemption is None:
            return None
        if redemption.status == Redemption.Status.PENDING and redemption.expires_at <= timezone.now():
            _refund_pending(redemption, Redemption.Status.EXPIRED)
        if redemption.status == Redemption.Status.PENDING:
            redemption.status = Redemption.Status.COLLECTED
            redemption.collected_at = timezone.now()
            redemption.save(update_fields=["status", "collected_at"])
            _publish_order(redemption)
        collectible = redemption.status == Redemption.Status.COLLECTED
    if not collectible:
        raise RedemptionNotCollectibleError(
            f"This redemption is {redemption.get_status_display().lower()} and can no longer be collected."
        )
    return redemption


@transaction.atomic
def cancel_redemption(*, redemption_id):
    row = Redemption.objects.filter(pk=redemption_id).values("owner_user_id").first()
    if row is None:
        return False
    owner = get_user_model().objects.select_for_update().get(pk=row["owner_user_id"])
    redemption = Redemption.objects.select_for_update().get(pk=redemption_id)
    status = Redemption.Status.EXPIRED if redemption.expires_at <= timezone.now() else Redemption.Status.CANCELLED
    return _refund_pending(redemption, status)


def expire_redemptions(*, owner=None, cafe=None, now=None):
    now = now or timezone.now()
    due = Redemption.objects.filter(status=Redemption.Status.PENDING, expires_at__lte=now)
    if owner is not None:
        due = due.filter(owner_user=owner)
    if cafe is not None:
        due = due.filter(cafe_user=cafe)
    count = 0
    for redemption_id, owner_id in due.values_list("id", "owner_user_id").iterator():
        with transaction.atomic():
            get_user_model().objects.select_for_update().get(pk=owner_id)
            redemption = Redemption.objects.select_for_update().get(pk=redemption_id)
            if redemption.status == Redemption.Status.PENDING and redemption.expires_at <= now:
                count += _refund_pending(redemption, Redemption.Status.EXPIRED)
    return count


def expire_points(*, owner=None, now=None):
    now = now or timezone.now()
    due = PointEntry.objects.filter(remaining_points__gt=0, expires_at__lte=now)
    if owner is not None:
        due = due.filter(user=owner)
    count = 0
    for entry_id, user_id in due.values_list("id", "user_id").iterator():
        with transaction.atomic():
            get_user_model().objects.select_for_update().get(pk=user_id)
            entry = PointEntry.objects.select_for_update().get(pk=entry_id)
            if entry.remaining_points and entry.expires_at <= now:
                PointEntry.objects.create(
                    user_id=user_id, amount=-entry.remaining_points,
                    type=PointEntry.Type.EXPIRE, source_reference=f"expire:{entry.pk}",
                )
                entry.remaining_points = 0
                entry.save(update_fields=["remaining_points"])
                count += 1
    return count
