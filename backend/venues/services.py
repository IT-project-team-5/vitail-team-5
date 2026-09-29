"""Server-authoritative venue check-ins.

The app only reports locations. The backend decides whether dwell was met, using its own
receipt times rather than client timestamps, and writes the award in the same owner-locked
transaction as the completion so a retry can never pay twice.
"""
import math

from django.contrib.auth import get_user_model
from django.db import transaction
from django.utils import timezone
from rest_framework.exceptions import NotFound, ValidationError

from rewards.models import PointEntry
from rewards.services import credit_points
from walks.services import MAX_ACCURACY_M, distance_between

from .daily_cap import remaining_daily_cap
from .models import CheckIn, Venue


CHECKIN_POINTS = 12
# The app reports about every 30 s; two missed reports mean the session is gone.
MAX_REPORT_GAP_SECONDS = 90


class AlreadyCheckedInError(Exception):
    pass


def _lock_owner(user):
    owner = get_user_model().objects.select_for_update().get(pk=user.pk)
    if owner.role != owner.Role.OWNER:
        raise ValidationError("Only dog owners can check in.")
    return owner


def _inside(venue, sample):
    return distance_between(
        {"latitude": venue.latitude, "longitude": venue.longitude}, sample
    ) <= venue.checkin_radius_m


def _abandon(check_in, reason):
    check_in.status = CheckIn.Status.ABANDONED
    check_in.abandon_reason = reason
    check_in.save(update_fields=["status", "abandon_reason"])
    return check_in


def _reject(sample):
    if not all(math.isfinite(sample[key]) for key in ("latitude", "longitude", "accuracy_m")):
        raise ValidationError({"code": "INVALID_LOCATION", "message": "Use a finite location."})
    if sample["is_simulated"]:
        raise ValidationError({"code": "SIMULATED_LOCATION",
                               "message": "Simulated locations cannot earn check-in points."})


def _abandon_open(owner, reason):
    for open_check_in in CheckIn.objects.filter(owner=owner, status=CheckIn.Status.IN_PROGRESS):
        _abandon(open_check_in, reason)


@transaction.atomic
def start_check_in(*, owner, venue_id, sample):
    owner = _lock_owner(owner)
    venue = Venue.objects.filter(pk=venue_id, is_active=True).first()
    if venue is None:
        raise NotFound("Venue not found.")
    _reject(sample)
    now = timezone.now()
    today = timezone.localdate(now)
    if CheckIn.objects.filter(owner=owner, venue=venue, completed_local_date=today).exists():
        raise AlreadyCheckedInError("You have already checked in here today.")
    if sample["accuracy_m"] > MAX_ACCURACY_M:
        raise ValidationError({"code": "LOW_ACCURACY", "message":
                               "Location is too imprecise. Wait for a better GPS signal."})
    if not _inside(venue, sample):
        raise ValidationError({"code": "OUTSIDE_RADIUS", "message":
                               f"Move within {venue.checkin_radius_m} m of {venue.name} to check in."})
    _abandon_open(owner, CheckIn.Reason.REPLACED)
    return CheckIn.objects.create(owner=owner, venue=venue, entered_at=now, last_report_at=now)


@transaction.atomic
def report_location(*, owner, check_in_id, sample):
    owner = _lock_owner(owner)
    check_in = CheckIn.objects.select_related("venue").filter(owner=owner, pk=check_in_id).first()
    if check_in is None:
        raise NotFound("Check-in not found.")
    if check_in.status != CheckIn.Status.IN_PROGRESS:
        return check_in
    now = timezone.now()
    if (now - check_in.last_report_at).total_seconds() > MAX_REPORT_GAP_SECONDS:
        return _abandon(check_in, CheckIn.Reason.SIGNAL_LOST)
    if sample["is_simulated"]:
        return _abandon(check_in, CheckIn.Reason.SIMULATED)
    if sample["accuracy_m"] > MAX_ACCURACY_M:
        # Not evidence either way; the report gap still runs, so no free dwell.
        return check_in
    if not _inside(check_in.venue, sample):
        return _abandon(check_in, CheckIn.Reason.LEFT_RADIUS)
    check_in.last_report_at = now
    if (now - check_in.entered_at).total_seconds() >= check_in.venue.dwell_seconds:
        return _complete(owner, check_in, now)
    check_in.save(update_fields=["last_report_at"])
    return check_in


def _complete(owner, check_in, now):
    local_date = timezone.localdate(now)
    points = min(CHECKIN_POINTS, remaining_daily_cap(owner, local_date))
    check_in.status = CheckIn.Status.COMPLETED
    check_in.dwell_completed_at = now
    check_in.completed_local_date = local_date
    check_in.awarded_points = points
    check_in.save(update_fields=[
        "last_report_at", "status", "dwell_completed_at", "completed_local_date", "awarded_points",
    ])
    if points:
        credit_points(user=owner, amount=points, type=PointEntry.Type.EARN,
                      source_reference=f"checkin:{check_in.pk}")
    return check_in


@transaction.atomic
def abandon_check_in(*, owner, check_in_id):
    owner = _lock_owner(owner)
    check_in = CheckIn.objects.select_related("venue").filter(owner=owner, pk=check_in_id).first()
    if check_in is None:
        raise NotFound("Check-in not found.")
    if check_in.status == CheckIn.Status.IN_PROGRESS:
        _abandon(check_in, CheckIn.Reason.CANCELLED)
    return check_in
