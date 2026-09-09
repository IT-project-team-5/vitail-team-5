"""Small, server-authoritative manual-walk award path.

Raw GPS exists only during validation. Persisted summaries and the canonical
point ledger share one owner-locked transaction; no offline upload queue or
goal/check-in/streak awards are introduced here.
"""
import hashlib
import json
import math
from datetime import timedelta
from decimal import Decimal, ROUND_DOWN

from django.contrib.auth import get_user_model
from django.db import transaction
from django.db.models import Sum
from django.utils import timezone
from rest_framework.exceptions import ValidationError

from dogs.models import Dog
from rewards.models import PointEntry
from rewards.services import credit_points

from .models import Walk


POINTS_PER_KM = 8
MAX_DAILY_WALK_POINTS = 40
MAX_WALK_SPEED_MPS = 3.0
MAX_ACCURACY_M = 30.0
MAX_SAMPLE_GAP_SECONDS = 60
INACTIVITY_SECONDS = 300
MAX_WALK_AGE = timedelta(hours=12)
CLOCK_SKEW = timedelta(seconds=30)


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


def validated_distance(*, started_at, ended_at, samples):
    now = timezone.now()
    if ended_at <= started_at:
        raise ValidationError({"ended_at": "A walk must end after it starts."})
    if started_at < now - MAX_WALK_AGE or ended_at - started_at > MAX_WALK_AGE:
        raise ValidationError({"started_at": "Submit a walk within 12 hours of starting it."})
    if started_at > now + CLOCK_SKEW or ended_at > now + CLOCK_SKEW:
        raise ValidationError({"ended_at": "Walk times cannot be in the future."})

    previous_time = None
    accurate = []
    for sample in samples:
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
            last_movement_at = sample["recorded_at"]
        previous = sample
    return Decimal(str(distance)).quantize(Decimal("0.01"), rounding=ROUND_DOWN)


def request_fingerprint(*, started_at, ended_at, dog_ids, samples):
    payload = {
        "started_at": started_at.isoformat(),
        "ended_at": ended_at.isoformat(),
        "dog_ids": sorted(dog_ids),
        "samples": [
            {**sample, "recorded_at": sample["recorded_at"].isoformat()}
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
    if owner.role != owner.Role.OWNER:
        raise ValidationError("Only dog owners can record walks.")
    fingerprint = request_fingerprint(
        started_at=started_at, ended_at=ended_at, dog_ids=dog_ids, samples=samples
    )
    existing = Walk.objects.filter(owner=owner, request_id=request_id).first()
    if existing is not None:
        if existing.request_fingerprint != fingerprint:
            raise WalkConflictError("This request ID was already used for a different walk.")
        return existing

    dogs = list(Dog.objects.filter(owner=owner, pk__in=dog_ids))
    if len(dogs) != len(dog_ids):
        raise ValidationError({"dog_ids": "Choose only dogs belonging to your account."})
    if Walk.objects.filter(owner=owner, started_at__lt=ended_at, ended_at__gt=started_at).exists():
        raise ValidationError({"started_at": "This walk overlaps one already submitted."})
    distance_m = validated_distance(started_at=started_at, ended_at=ended_at, samples=samples)
    point_date = timezone.localdate(ended_at)
    daily = Walk.objects.filter(owner=owner, point_date=point_date).aggregate(
        distance=Sum("distance_m"), awarded=Sum("points_awarded")
    )
    daily_distance = (daily["distance"] or Decimal(0)) + distance_m
    points_awarded = max(0, points_for_daily_distance(daily_distance) - (daily["awarded"] or 0))
    walk = Walk.objects.create(
        owner=owner, request_id=request_id, request_fingerprint=fingerprint,
        started_at=started_at, ended_at=ended_at, point_date=point_date,
        distance_m=distance_m, points_awarded=points_awarded,
    )
    walk.dogs.set(dogs)
    if points_awarded:
        credit_points(
            user=owner, amount=points_awarded, type=PointEntry.Type.EARN,
            source_reference=f"walk:{walk.pk}",
        )
    return walk
