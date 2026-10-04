"""Shared persisted progress. GPS start/verification belongs to the venue integration.

These services do not accept client progress values or manufacture opportunities.
Partial awards and unconfirmed net cap membership remain disabled.
"""
from django.contrib.auth import get_user_model
from django.db import transaction
from django.db.models import Sum
from django.http import Http404
from django.utils import timezone
from rest_framework.exceptions import ValidationError

from quests.models import QuestDefinition
from rewards.models import PointEntry
from rewards.policy import DAILY_ACTIVITY_CAP, local_date
from rewards.services import credit_points, get_balance

from .models import CheckIn


def daily_activity_points(owner, day):
    return PointEntry.objects.filter(user=owner, type=PointEntry.Type.EARN, earned_on=day,
        earn_category__in=(PointEntry.EarnCategory.WALK, PointEntry.EarnCategory.CHECK_IN,
                           PointEntry.EarnCategory.DAILY_GOAL)
    ).aggregate(total=Sum("amount"))["total"] or 0


def current_progress(*, owner, now=None):
    now = now or timezone.now()
    day = local_date(now)
    earned = daily_activity_points(owner, day)
    enabled = QuestDefinition.objects.filter(code="CHECK_IN", is_enabled=True).exists()
    rows = CheckIn.objects.filter(owner=owner, local_date=day).select_related("venue", "point_entry")
    visible = [row for row in rows if row.collected_at or (
        enabled and earned < DAILY_ACTIVITY_CAP and row.venue_id and row.venue.is_active
        and row.venue.checkin_enabled and row.expires_at > now)]
    return {"local_date": day, "server_time": now, "earned_points_today": earned, "items": visible}


@transaction.atomic
def collect_checkin(*, owner, checkin_id, now=None):
    """Both consumers collect the same qualification under the wallet owner lock."""
    owner = get_user_model().objects.select_for_update().get(pk=owner.pk)
    now = now or timezone.now()
    if owner.role != "OWNER" or not owner.is_active or owner.deleted_at:
        raise Http404
    row = CheckIn.objects.select_for_update().select_related("point_entry", "venue").filter(pk=checkin_id, owner=owner).first()
    if row is None:
        raise Http404
    if not row.point_entry_id:
        if not QuestDefinition.objects.filter(code="CHECK_IN", is_enabled=True).exists():
            raise ValidationError("Check-in rewards are currently unavailable.")
        if row.venue_id is None or not row.venue.is_active or not row.venue.checkin_enabled:
            raise ValidationError("This venue is currently unavailable for check-in rewards.")
        if row.local_date != local_date(now) or row.expires_at <= now:
            raise ValidationError("This check-in has expired.")
        if row.ready_at is None or row.ready_at > now or row.verified_seconds < row.required_seconds:
            raise ValidationError("This check-in has not been verified as complete.")
        available = max(0, DAILY_ACTIVITY_CAP - daily_activity_points(owner, row.local_date))
        if available < row.promised_points:
            raise ValidationError("There is not enough daily allowance for this reward. Partial collection is not enabled.")
        row.point_entry = credit_points(user=owner, amount=row.promised_points, type=PointEntry.Type.EARN,
            source_reference=f"checkin:{row.pk}", earn_category=PointEntry.EarnCategory.CHECK_IN,
            earned_on=row.local_date, rules_version=row.rules_version)
        row.collected_at = now
        row.save(update_fields=("point_entry", "collected_at", "updated_at"))
    return {"check_in": row, "awarded_points": row.point_entry.amount, "wallet_balance": get_balance(owner),
            "daily_earned_points": daily_activity_points(owner, row.local_date), "local_date": row.local_date}
