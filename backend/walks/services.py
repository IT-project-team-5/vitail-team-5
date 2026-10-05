"""Small, server-authoritative manual-walk award path.

Raw GPS exists only during validation. Persisted summaries and the canonical
point ledger share one owner-locked transaction; no offline upload queue or
goal/check-in/streak awards are introduced here.
"""
import hashlib
import json
import math
from dataclasses import dataclass
from datetime import UTC, timedelta
from decimal import Decimal, ROUND_DOWN
from zoneinfo import ZoneInfo

from django.contrib.auth import get_user_model
from django.db import transaction
from django.db.models import Sum
from django.utils import timezone
from rest_framework.exceptions import ValidationError

from dogs.models import Dog
from rewards.models import PointEntry
from rewards.policy import DAILY_ACTIVITY_CAP
from rewards.services import credit_points

from .models import Walk, WalkDog, WalkSession, NetWalkInterval


POINTS_PER_KM = 8
MAX_DAILY_WALK_POINTS = 40
MAX_WALK_SPEED_MPS = 3.0
MAX_ACCURACY_M = 30.0
MAX_SAMPLE_GAP_SECONDS = 60
INACTIVITY_SECONDS = 300
MAX_WALK_AGE = timedelta(hours=12)
CLOCK_SKEW = timedelta(seconds=30)
WALK_RULES_VERSION = "walk-gps-v2"
MELBOURNE = ZoneInfo("Australia/Melbourne")


class WalkConflictError(Exception):
    pass


def distance_between(first, second):
    """Haversine metres, clamped for floating-point rounding at the poles."""
    lat1, lat2 = math.radians(first["latitude"]), math.radians(second["latitude"])
    delta_lat = lat2 - lat1
    delta_lon = math.radians(second["longitude"] - first["longitude"])
    haversine = (
        math.sin(delta_lat / 2) ** 2
        + math.cos(lat1) * math.cos(lat2) * math.sin(delta_lon / 2) ** 2
    )
    return 6_371_000 * 2 * math.asin(math.sqrt(min(1.0, max(0.0, haversine))))


@dataclass(frozen=True)
class ValidatedActivity:
    distance_m: Decimal
    active_seconds: int
    accepted_segments: int


def validated_activity(*, started_at, ended_at, samples):
    # Elapsed GPS time is absolute time, including the skipped/repeated hour
    # when Melbourne changes daylight saving. Keep receipt/fingerprint inputs
    # unchanged; only validation arithmetic uses UTC.
    started_at = started_at.astimezone(UTC)
    ended_at = ended_at.astimezone(UTC)
    samples = [{**sample, "recorded_at": sample["recorded_at"].astimezone(UTC)} for sample in samples]
    now = timezone.now().astimezone(UTC)
    if ended_at <= started_at:
        raise ValidationError({"ended_at": "A walk must end after it starts."})
    if started_at < now - MAX_WALK_AGE or ended_at - started_at > MAX_WALK_AGE:
        raise ValidationError({"started_at": "Submit a walk within 12 hours of starting it."})
    if started_at > now + CLOCK_SKEW or ended_at > now + CLOCK_SKEW:
        raise ValidationError({"ended_at": "Walk times cannot be in the future."})

    previous_time = None
    previous_segment = 0
    accurate = []
    for sample in samples:
        segment = sample.get("segment_id", 0)
        if (previous_time is None and segment != 0) or segment not in (previous_segment, previous_segment + 1):
            raise ValidationError({"samples": "Segments must start at zero and increase consecutively."})
        previous_segment = segment
        recorded_at = sample["recorded_at"]
        if sample["is_simulated"]:
            raise ValidationError({"code": "SIMULATED_LOCATION", "message": "Simulated locations cannot earn walking points."})
        if not started_at <= recorded_at <= ended_at:
            raise ValidationError({"samples": "Every GPS sample must be inside the walk's start/end times."})
        if previous_time is not None and recorded_at <= previous_time:
            raise ValidationError({"samples": "GPS sample times must be strictly increasing."})
        previous_time = recorded_at
        if sample["accuracy_m"] <= MAX_ACCURACY_M:
            accurate.append(sample)
    if len(accurate) < 2:
        raise ValidationError({"samples": "At least two GPS readings with accuracy within 30 metres are required."})

    distance = 0.0
    active_seconds = 0.0
    accepted_segments = 0
    previous = None
    last_movement_at = accurate[0]["recorded_at"]
    for sample in samples:
        if sample["accuracy_m"] > MAX_ACCURACY_M:
            previous = None
            continue
        if (sample["recorded_at"] - last_movement_at).total_seconds() >= INACTIVITY_SECONDS:
            break
        if previous is None:
            previous = sample
            continue
        if sample.get("segment_id", 0) != previous.get("segment_id", 0):
            # Pause, recovery and GPS interruptions never earn bridging distance.
            # Do not reset last_movement_at: the five-minute inactivity rule still applies.
            previous = sample
            continue
        seconds = (sample["recorded_at"] - previous["recorded_at"]).total_seconds()
        if seconds >= INACTIVITY_SECONDS:
            break
        if seconds > MAX_SAMPLE_GAP_SECONDS:
            # No straight-line distance credit through missing GPS signal.
            previous = sample
            continue
        segment = distance_between(previous, sample)
        if segment / seconds > MAX_WALK_SPEED_MPS:
            # Drop this segment, then begin from the new anchor. Do not bridge
            # across driving or an impossible jump on the following sample.
            previous = sample
            continue
        distance += segment
        if segment >= 1.0:
            # Only validated moving intervals count. Explicit pauses, GPS gaps,
            # rejected speeds and stationary samples never become exercise time.
            active_seconds += seconds
            accepted_segments += 1
            last_movement_at = sample["recorded_at"]
        previous = sample
    return ValidatedActivity(
        distance_m=Decimal(str(distance)).quantize(Decimal("0.01"), rounding=ROUND_DOWN),
        active_seconds=math.floor(active_seconds),
        accepted_segments=accepted_segments,
    )


def validated_distance(**kwargs):
    """Compatibility for distance-only callers; duration uses the same validator."""
    return validated_activity(**kwargs).distance_m


def request_fingerprint(*, started_at, ended_at, dog_ids, samples):
    payload = {
        "started_at": started_at.isoformat(),
        "ended_at": ended_at.isoformat(),
        "dog_ids": sorted(dog_ids),
        "samples": [
            {**{key: value for key, value in sample.items() if key != "segment_id" or value != 0},
             "recorded_at": sample["recorded_at"].isoformat()}
            for sample in samples
        ],
    }
    return hashlib.sha256(json.dumps(payload, sort_keys=True).encode()).hexdigest()


def points_for_daily_distance(distance_m):
    """Single policy point: floor cumulative daily kilometres × 8, max 40."""
    return min(MAX_DAILY_WALK_POINTS, int(distance_m * POINTS_PER_KM / 1000))


@transaction.atomic
def create_walk(*, owner, request_id, started_at, ended_at, dog_ids, samples):
    owner = get_user_model().objects.select_for_update().get(pk=owner.pk)
    if owner.role != owner.Role.OWNER or not owner.is_active or owner.deleted_at:
        raise ValidationError("Only active dog owners can record walks.")
    fingerprint = request_fingerprint(
        started_at=started_at, ended_at=ended_at, dog_ids=dog_ids, samples=samples
    )
    existing = Walk.objects.filter(owner=owner, request_id=request_id).first()
    if existing is not None:
        if existing.request_fingerprint != fingerprint:
            raise WalkConflictError("This request ID was already used for a different walk.")
        return existing

    dogs = list(Dog.objects.select_for_update().filter(owner=owner, pk__in=dog_ids).order_by("pk"))
    if len(dogs) != len(dog_ids):
        raise ValidationError({"dog_ids": "Choose only dogs belonging to your account."})
    if Walk.objects.filter(owner=owner, started_at__lt=ended_at, ended_at__gt=started_at).exists():
        raise ValidationError({"started_at": "This walk overlaps one already submitted."})
    activity = validated_activity(started_at=started_at, ended_at=ended_at, samples=samples)
    distance_m = activity.distance_m
    point_date = timezone.localdate(ended_at, timezone=MELBOURNE)
    daily = Walk.objects.filter(owner=owner, point_date=point_date).aggregate(
        distance=Sum("distance_m"), awarded=Sum("points_awarded")
    )
    daily_distance = (daily["distance"] or Decimal(0)) + distance_m
    points_awarded = max(0, points_for_daily_distance(daily_distance) - (daily["awarded"] or 0))
    from checkins.services import daily_activity_points
    points_awarded = min(points_awarded, max(0, DAILY_ACTIVITY_CAP - daily_activity_points(owner, point_date)))
    walk = Walk.objects.create(
        owner=owner, request_id=request_id, request_fingerprint=fingerprint,
        started_at=started_at, ended_at=ended_at, point_date=point_date,
        distance_m=distance_m, points_awarded=points_awarded,
        active_seconds=activity.active_seconds, rules_version=WALK_RULES_VERSION,
        validation_summary={"accepted_moving_segments": activity.accepted_segments},
    )
    WalkDog.objects.bulk_create([
        WalkDog(walk=walk, dog=dog, dog_id_snapshot=dog.pk, dog_name_snapshot=dog.name,
                active_seconds=activity.active_seconds, distance_m=distance_m)
        for dog in dogs
    ])
    if points_awarded:
        walk.base_point_entry = credit_points(
            user=owner, amount=points_awarded, type=PointEntry.Type.EARN,
            source_reference=f"walk:{walk.pk}",
            earn_category="WALK", earned_on=point_date, rules_version=WALK_RULES_VERSION,
        )
        walk.save(update_fields=["base_point_entry"])
    return walk


@transaction.atomic
def start_walk_session(*, owner, request_id, started_at, validation_version):
    """Internal foundation only; existing manual uploads do not create sessions."""
    owner = get_user_model().objects.select_for_update().get(pk=owner.pk)
    if not owner.is_active or owner.deleted_at or owner.role != "OWNER":
        raise ValidationError("Only active owners can start walk sessions.")
    if not validation_version or started_at > timezone.now() + CLOCK_SKEW:
        raise ValidationError("A session needs a validation version and valid start time.")
    existing = WalkSession.objects.filter(owner=owner, request_id=request_id).first()
    if existing:
        if existing.started_at != started_at or existing.validation_version != validation_version:
            raise WalkConflictError("This request ID was already used for another session.")
        return existing
    if owner.active_walk_session_id:
        raise WalkConflictError("An active walk session already exists.")
    session = WalkSession.objects.create(
        owner=owner, request_id=request_id, started_at=started_at,
        heartbeat_at=timezone.now(), state=WalkSession.State.RECORDING,
        validation_version=validation_version,
    )
    owner.active_walk_session = session
    owner.save(update_fields=("active_walk_session",))
    return session


@transaction.atomic
def transition_walk_session(*, owner, session_id, state, at=None):
    owner = get_user_model().objects.select_for_update().get(pk=owner.pk)
    session = WalkSession.objects.select_for_update().filter(pk=session_id, owner=owner).first()
    if session is None:
        raise ValidationError("This walk session is unavailable.")
    active = (WalkSession.State.RECORDING, WalkSession.State.PAUSED)
    terminal = (WalkSession.State.FINISHED, WalkSession.State.TIMED_OUT, WalkSession.State.CANCELLED)
    if state in active and (not owner.is_active or owner.deleted_at or owner.role != "OWNER"):
        raise ValidationError("Only active owners can record a walk session.")
    if state == session.state:
        return session
    if session.state not in active or state not in (*active, *terminal) or owner.active_walk_session_id != session.pk:
        raise WalkConflictError("This walk session cannot make that transition.")
    at = at or timezone.now()
    if at < max(session.started_at, session.heartbeat_at) or at > timezone.now() + CLOCK_SKEW:
        raise ValidationError("Invalid session transition time.")
    session.state = state
    session.heartbeat_at = at
    # Pause/stop removes presence immediately; resume needs a fresh GPS sample.
    session.last_latitude = session.last_longitude = session.last_accuracy_m = None
    session.location_recorded_at = session.location_expires_at = None
    if state in terminal:
        session.ended_at = at
        owner.active_walk_session = None
        owner.save(update_fields=("active_walk_session",))
    session.full_clean()
    session.save()
    return session


@transaction.atomic
def store_verified_net_interval(*, first_session_id, second_session_id, started_at, ended_at,
                                first_distance_m, second_distance_m, rules_version,
                                validation_summary):
    """Persist a verifier's result safely; never infer a match or award points.

    No caller/API is enabled until proximity, consent and retention policy exist.
    Owner locks and session locks serialize overlap checks and later settlement.
    """
    from social.services import is_blocked

    ids = sorted((first_session_id, second_session_id))
    if ids[0] == ids[1] or not rules_version:
        raise ValidationError("A versioned match requires two different sessions.")
    owner_ids = list(WalkSession.objects.filter(pk__in=ids).values_list("owner_id", flat=True))
    if len(set(owner_ids)) != 2:
        raise ValidationError("A match requires two different owners.")
    owners = list(get_user_model().objects.select_for_update().filter(pk__in=owner_ids).order_by("pk"))
    if any(not owner.is_active or owner.deleted_at or owner.role != "OWNER" for owner in owners) or is_blocked(*owner_ids):
        raise ValidationError("This match is unavailable.")
    sessions = list(WalkSession.objects.select_for_update().filter(pk__in=ids).order_by("pk"))
    if len(sessions) != 2:
        raise ValidationError("The sessions are unavailable.")
    if any(session.walk_id and session.walk.net_settled_at is not None for session in sessions):
        raise WalkConflictError("Net-walking for this session is already settled.")
    distances = {first_session_id: first_distance_m, second_session_id: second_distance_m}
    existing = NetWalkInterval.objects.filter(session_low=sessions[0], session_high=sessions[1], started_at=started_at, ended_at=ended_at).first()
    if existing:
        if (existing.low_distance_m, existing.high_distance_m, existing.rules_version, existing.validation_summary) != (distances[ids[0]], distances[ids[1]], rules_version, validation_summary):
            raise WalkConflictError("This verified interval was already stored with different data.")
        return existing
    interval = NetWalkInterval(
        session_low=sessions[0], session_high=sessions[1], started_at=started_at, ended_at=ended_at,
        low_distance_m=distances[ids[0]], high_distance_m=distances[ids[1]],
        rules_version=rules_version, validation_summary=validation_summary, verified_at=timezone.now(),
    )
    interval.full_clean()
    interval.save()
    return interval
