"""Live owner presence and explicitly accepted Net-Walking pairs.

GPS is a short-lived verification buffer, never a returned route. The server
checks sample freshness, walking speed, paired time overlap and proximity.
The unsettled client policy is represented by a disabled wallet feature flag.
"""
from datetime import timedelta
from decimal import Decimal, ROUND_DOWN

from django.conf import settings
from django.contrib.auth import get_user_model
from django.db import transaction
from django.db.models import Q, Sum
from django.utils import timezone
from rest_framework.exceptions import NotFound, ValidationError

from rewards.models import PointEntry
from rewards.policy import DAILY_ACTIVITY_CAP
from rewards.services import credit_points
from walks.models import LocationSample, NetWalkInterval, WalkSession
from walks.services import CLOCK_SKEW, MAX_ACCURACY_M, MAX_SAMPLE_GAP_SECONDS, MAX_WALK_AGE, MAX_WALK_SPEED_MPS, WalkConflictError, distance_between, start_walk_session, transition_walk_session

from .models import NetWalkInvitation
from .services import is_blocked

LIVE_RULES_VERSION = "social-gps-v1"
OPEN_STATUSES = (NetWalkInvitation.Status.PENDING, NetWalkInvitation.Status.ACTIVE)
ACTIVE_STATES = (WalkSession.State.RECORDING, WalkSession.State.PAUSED)


def active_owners():
    return get_user_model().objects.filter(role="OWNER", is_active=True, deleted_at__isnull=True)


def blocked_ids(owner_id):
    from .models import UserBlock
    rows = UserBlock.objects.filter(Q(blocker_id=owner_id) | Q(blocked_id=owner_id))
    return {row.blocked_id if row.blocker_id == owner_id else row.blocker_id for row in rows}


def public_owner(public_id, *, actor, allow_blocked=False):
    user = active_owners().filter(public_id=public_id).first()
    if user is None or user.pk == actor.pk or (not allow_blocked and is_blocked(actor.pk, user.pk)):
        raise NotFound("This owner is unavailable.")
    return user


def _lock_owners(ids):
    users = list(active_owners().select_for_update().filter(pk__in=ids).order_by("pk"))
    if len(users) != len(set(ids)):
        raise NotFound("This owner is unavailable.")
    return {user.pk: user for user in users}


def invitations_for(user_id):
    return NetWalkInvitation.objects.filter(Q(sender_id=user_id) | Q(recipient_id=user_id))


def _withdraw_sessions(session_ids, at):
    if session_ids:
        WalkSession.objects.filter(pk__in=session_ids, net_consent_at__isnull=False).update(net_consent_withdrawn_at=at)


def end_pair_invitations(first_id, second_id, *, reason):
    rows = NetWalkInvitation.objects.filter(
        Q(sender_id=first_id, recipient_id=second_id) | Q(sender_id=second_id, recipient_id=first_id),
        status__in=OPEN_STATUSES,
    )
    ids = {pk for pair in rows.filter(status="ACTIVE").values_list("sender_session_id", "recipient_session_id") for pk in pair}
    now = timezone.now()
    rows.update(status="ENDED", ended_at=now, end_reason=reason)
    _withdraw_sessions(ids, now)


def end_owner_invitations(owner_id, *, reason):
    rows = invitations_for(owner_id).filter(status__in=OPEN_STATUSES)
    ids = {pk for pair in rows.filter(status="ACTIVE").values_list("sender_session_id", "recipient_session_id") for pk in pair}
    now = timezone.now()
    rows.update(
        status="ENDED", ended_at=now, end_reason=reason,
    )
    # A single-owner stop may race the other owner's stop. Update only this
    # owner's session here; crossing session locks would invert that ordering.
    # One withdrawn consent plus the ended invitation invalidates the pair.
    own_ids = list(WalkSession.objects.filter(pk__in=ids, owner_id=owner_id).values_list("id", flat=True))
    _withdraw_sessions(own_ids, now)


def fresh_presence(session, now=None):
    now = now or timezone.now()
    owner = session.owner
    return bool(
        owner.is_active and not owner.deleted_at and owner.role == "OWNER"
        and owner.active_walk_session_id == session.pk
        and session.state == "RECORDING"
        and session.last_latitude is not None and session.last_longitude is not None
        and session.location_recorded_at and session.location_recorded_at <= now + CLOCK_SKEW
        and session.location_expires_at and session.location_expires_at > now
        and session.heartbeat_at > now - timedelta(seconds=settings.SOCIAL_PRESENCE_TTL_SECONDS)
    )


def _match_available(session, now):
    return session.owner.net_matching_enabled and fresh_presence(session, now)


def refresh_invitations(user_id, *, now=None):
    """Expire consent when either participant becomes unavailable."""
    now = now or timezone.now()
    rows = invitations_for(user_id).filter(status__in=OPEN_STATUSES).select_related(
        "sender_session__owner", "recipient_session__owner",
    )
    for row in rows:
        reason = None
        if row.status == "PENDING" and row.expires_at <= now:
            reason = "invitation_expired"
        elif is_blocked(row.sender_id, row.recipient_id):
            reason = "blocked"
        elif not all(_match_available(session, now) for session in (row.sender_session, row.recipient_session)):
            reason = "presence_unavailable"
        if reason:
            changed = NetWalkInvitation.objects.filter(pk=row.pk, status__in=OPEN_STATUSES).update(
                status="EXPIRED" if row.status == "PENDING" else "ENDED",
                ended_at=now, end_reason=reason,
            )
            if changed and row.status == "ACTIVE":
                _withdraw_sessions((row.sender_session_id if row.sender_id == user_id else row.recipient_session_id,), now)


def active_invitation(user_id):
    return invitations_for(user_id).filter(status="ACTIVE").select_related(
        "sender", "recipient", "sender_session", "recipient_session",
    ).order_by("id").first()


@transaction.atomic
def current_session(owner):
    owner = _lock_owners([owner.pk])[owner.pk]
    if not owner.active_walk_session_id:
        return None
    session = WalkSession.objects.select_for_update().select_related("owner").get(pk=owner.active_walk_session_id)
    if session.state not in ACTIVE_STATES:
        owner.active_walk_session = None
        owner.save(update_fields=("active_walk_session",))
        return None
    if session.heartbeat_at < timezone.now() - timedelta(minutes=5):
        transition_walk_session(owner=owner, session_id=session.pk, state="TIMED_OUT")
        end_owner_invitations(owner.pk, reason="session_timed_out")
        session.samples.all().delete()
        return None
    return session


@transaction.atomic
def start_session(*, owner, request_id, started_at):
    now = timezone.now()
    if started_at < now - MAX_WALK_AGE or started_at > now + CLOCK_SKEW:
        raise ValidationError({"started_at": "Start a current walk within the last twelve hours."})
    current_session(owner)
    owner = _lock_owners([owner.pk])[owner.pk]
    session = start_walk_session(owner=owner, request_id=request_id, started_at=started_at, validation_version=LIVE_RULES_VERSION)
    if session.state == "TIMED_OUT" and session.walk_id is None:
        if owner.active_walk_session_id:
            raise WalkConflictError("Another walk session is already active.")
        session.state = "RECORDING"
        session.ended_at = None
        session.heartbeat_at = now
        _clear_presence(session)
        session.save()
        owner.active_walk_session = session
        owner.save(update_fields=("active_walk_session",))
    return session


@transaction.atomic
def update_session_state(*, owner, session_id, state):
    session = transition_walk_session(owner=owner, session_id=session_id, state=state)
    if state != "RECORDING":
        end_owner_invitations(owner.pk, reason="walk_paused" if state == "PAUSED" else "walk_ended")
        session.samples.all().delete()
    return session


@transaction.atomic
def update_preferences(*, owner, **values):
    owner = _lock_owners([owner.pk])[owner.pk]
    for key, value in values.items():
        setattr(owner, key, value)
    if values:
        owner.save(update_fields=tuple(values))
    if values.get("net_matching_enabled") is False:
        end_owner_invitations(owner.pk, reason="matching_disabled")
        if owner.active_walk_session_id:
            WalkSession.objects.filter(pk=owner.active_walk_session_id, net_consent_at__isnull=False).update(net_consent_withdrawn_at=timezone.now())
    return owner


@transaction.atomic
def send_invitation(*, sender, recipient):
    users = _lock_owners([sender.pk, recipient.pk])
    sender, recipient = users[sender.pk], users[recipient.pk]
    if is_blocked(sender.pk, recipient.pk):
        raise NotFound("This owner is unavailable.")
    now = timezone.now()
    refresh_invitations(sender.pk, now=now)
    refresh_invitations(recipient.pk, now=now)
    sessions = list(WalkSession.objects.select_for_update().select_related("owner").filter(
        pk__in=(sender.active_walk_session_id, recipient.active_walk_session_id),
    ).order_by("pk"))
    by_owner = {session.owner_id: session for session in sessions}
    if len(by_owner) != 2 or not all(_match_available(session, now) for session in sessions):
        raise ValidationError({"code": "WALKERS_UNAVAILABLE", "message": "Both owners must enable Net-Walking and have fresh locations on an active walk."})
    first, second = by_owner[sender.pk], by_owner[recipient.pk]
    if distance_between(_coordinates(first), _coordinates(second)) > settings.SOCIAL_NEARBY_RADIUS_M:
        raise ValidationError("Choose a nearby walker within two kilometres.")
    same = NetWalkInvitation.objects.filter(sender=sender, recipient=recipient, sender_session=first, recipient_session=second, status__in=OPEN_STATUSES).first()
    if same:
        return same
    if invitations_for(sender.pk).filter(status__in=OPEN_STATUSES).exists() or invitations_for(recipient.pk).filter(status__in=OPEN_STATUSES).exists():
        raise WalkConflictError("One participant already has a Net-Walking invitation or partner. End it before inviting someone else.")
    return NetWalkInvitation.objects.create(
        sender=sender, recipient=recipient, sender_session=first, recipient_session=second,
        expires_at=now + timedelta(minutes=2),
    )


@transaction.atomic
def respond_invitation(*, actor, invitation_id, accept):
    row = invitations_for(actor.pk).filter(pk=invitation_id).first()
    if row is None or row.recipient_id != actor.pk:
        raise NotFound("Only the invited owner can answer this invitation.")
    _lock_owners([row.sender_id, row.recipient_id])
    refresh_invitations(actor.pk)
    row = NetWalkInvitation.objects.select_for_update().select_related("sender_session__owner", "recipient_session__owner").get(pk=row.pk)
    desired = "ACTIVE" if accept else "DECLINED"
    if row.status == desired:
        return row
    if row.status != "PENDING":
        raise WalkConflictError("This invitation is no longer pending.")
    now = timezone.now()
    if accept:
        if is_blocked(row.sender_id, row.recipient_id) or not all(_match_available(s, now) for s in (row.sender_session, row.recipient_session)):
            raise ValidationError("Both walkers must be available before accepting.")
        if distance_between(_coordinates(row.sender_session), _coordinates(row.recipient_session)) > settings.SOCIAL_NEARBY_RADIUS_M:
            raise ValidationError("The other walker is no longer nearby.")
        row.accepted_at = now
        WalkSession.objects.filter(pk__in=(row.sender_session_id, row.recipient_session_id)).update(
            net_consent_at=now, net_consent_withdrawn_at=None,
        )
    else:
        row.ended_at = now
    row.status = desired
    row.save(update_fields=("status", "accepted_at", "ended_at"))
    return row


@transaction.atomic
def end_invitation(*, actor, invitation_id):
    row = invitations_for(actor.pk).filter(pk=invitation_id).first()
    if row is None:
        raise NotFound("This invitation is unavailable.")
    _lock_owners([row.sender_id, row.recipient_id])
    row = NetWalkInvitation.objects.select_for_update().get(pk=row.pk)
    if row.status in OPEN_STATUSES:
        was_active = row.status == "ACTIVE"
        row.status = "ENDED" if row.status == "ACTIVE" else "CANCELLED"
        row.ended_at = timezone.now()
        row.end_reason = "owner_ended"
        row.save(update_fields=("status", "ended_at", "end_reason"))
        if was_active:
            _withdraw_sessions((row.sender_session_id, row.recipient_session_id), row.ended_at)
    return row


def _coordinates(value):
    return {"latitude": float(value.last_latitude), "longitude": float(value.last_longitude)}


def _sample_coordinates(value):
    return {"latitude": float(value.latitude), "longitude": float(value.longitude)}


def _clear_presence(session):
    session.last_latitude = session.last_longitude = session.last_accuracy_m = None
    session.location_recorded_at = session.location_expires_at = None


@transaction.atomic
def report_presence(*, owner, session_id, **sample):
    now = timezone.now()
    candidate = active_invitation(owner.pk)
    locked_ids = {owner.pk}
    if candidate:
        locked_ids.update((candidate.sender_id, candidate.recipient_id))
    users = _lock_owners(locked_ids)
    owner = users[owner.pk]
    session = WalkSession.objects.select_for_update().select_related("owner").filter(pk=session_id, owner=owner).first()
    if session is None:
        raise NotFound("This walk session is unavailable.")
    if session.state != "RECORDING" or owner.active_walk_session_id != session.pk:
        raise WalkConflictError("Resume an active walk before updating its location.")
    stamp = sample["recorded_at"]
    if stamp < session.started_at or stamp > now + timedelta(seconds=5) or stamp < now - timedelta(seconds=settings.SOCIAL_PRESENCE_TTL_SECONDS):
        raise ValidationError({"code": "STALE_LOCATION", "message": "Use a fresh GPS reading from this walk."})
    previous = session.samples.order_by("-sequence").first()
    if previous and stamp <= previous.recorded_at:
        same = stamp == previous.recorded_at and all(round(float(getattr(previous, key)), 2 if key == "accuracy_m" else 6) == round(float(sample[key]), 2 if key == "accuracy_m" else 6) for key in ("latitude", "longitude", "accuracy_m")) and bool(previous.source_flags.get("is_simulated")) == sample["is_simulated"]
        if same:
            return session, previous.rejection_reason or None
        raise WalkConflictError("GPS readings must have increasing times; an existing reading cannot be replaced.")
    if previous and (now - previous.received_at).total_seconds() < settings.SOCIAL_MIN_SAMPLE_SECONDS:
        # Bound the evidence stream at the server, not just the device. A
        # refused update interrupts eligibility rather than bridging its gap.
        _clear_presence(session)
        session.save(update_fields=("last_latitude", "last_longitude", "last_accuracy_m", "location_recorded_at", "location_expires_at"))
        end_owner_invitations(owner.pk, reason="location_rate_limit")
        return session, "LOCATION_RATE_LIMIT"
    code = "SIMULATED_LOCATION" if sample["is_simulated"] else ("LOW_ACCURACY" if sample["accuracy_m"] > MAX_ACCURACY_M else None)
    segment_id = previous.segment_id if previous else 0
    gap = (stamp - previous.recorded_at).total_seconds() if previous else None
    bridged = bool(previous and previous.accepted and session.location_recorded_at and gap <= MAX_SAMPLE_GAP_SECONDS)
    if previous and not bridged:
        segment_id += 1
    distance = distance_between(_sample_coordinates(previous), sample) if bridged else 0
    if bridged and distance / gap > MAX_WALK_SPEED_MPS:
        code = code or "IMPLAUSIBLE_SPEED"
    row = LocationSample.objects.create(
        owner=owner, session=session, stream_id=session.request_id,
        sequence=(previous.sequence + 1) if previous else 0, segment_id=segment_id,
        recorded_at=stamp, received_at=now, latitude=sample["latitude"], longitude=sample["longitude"],
        accuracy_m=sample["accuracy_m"], source_flags={"is_simulated": sample["is_simulated"]},
        accepted=not code, rejection_reason=code or "",
    )
    session.heartbeat_at = now
    if code:
        _clear_presence(session)
    else:
        if bridged:
            session.verified_distance_m += Decimal(str(distance)).quantize(Decimal("0.01"), rounding=ROUND_DOWN)
            if distance >= 1:
                session.verified_active_seconds += int(gap)
        session.last_latitude, session.last_longitude = row.latitude, row.longitude
        session.last_accuracy_m = row.accuracy_m
        session.location_recorded_at = stamp
        session.location_expires_at = min(stamp, now) + timedelta(seconds=settings.SOCIAL_PRESENCE_TTL_SECONDS)
    session.save()
    if code:
        end_owner_invitations(owner.pk, reason="invalid_location")
    else:
        refresh_invitations(owner.pk, now=now)
        pair = active_invitation(owner.pk)
        if pair and {pair.sender_id, pair.recipient_id}.issubset(locked_ids):
            _verify_pair(pair, now=now)
    # Keep only the short rolling evidence buffer, not a stored walking route.
    LocationSample.objects.filter(session__isnull=False, received_at__lt=now - timedelta(seconds=settings.SOCIAL_GPS_RETENTION_SECONDS)).delete()
    excess_ids = list(session.samples.order_by("-sequence").values_list("id", flat=True)[settings.SOCIAL_MAX_SESSION_SAMPLES:])
    if excess_ids:
        LocationSample.objects.filter(pk__in=excess_ids).delete()
    return session, code


def _segments(session_id, since):
    rows = list(LocationSample.objects.filter(session_id=session_id).order_by("recorded_at"))
    segments = []
    for first, second in zip(rows, rows[1:]):
        gap = (second.recorded_at - first.recorded_at).total_seconds()
        if not first.accepted or not second.accepted or first.segment_id != second.segment_id or not 0 < gap <= MAX_SAMPLE_GAP_SECONDS or second.recorded_at <= since:
            continue
        metres = distance_between(_sample_coordinates(first), _sample_coordinates(second))
        if metres >= 1 and metres / gap <= MAX_WALK_SPEED_MPS:
            segments.append((first, second, metres))
    return segments


def _interpolate(first, second, at):
    fraction = (at - first.recorded_at).total_seconds() / (second.recorded_at - first.recorded_at).total_seconds()
    # Interpolate across the short, plausible segments only. Wrap longitude at
    # the antimeridian instead of creating a path around the world.
    delta_lon = (float(second.longitude) - float(first.longitude) + 180) % 360 - 180
    return {
        "latitude": float(first.latitude) + fraction * (float(second.latitude) - float(first.latitude)),
        "longitude": (float(first.longitude) + fraction * delta_lon + 180) % 360 - 180,
    }


def _verify_pair(invitation, *, now):
    ids = sorted((invitation.sender_session_id, invitation.recipient_session_id))
    sessions = list(WalkSession.objects.select_for_update().select_related("owner").filter(pk__in=ids).order_by("pk"))
    if len(sessions) != 2 or not invitation.accepted_at or not all(_match_available(s, now) for s in sessions):
        return
    latest = NetWalkInterval.objects.filter(session_low_id=ids[0], session_high_id=ids[1]).order_by("-ended_at").first()
    since = max(invitation.accepted_at, now - timedelta(seconds=settings.SOCIAL_PRESENCE_TTL_SECONDS), latest.ended_at if latest else invitation.accepted_at)
    first_segments = _segments(ids[0], since)
    second_segments = _segments(ids[1], since)
    for a, b, first_metres in first_segments:
        for c, d, second_metres in second_segments:
            start = max(a.recorded_at, c.recorded_at, since)
            end = min(b.recorded_at, d.recorded_at, now)
            if end <= start:
                continue
            if any(distance_between(_interpolate(a, b, at), _interpolate(c, d, at)) > settings.NET_WALK_RADIUS_M for at in (start, end)):
                continue
            # Locked pair owners and sessions serialize verification, including
            # updates arriving in either order. Only uncovered time can count.
            existing = list(NetWalkInterval.objects.filter(session_low_id=ids[0], session_high_id=ids[1], started_at__lt=end, ended_at__gt=start).order_by("started_at"))
            uncovered = [(start, end)]
            for old in existing:
                next_ranges = []
                for left, right in uncovered:
                    if old.ended_at <= left or old.started_at >= right:
                        next_ranges.append((left, right))
                    else:
                        if left < old.started_at:
                            next_ranges.append((left, old.started_at))
                        if old.ended_at < right:
                            next_ranges.append((old.ended_at, right))
                uncovered = next_ranges
            for left, right in uncovered:
                seconds = Decimal(str((right - left).total_seconds()))
                low_distance = (Decimal(str(first_metres)) * seconds / Decimal(str((b.recorded_at - a.recorded_at).total_seconds()))).quantize(Decimal("0.01"), rounding=ROUND_DOWN)
                high_distance = (Decimal(str(second_metres)) * seconds / Decimal(str((d.recorded_at - c.recorded_at).total_seconds()))).quantize(Decimal("0.01"), rounding=ROUND_DOWN)
                interval = NetWalkInterval(
                    session_low=sessions[0], session_high=sessions[1], started_at=left, ended_at=right,
                    low_distance_m=low_distance, high_distance_m=high_distance,
                    rules_version=LIVE_RULES_VERSION,
                    validation_summary={"invitation_id": invitation.pk, "radius_m": settings.NET_WALK_RADIUS_M, "max_speed_mps": MAX_WALK_SPEED_MPS},
                    verified_at=now,
                )
                interval.full_clean()
                interval.save()


def shared_distance(session):
    totals = NetWalkInterval.objects.filter(Q(session_low=session) | Q(session_high=session)).aggregate(
        low=Sum("low_distance_m", filter=Q(session_low=session)),
        high=Sum("high_distance_m", filter=Q(session_high=session)),
    )
    return (totals["low"] or Decimal(0)) + (totals["high"] or Decimal(0))


@transaction.atomic
def link_walk_and_settle(walk):
    """Connect a normal completed walk to its live presence by request UUID.

    The default stores verified distance with no wallet bonus. If enabled after
    rule approval, the optional award uses floor cumulative km × 2, max 10/day,
    and conservatively includes all activity sources in the shared 72 cap.
    """
    session = WalkSession.objects.select_for_update().filter(owner=walk.owner, request_id=walk.request_id).first()
    if session is None or session.started_at != walk.started_at:
        return
    if session.walk_id and session.walk_id != walk.pk:
        raise WalkConflictError("This live session belongs to another completed walk.")
    if walk.net_settled_at:
        return
    # Summaries must be covered by the submitted walk; never attach live time
    # outside its confirmed GPS-backed duration.
    intervals = NetWalkInterval.objects.filter(Q(session_low=session) | Q(session_high=session))
    if intervals.filter(Q(started_at__lt=walk.started_at) | Q(ended_at__gt=walk.ended_at)).exists():
        raise ValidationError("The submitted walk does not cover its Net-Walking intervals.")
    session.walk = walk
    session.save(update_fields=("walk",))
    if session.state in ACTIVE_STATES:
        transition_walk_session(owner=walk.owner, session_id=session.pk, state="FINISHED", at=max(walk.ended_at, session.heartbeat_at))
    end_owner_invitations(walk.owner_id, reason="walk_uploaded")
    session.samples.all().delete()
    distance = min(shared_distance(session), walk.distance_m)
    walk.net_distance_m = distance
    if settings.NET_WALK_REWARDS_ENABLED:
        day = walk.point_date
        from walks.models import Walk
        prior = Walk.objects.filter(owner=walk.owner, point_date=day, validation_summary__net_bonus_policy="enabled-v1").exclude(pk=walk.pk).aggregate(distance=Sum("net_distance_m"))
        eligible = min(10, int(((prior["distance"] or Decimal(0)) + distance) * 2 / 1000))
        awarded = PointEntry.objects.filter(user=walk.owner, earned_on=day, earn_category="NET_WALK", type="EARN").aggregate(total=Sum("amount"))["total"] or 0
        activity = PointEntry.objects.filter(user=walk.owner, earned_on=day, earn_category__in=("WALK", "CHECK_IN", "DAILY_GOAL", "NET_WALK"), type="EARN").aggregate(total=Sum("amount"))["total"] or 0
        points = max(0, min(eligible - awarded, DAILY_ACTIVITY_CAP - activity))
        if points:
            walk.net_point_entry = credit_points(
                user=walk.owner, amount=points, type="EARN", source_reference=f"net-walk:{walk.pk}",
                earn_category="NET_WALK", earned_on=day, rules_version=LIVE_RULES_VERSION,
            )
    # Finalize the default no-wallet result too. Enabling a policy later must
    # never unexpectedly backfill points when a completed upload is retried.
    walk.net_settled_at = timezone.now()
    walk.validation_summary = {**(walk.validation_summary or {}), "net_bonus_policy": "enabled-v1" if settings.NET_WALK_REWARDS_ENABLED else "awaiting_rules"}
    walk.save(update_fields=("net_distance_m", "net_point_entry", "net_settled_at", "validation_summary"))


def purge_expired_presence():
    """Run periodically alongside ordinary server maintenance."""
    now = timezone.now()
    WalkSession.objects.filter(location_expires_at__lte=now).update(
        last_latitude=None, last_longitude=None, last_accuracy_m=None,
        location_recorded_at=None, location_expires_at=None,
    )
    deleted, _ = LocationSample.objects.filter(session__isnull=False, received_at__lt=now - timedelta(seconds=settings.SOCIAL_GPS_RETENTION_SECONDS)).delete()
    for user_id in get_user_model().objects.filter(active_walk_session__isnull=False).values_list("id", flat=True):
        refresh_invitations(user_id, now=now)
    return deleted
