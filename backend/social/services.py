"""Locked relationship invariants. No social endpoints or matching are enabled."""
from django.contrib.auth import get_user_model
from django.core.exceptions import ValidationError
from django.db import transaction
from django.db.models import Q
from django.utils import timezone

from .models import Friendship, UserBlock


def _lock_pair(first, second):
    if not first.pk or not second.pk or first.pk == second.pk:
        raise ValidationError("Choose two different owner accounts.")
    users = list(get_user_model().objects.select_for_update().filter(pk__in=(first.pk, second.pk)).order_by("pk"))
    if len(users) != 2 or any(not user.is_active or user.deleted_at or user.role != "OWNER" for user in users):
        raise ValidationError("Social relationships require two active owner accounts.")
    return users[0].pk, users[1].pk


def is_blocked(first_id, second_id):
    return UserBlock.objects.filter(
        Q(blocker_id=first_id, blocked_id=second_id) | Q(blocker_id=second_id, blocked_id=first_id)
    ).exists()


def are_friends(first_id, second_id):
    if first_id == second_id or is_blocked(first_id, second_id):
        return False
    if get_user_model().objects.filter(pk__in=(first_id, second_id), is_active=True, deleted_at__isnull=True, role="OWNER").count() != 2:
        return False
    low, high = sorted((first_id, second_id))
    return Friendship.objects.filter(user_low_id=low, user_high_id=high, status=Friendship.Status.ACCEPTED).exists()


@transaction.atomic
def request_friendship(*, sender, recipient):
    low, high = _lock_pair(sender, recipient)
    if is_blocked(low, high):
        raise ValidationError("This relationship is unavailable.")
    relationship, _ = Friendship.objects.get_or_create(user_low_id=low, user_high_id=high, defaults={"requested_by_id": sender.pk})
    # A reciprocal request is not implicit consent; the recipient must accept.
    # Re-request policy for DECLINED is intentionally not enabled yet.
    return relationship


@transaction.atomic
def respond_to_friendship(*, actor, other, accept):
    low, high = _lock_pair(actor, other)
    if is_blocked(low, high):
        raise ValidationError("This relationship is unavailable.")
    relationship = Friendship.objects.select_for_update().filter(user_low_id=low, user_high_id=high).first()
    if relationship is None or relationship.requested_by_id == actor.pk:
        raise ValidationError("Only the request recipient can respond.")
    desired = Friendship.Status.ACCEPTED if accept else Friendship.Status.DECLINED
    if relationship.status == desired:
        return relationship
    if relationship.status != Friendship.Status.PENDING:
        raise ValidationError("This request was already answered.")
    relationship.status = desired
    relationship.responded_at = timezone.now()
    relationship.save(update_fields=("status", "responded_at"))
    return relationship


@transaction.atomic
def block_user(*, actor, other):
    low, high = _lock_pair(actor, other)
    block, _ = UserBlock.objects.get_or_create(blocker_id=actor.pk, blocked_id=other.pk)
    Friendship.objects.filter(user_low_id=low, user_high_id=high).delete()
    return block


@transaction.atomic
def unblock_user(*, actor, other):
    _lock_pair(actor, other)
    # Removing a directional block never recreates a friendship or consent.
    UserBlock.objects.filter(blocker_id=actor.pk, blocked_id=other.pk).delete()
