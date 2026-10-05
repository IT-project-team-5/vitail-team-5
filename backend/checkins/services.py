"""Server-authoritative venue check-in progress and collection.

The device submits location samples only.  This module uses server receipt time,
the saved venue centre, and the daily wallet cap to decide whether a visit can be
collected.  It never accepts a duration, score, or client timestamp from the app.
"""
import math

from django.contrib.auth import get_user_model
from django.db import transaction
from django.db.models import Sum
from django.http import Http404
from django.utils import timezone
from rest_framework.exceptions import NotFound, ValidationError

from quests.models import QuestDefinition
from rewards.models import PointEntry
from rewards.policy import CHECKIN_POINTS, CHECKIN_RADIUS_M, CHECKIN_SECONDS, DAILY_ACTIVITY_CAP, local_date, next_midnight
from rewards.services import credit_points, get_balance
from venues.models import Venue
from walks.services import MAX_ACCURACY_M, distance_between

from .models import CheckIn


# The iOS app sends an update every 25 seconds.  A longer gap starts a fresh
# continuous dwell window, so background suspension cannot create free time.
MAX_REPORT_GAP_SECONDS = 90


def _owner_lock(owner):
    owner = get_user_model().objects.select_for_update().get(pk=owner.pk)
    if owner.role != owner.Role.OWNER or not owner.is_active or owner.deleted_at:
        raise Http404
    return owner


def _validate_sample(sample):
    fields = ("latitude", "longitude", "accuracy_m")
    if not all(math.isfinite(float(sample[field])) for field in fields):
        raise ValidationError({"code": "INVALID_LOCATION", "message": "Use a finite location."})
    if sample.get("is_simulated"):
        raise ValidationError({"code": "SIMULATED_LOCATION", "message": "Simulated locations cannot earn check-in points."})
    if sample["accuracy_m"] > MAX_ACCURACY_M:
        raise ValidationError({"code": "LOW_ACCURACY", "message": "Location is too imprecise. Wait for a better GPS signal."})


def _inside(row_or_venue, sample):
    latitude = row_or_venue.center_latitude if isinstance(row_or_venue, CheckIn) else row_or_venue.latitude
    longitude = row_or_venue.center_longitude if isinstance(row_or_venue, CheckIn) else row_or_venue.longitude
    radius = row_or_venue.radius_m if isinstance(row_or_venue, CheckIn) else CHECKIN_RADIUS_M
    return distance_between({"latitude": float(latitude), "longitude": float(longitude)}, sample) <= radius


def _checkin_enabled():
    return QuestDefinition.objects.filter(code=QuestDefinition.Code.CHECK_IN, is_enabled=True).exists()


def _require_available_reward(owner, day):
    if not _checkin_enabled():
        raise ValidationError({"code": "CHECKIN_UNAVAILABLE", "message": "Check-in rewards are currently unavailable."})
    if daily_activity_points(owner, day) + CHECKIN_POINTS > DAILY_ACTIVITY_CAP:
        raise ValidationError({"code": "DAILY_LIMIT_REACHED", "message": "There is not enough daily allowance for a check-in reward."})


@transaction.atomic
def start_checkin(*, owner, venue_id, sample, now=None):
    """Start one verified dwell attempt for the venue's daily category slot."""
    owner = _owner_lock(owner)
    _validate_sample(sample)
    now = now or timezone.now()
    day = local_date(now)
    _require_available_reward(owner, day)
    venue = Venue.objects.select_for_update().filter(
        pk=venue_id, is_active=True, checkin_enabled=True,
        latitude__isnull=False, longitude__isnull=False,
    ).first()
    if venue is None:
        raise NotFound("Venue not found.")
    if not _inside(venue, sample):
        raise ValidationError({"code": "OUTSIDE_RADIUS", "message": f"Move within {CHECKIN_RADIUS_M} m of {venue.name} to check in."})

    existing = CheckIn.objects.select_for_update().select_related("venue", "point_entry").filter(
        owner=owner, local_date=day, category_slot=venue.kind,
    ).first()
    if existing:
        if existing.venue_id == venue.pk and existing.expires_at > now:
            return existing
        raise ValidationError({"code": "CATEGORY_ALREADY_USED", "message": "Today's check-in for this venue type has already started."})

    return CheckIn.objects.create(
        owner=owner, venue=venue, venue_name_snapshot=venue.name, local_date=day,
        category_slot=venue.kind, radius_m=CHECKIN_RADIUS_M,
        center_latitude=venue.latitude, center_longitude=venue.longitude,
        required_seconds=CHECKIN_SECONDS[venue.kind], verified_seconds=0,
        last_recorded_at=now, last_latitude=sample["latitude"], last_longitude=sample["longitude"],
        last_verified_at=now, started_at=now, expires_at=next_midnight(now),
        promised_points=CHECKIN_POINTS,
    )


@transaction.atomic
def report_checkin_location(*, owner, checkin_id, sample, now=None):
    """Add one server-timed, continuous, in-radius dwell interval."""
    owner = _owner_lock(owner)
    _validate_sample(sample)
    now = now or timezone.now()
    row = CheckIn.objects.select_for_update().select_related("venue", "point_entry").filter(pk=checkin_id, owner=owner).first()
    if row is None:
        raise NotFound("Check-in not found.")
    if row.point_entry_id or row.ready_at:
        return row
    if row.local_date != local_date(now) or row.expires_at <= now or row.venue_id is None:
        raise ValidationError({"code": "CHECKIN_EXPIRED", "message": "This check-in has expired."})
    if not row.venue.is_active or not row.venue.checkin_enabled:
        raise ValidationError({"code": "VENUE_UNAVAILABLE", "message": "This venue is currently unavailable for check-in rewards."})

    previous = row.last_verified_at or row.last_recorded_at or row.started_at
    gap = (now - previous).total_seconds() if previous else MAX_REPORT_GAP_SECONDS + 1
    inside = _inside(row, sample)
    row.last_recorded_at = now
    row.last_latitude = sample["latitude"]
    row.last_longitude = sample["longitude"]
    if not inside or gap > MAX_REPORT_GAP_SECONDS:
        # A visit must be continuous.  Keep the attempt visible, but require a
        # new uninterrupted dwell from the next valid in-radius report.
        row.verified_seconds = 0
        row.last_verified_at = now if inside else None
        row.save(update_fields=("verified_seconds", "last_recorded_at", "last_latitude", "last_longitude", "last_verified_at", "updated_at"))
        return row

    row.verified_seconds = min(row.required_seconds, row.verified_seconds + max(0, int(gap)))
    row.last_verified_at = now
    update_fields = ["verified_seconds", "last_recorded_at", "last_latitude", "last_longitude", "last_verified_at", "updated_at"]
    if row.verified_seconds >= row.required_seconds:
        row.ready_at = now
        update_fields.append("ready_at")
    row.save(update_fields=update_fields)
    return row


@transaction.atomic
def cancel_checkin(*, owner, checkin_id):
    """Cancel only an unqualified dwell attempt; ready work remains collectible."""
    owner = _owner_lock(owner)
    row = CheckIn.objects.select_for_update().filter(pk=checkin_id, owner=owner).first()
    if row is None:
        raise NotFound("Check-in not found.")
    if row.point_entry_id or row.ready_at:
        return row
    row.delete()
    return None


def daily_activity_points(owner, day):
    return PointEntry.objects.filter(user=owner, type=PointEntry.Type.EARN, earned_on=day,
        earn_category__in=(PointEntry.EarnCategory.WALK, PointEntry.EarnCategory.CHECK_IN)
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
