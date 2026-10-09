"""Verified same-walk venue progress; rewards settle with the immutable Walk."""
import math
import hashlib
import json
from datetime import timedelta

from django.contrib.auth import get_user_model
from django.db import transaction
from django.db.models import Q, Sum
from django.db.models.functions import Greatest
from django.http import Http404
from django.utils import timezone
from rest_framework.exceptions import NotFound, ValidationError

from quests.models import QuestDefinition
from rewards.models import PointEntry
from rewards.policy import CHECKIN_POINTS, CHECKIN_RADIUS_M, CHECKIN_SECONDS, DAILY_ACTIVITY_CAP, local_date
from rewards.services import credit_points, get_balance
from venues.models import Venue
from walks.services import CLOCK_SKEW, MAX_ACCURACY_M, MAX_WALK_AGE, WalkConflictError, distance_between

from .models import CheckIn, CheckInWalk

MAX_REPORT_GAP_SECONDS = 90
CHECKIN_RULES_VERSION = "checkin-walk-v1"


def _owner_lock(owner):
    owner = get_user_model().objects.select_for_update().get(pk=owner.pk)
    if owner.role != owner.Role.OWNER or not owner.is_active or owner.deleted_at:
        raise Http404
    return owner


def _valid_sample(sample, context, now):
    return (all(math.isfinite(float(sample[field])) for field in ("latitude", "longitude", "accuracy_m"))
            and not sample.get("is_simulated") and sample["accuracy_m"] <= MAX_ACCURACY_M
            and context.started_at <= sample["recorded_at"] <= now + timedelta(seconds=5)
            and now - sample["recorded_at"] <= timedelta(seconds=30))


def _sample_fingerprint(sample):
    body = {**sample, "recorded_at": sample["recorded_at"].isoformat()}
    return hashlib.sha256(json.dumps(body, sort_keys=True).encode()).hexdigest()


def _inside(row_or_venue, sample):
    latitude = row_or_venue.center_latitude if isinstance(row_or_venue, CheckIn) else row_or_venue.latitude
    longitude = row_or_venue.center_longitude if isinstance(row_or_venue, CheckIn) else row_or_venue.longitude
    radius = row_or_venue.radius_m if isinstance(row_or_venue, CheckIn) else CHECKIN_RADIUS_M
    return distance_between({"latitude": float(latitude), "longitude": float(longitude)}, sample) <= radius


def reward_category(kind):
    return "PARTNER" if kind in ("CAFE", "RESTAURANT") else kind


def eligible_venues():
    return Venue.objects.filter(
        is_active=True, checkin_enabled=True, latitude__isnull=False, longitude__isnull=False,
    ).filter(Q(kind__in=("VET", "PARK")) | Q(kind__in=("CAFE", "RESTAURANT"), is_partner=True))


def _venue_eligible(venue):
    return bool(venue and venue.is_active and venue.checkin_enabled
                and venue.latitude is not None and venue.longitude is not None
                and (venue.kind in ("VET", "PARK")
                     or venue.kind in ("CAFE", "RESTAURANT") and venue.is_partner))


def _rewarded_categories(owner, day):
    return set(CheckIn.objects.filter(
        owner=owner, local_date=day, point_entry__isnull=False,
    ).values_list("category_slot", flat=True))


def _checkin_enabled():
    return QuestDefinition.objects.filter(code=QuestDefinition.Code.CHECK_IN, is_enabled=True).exists()


def _require_available_reward(owner, day):
    if not _checkin_enabled():
        raise ValidationError({"code": "CHECKIN_UNAVAILABLE", "message": "Check-in rewards are currently unavailable."})
    if daily_activity_points(owner, day) + CHECKIN_POINTS > DAILY_ACTIVITY_CAP:
        raise ValidationError({"code": "DAILY_LIMIT_REACHED", "message": "There is not enough daily allowance for a check-in reward."})


@transaction.atomic
def update_walk_context(*, owner, walk_request_id, started_at, state, now=None):
    """The manual tracker has a lifecycle separate from optional social presence."""
    owner = _owner_lock(owner)
    now = now or timezone.now()
    context = CheckInWalk.objects.select_for_update().filter(owner=owner, request_id=walk_request_id).first()
    if context is None:
        if started_at > now + CLOCK_SKEW or started_at < now - MAX_WALK_AGE:
            raise ValidationError({"code": "INVALID_WALK_TIME", "message": "Use the current walk's start time."})
        if state != CheckInWalk.State.RECORDING:
            raise ValidationError({"code": "WALK_NOT_STARTED", "message": "Start recording this walk first."})
        # A new walk stops old accrual but preserves ready evidence for a lost
        # Finish/upload response. Explicit CANCELLED remains a real discard.
        previous = CheckInWalk.objects.filter(owner=owner, state__in=("RECORDING", "PAUSED"))
        CheckIn.objects.filter(walk_context__in=previous).update(last_verified_at=None)
        previous.update(state="FINISHED", ended_at=Greatest("started_at", now))
        return CheckInWalk.objects.create(owner=owner, request_id=walk_request_id,
                                          started_at=started_at, state=state)
    if context.started_at != started_at:
        raise WalkConflictError("This walk ID was already used with a different start time.")
    if context.state == state:
        return context
    if context.state in ("FINISHED", "CANCELLED") or context.settled_at:
        raise WalkConflictError("This venue walk context has already ended.")
    if state == "RECORDING" and now > context.started_at + MAX_WALK_AGE:
        raise ValidationError({"code": "WALK_EXPIRED", "message": "This walk has expired."})
    if now < context.started_at:
        raise ValidationError("The walk has not started yet.")
    context.state = state
    if state in ("FINISHED", "CANCELLED"):
        context.ended_at = now
    context.save(update_fields=("state", "ended_at"))
    # A resume starts at the next reliable sample, never bridges a pause.
    context.checkins.update(last_verified_at=None)
    return context


@transaction.atomic
def start_checkin(*, owner, venue_id, walk_request_id, sample, now=None):
    owner = _owner_lock(owner)
    now = now or timezone.now()
    context = CheckInWalk.objects.select_for_update().filter(owner=owner, request_id=walk_request_id).first()
    if context is None or context.state != "RECORDING" or context.started_at > now or now > context.started_at + MAX_WALK_AGE:
        raise ValidationError({"code": "RECORDING_WALK_REQUIRED", "message": "Start a walk to earn venue points."})
    if not _valid_sample(sample, context, now):
        raise ValidationError({"code": "UNRELIABLE_LOCATION", "message": "Wait for a reliable GPS signal."})
    venue = eligible_venues().select_for_update().filter(pk=venue_id).first()
    if venue is None:
        raise NotFound("Venue not found.")
    existing = CheckIn.objects.select_for_update().select_related("venue", "point_entry", "walk_context").filter(
        owner=owner, walk_context=context, venue=venue,
    ).first()
    if existing:
        return report_checkin_location(owner=owner, checkin_id=existing.pk, sample=sample, now=now)
    day = local_date(now)
    _require_available_reward(owner, day)
    if venue.kind in _rewarded_categories(owner, day):
        raise ValidationError({"code": "CATEGORY_ALREADY_USED", "message": "Today's reward for this venue category has already been earned."})
    if not _inside(venue, sample):
        raise ValidationError({"code": "OUTSIDE_RADIUS", "message": f"Move within {CHECKIN_RADIUS_M} m of {venue.name} to check in."})
    return CheckIn.objects.create(
        owner=owner, walk_context=context, venue=venue, venue_name_snapshot=venue.name,
        local_date=day, category_slot=venue.kind, radius_m=CHECKIN_RADIUS_M,
        center_latitude=venue.latitude, center_longitude=venue.longitude,
        required_seconds=CHECKIN_SECONDS[venue.kind], last_sequence=sample["sequence"],
        last_captured_at=sample["recorded_at"], last_sample_fingerprint=_sample_fingerprint(sample),
        last_recorded_at=now, last_latitude=sample["latitude"], last_longitude=sample["longitude"],
        last_verified_at=now, started_at=sample["recorded_at"], expires_at=context.started_at + MAX_WALK_AGE,
        promised_points=CHECKIN_POINTS, rules_version=CHECKIN_RULES_VERSION,
    )


@transaction.atomic
def report_checkin_location(*, owner, checkin_id, sample, now=None):
    """Only adjacent reliable receipts accrue; sequence retries never add time."""
    owner = _owner_lock(owner)
    now = now or timezone.now()
    row = CheckIn.objects.select_for_update().select_related("venue", "point_entry", "walk_context").filter(pk=checkin_id, owner=owner).first()
    if row is None:
        raise NotFound("Check-in not found.")
    if row.point_entry_id or row.ready_at:
        return row
    if row.last_sequence is not None and sample["sequence"] <= row.last_sequence:
        if sample["sequence"] == row.last_sequence and _sample_fingerprint(sample) != row.last_sample_fingerprint:
            row.last_verified_at = None
            row.save(update_fields=("last_verified_at", "updated_at"))
        return row
    if row.last_captured_at and sample["recorded_at"] <= row.last_captured_at:
        # Sequence alone is not evidence of a new GPS reading. Keep the capture
        # high-water mark so a renamed replay cannot earn the same interval twice.
        row.last_verified_at = None
        row.save(update_fields=("last_verified_at", "updated_at"))
        return row
    if row.walk_context_id is None or row.walk_context.state != "RECORDING" or row.expires_at <= now:
        row.last_verified_at = None
        row.save(update_fields=("last_verified_at", "updated_at"))
        return row
    reliable = _valid_sample(sample, row.walk_context, now)
    allowed = (_checkin_enabled() and _venue_eligible(row.venue)
               and daily_activity_points(owner, local_date(now)) + row.promised_points <= DAILY_ACTIVITY_CAP
               and row.category_slot not in _rewarded_categories(owner, local_date(now)))
    inside = bool(reliable and allowed and _inside(row, sample))
    previous = row.last_verified_at
    gap = (now - previous).total_seconds() if previous else None
    captured_gap = (sample["recorded_at"] - row.last_captured_at).total_seconds() if row.last_captured_at else None
    # Out-of-order receipt times must not move the anchor backwards.
    if row.last_recorded_at and now <= row.last_recorded_at:
        return row
    row.last_sequence = sample["sequence"]
    row.last_sample_fingerprint = _sample_fingerprint(sample)
    row.last_recorded_at = now
    row.last_latitude = sample["latitude"] if reliable else None
    row.last_longitude = sample["longitude"] if reliable else None
    if inside and gap is not None and captured_gap is not None and 0 < gap <= MAX_REPORT_GAP_SECONDS and 0 < captured_gap <= MAX_REPORT_GAP_SECONDS:
        row.verified_seconds = min(row.required_seconds, row.verified_seconds + int(min(gap, captured_gap)))
    if reliable:
        row.last_captured_at = sample["recorded_at"]
    row.last_verified_at = now if inside else None
    fields = ["last_sequence", "last_sample_fingerprint", "last_captured_at", "last_recorded_at", "last_latitude", "last_longitude", "last_verified_at", "verified_seconds", "updated_at"]
    if row.verified_seconds == row.required_seconds:
        row.ready_at = min(now, sample["recorded_at"])
        row.last_verified_at = None
        fields.append("ready_at")
    row.save(update_fields=fields)
    return row


@transaction.atomic
def cancel_checkin(*, owner, checkin_id):
    """Historical cancel route now pauses; leaving never destroys same-walk work."""
    owner = _owner_lock(owner)
    row = CheckIn.objects.select_for_update().select_related("walk_context", "venue", "point_entry").filter(pk=checkin_id, owner=owner).first()
    if row is None:
        raise NotFound("Check-in not found.")
    row.last_verified_at = None
    row.save(update_fields=("last_verified_at", "updated_at"))
    return row


def daily_activity_points(owner, day):
    return PointEntry.objects.filter(user=owner, type=PointEntry.Type.EARN, earned_on=day,
        earn_category__in=("WALK", "CHECK_IN", "DAILY_GOAL", "NET_WALK")
    ).aggregate(total=Sum("amount"))["total"] or 0


def current_progress(*, owner, walk_request_id=None, now=None):
    now = now or timezone.now()
    day = local_date(now)
    contexts = CheckInWalk.objects.filter(owner=owner)
    context = (contexts.filter(request_id=walk_request_id).first() if walk_request_id
               else contexts.filter(state__in=("RECORDING", "PAUSED")).order_by("-started_at").first())
    visible = Q(point_entry__isnull=False, local_date=day)
    if context and not context.settled_at and context.state != "CANCELLED":
        visible |= Q(walk_context=context)
    rows = CheckIn.objects.filter(owner=owner).filter(visible).select_related(
        "venue", "point_entry", "walk_context").order_by("started_at", "id")
    return {"local_date": day, "server_time": now, "earned_points_today": daily_activity_points(owner, day),
            "items": list(rows), "context": context, "rewarded_categories": _rewarded_categories(owner, day)}


@transaction.atomic
def settle_walk_checkins(walk, *, now=None):
    """Called inside create_walk's owner-locked transaction; once per upload."""
    owner = _owner_lock(walk.owner)
    context = CheckInWalk.objects.select_for_update().filter(owner=owner, request_id=walk.request_id).first()
    if context is None:
        return
    if context.started_at != walk.started_at or (context.walk_id and context.walk_id != walk.pk):
        raise WalkConflictError("The uploaded walk does not match its venue context.")
    if context.settled_at:
        return
    now = now or timezone.now()
    rows = list(context.checkins.select_for_update().select_related("venue", "point_entry").order_by("ready_at", "id"))
    rewarded = _rewarded_categories(owner, walk.point_date)
    enabled = _checkin_enabled() and context.state != "CANCELLED"
    for row in rows:
        if row.point_entry_id or not row.ready_at:
            continue
        if row.started_at < walk.started_at or row.ready_at > walk.ended_at:
            raise ValidationError({"code": "CHECKIN_OUTSIDE_WALK", "message": "The submitted walk must cover its completed venue visits."})
        if (not enabled or row.category_slot in rewarded or not _venue_eligible(row.venue)
                or row.verified_seconds < row.required_seconds
                or DAILY_ACTIVITY_CAP - daily_activity_points(owner, walk.point_date) < row.promised_points):
            continue
        row.point_entry = credit_points(
            user=owner, amount=row.promised_points, type=PointEntry.Type.EARN,
            source_reference=f"venue-walk:{owner.pk}:{walk.point_date}:{row.category_slot}",
            earn_category="CHECK_IN", earned_on=walk.point_date, rules_version=row.rules_version,
        )
        row.local_date = walk.point_date
        row.collected_at = now
        row.last_verified_at = None
        row.save(update_fields=("point_entry", "local_date", "collected_at", "last_verified_at", "updated_at"))
        rewarded.add(row.category_slot)
    context.walk = walk
    context.state = "FINISHED"
    context.ended_at = walk.ended_at
    context.settled_at = now
    context.save(update_fields=("walk", "state", "ended_at", "settled_at"))
    context.checkins.update(last_verified_at=None)


@transaction.atomic
def collect_checkin(*, owner, checkin_id, now=None):
    """Read a settled receipt only. Map/Quest cannot settle ahead of Walk upload."""
    owner = _owner_lock(owner)
    row = CheckIn.objects.select_related("point_entry", "venue", "walk_context").filter(pk=checkin_id, owner=owner).first()
    if row is None:
        raise Http404
    if not row.point_entry_id:
        raise ValidationError({"code": "FINISH_WALK_REQUIRED", "message": "Finish and save your walk to settle venue points."})
    return {"check_in": row, "awarded_points": row.point_entry.amount, "wallet_balance": get_balance(owner),
            "daily_earned_points": daily_activity_points(owner, row.local_date), "local_date": row.local_date}
