"""Shared availability and daily allocation rules for browsing and purchasing."""
import hashlib
import json
from zoneinfo import ZoneInfo

from django.db.models import Count, F, Q
from django.utils import timezone

from .models import Redemption, Reward


MELBOURNE = ZoneInfo("Australia/Melbourne")


def purchase_fingerprint(reward_id):
    payload = json.dumps({"reward_id": reward_id}, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(payload.encode()).hexdigest()


def active_rewards(now):
    return Reward.objects.filter(
        is_available=True, venue__is_active=True, venue__is_partner=True,
        venue__manager_user__is_active=True, venue__manager_user__role="CAFE",
    ).filter(Q(starts_at__isnull=True) | Q(starts_at__lte=now)).filter(
        Q(ends_at__isnull=True) | Q(ends_at__gt=now))


def daily_allocation_filter(now, prefix=""):
    # Pending orders reserve one unit; cancellation/expiry releases it. Collected
    # orders consume one unit for the Melbourne date on which they were bought.
    return Q(**{prefix + "order_date": timezone.localdate(now, timezone=MELBOURNE)}) & (
        Q(**{prefix + "status": Redemption.Status.COLLECTED}) |
        Q(**{prefix + "status": Redemption.Status.PENDING, prefix + "expires_at__gt": now})
    )


def available_rewards(now=None):
    now = now or timezone.now()
    return active_rewards(now).annotate(
        allocated_today=Count("redemptions", filter=daily_allocation_filter(now, "redemptions__"))
    ).filter(Q(daily_quantity_limit__isnull=True) | Q(allocated_today__lt=F("daily_quantity_limit")))
