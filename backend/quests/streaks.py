"""Walking-day streaks derived from validated summaries, with explicit collection."""
from dataclasses import dataclass
from datetime import timedelta

from django.contrib.auth import get_user_model
from django.db import transaction
from django.utils import timezone

from rewards.models import PointEntry
from rewards.policy import local_date
from rewards.services import credit_points, get_balance
from walks.models import Walk

from .models import QuestAward, QuestDefinition

STREAK_RULES_VERSION = "streak-walk-days-2026-09-26"
# Extend deliberately when another persisted validator has equivalent evidence.
TRUSTED_WALK_RULES = ("walk-gps-v2",)


class StreakClaimError(Exception):
    def __init__(self, code, message, status_code):
        self.code, self.message, self.status_code = code, message, status_code
        super().__init__(message)


@dataclass(frozen=True)
class StreakRun:
    days: tuple

    @property
    def start(self):
        return self.days[0][0]

    @property
    def end(self):
        return self.days[-1][0]

    @property
    def count(self):
        return len(self.days)


def valid_milestone(value):
    return type(value) is int and (value == 7 or value > 0 and value % 30 == 0)


def _runs(owner, now):
    days = {}
    walks = Walk.objects.filter(
        owner=owner, ended_at__lte=now, distance_m__gt=0, active_seconds__gt=0,
        rules_version__in=TRUSTED_WALK_RULES,
    ).values("point_date", "started_at", "ended_at", "active_seconds", "validation_summary").order_by("ended_at", "pk")
    for walk in walks.iterator():
        summary = walk["validation_summary"]
        moving = summary.get("accepted_moving_segments") if isinstance(summary, dict) else None
        if type(moving) is not int or moving <= 0:
            continue
        if not 0 < walk["active_seconds"] <= (walk["ended_at"] - walk["started_at"]).total_seconds():
            continue
        day = walk["point_date"]
        if day != local_date(walk["ended_at"]):
            continue
        # Credit uses the end's Melbourne day; repeated walks never add a day.
        days.setdefault(day, walk["ended_at"])
    runs, current = [], []
    for day, ended_at in sorted(days.items()):
        if current and day != current[-1][0] + timedelta(days=1):
            runs.append(StreakRun(tuple(current)))
            current = []
        current.append((day, ended_at))
    if current:
        runs.append(StreakRun(tuple(current)))
    return runs


def _projection(owner, now):
    runs = _runs(owner, now)
    collected = set(QuestAward.objects.filter(
        owner=owner, kind=QuestAward.Kind.STREAK, point_entry__isnull=False,
    ).values_list("run_start_date", "milestone_days"))

    def next_target(run):
        target = 7
        while (run.start, target) in collected:
            target = 30 if target == 7 else target + 30
        return target

    # Earned milestones do not expire when a run breaks. Keep one actionable bar.
    for run in runs:
        target = next_target(run)
        if run.count >= target:
            return run, target, True
    active = runs[-1] if runs and runs[-1].end >= local_date(now) - timedelta(days=1) else None
    return active, next_target(active) if active else 7, False


def streak_task(*, owner, now):
    run, milestone, ready = _projection(owner, now)
    current = run.count if run else 0
    start = run.start if run else None
    points = 20 if milestone == 7 else 100
    return {
        "id": f"streak:{start.isoformat() if start else 'idle'}:{milestone}",
        "kind": "STREAK", "status": "READY" if ready else "IN_PROGRESS",
        "title": "Walking streak", "subtitle": f"{current} / {milestone} days",
        "subject_name": "Walking streak", "photo": None, "icon": "flame.fill",
        "detail": f"Walk on consecutive Melbourne days. Collect {points} points at {milestone} days. Missing a day starts a new streak; earned rewards remain available.",
        "reward_points": points, "progress": min(current / milestone, 1),
        "dog_id": None, "entitlement_id": None, "collected_at": None,
        "current_days": current, "milestone_days": milestone, "run_start_date": start,
    }


@transaction.atomic
def collect_streak(*, owner, run_start_date, milestone_days, now=None):
    owner = get_user_model().objects.select_for_update().get(pk=owner.pk)
    if owner.role != owner.Role.OWNER or not owner.is_active or owner.deleted_at:
        raise StreakClaimError("OWNER_REQUIRED", "Only active dog owners can collect streak points.", 403)
    if not valid_milestone(milestone_days):
        raise StreakClaimError("INVALID_STREAK_MILESTONE", "Use 7 days or a positive multiple of 30 days.", 400)
    now = now or timezone.now()
    existing = QuestAward.objects.select_for_update().select_related("point_entry").filter(
        owner=owner, kind=QuestAward.Kind.STREAK, run_start_date=run_start_date,
        milestone_days=milestone_days,
    ).order_by("pk")
    existing = list(existing)
    paid = next((award for award in existing if award.point_entry_id), None)
    if paid:
        return {"award": paid, "balance": get_balance(owner), "created": False}
    if not QuestDefinition.objects.filter(code=QuestDefinition.Code.STREAK, is_enabled=True).exists():
        raise StreakClaimError("QUEST_DISABLED", "Streak rewards are currently unavailable.", 409)
    run, target, ready = _projection(owner, now)
    if not ready or run.start != run_start_date or target != milestone_days:
        raise StreakClaimError("STREAK_NOT_READY", "Complete and collect the next available streak milestone first.", 409)
    points = 20 if target == 7 else 100
    pending = existing[0] if existing else None
    if pending and (pending.promised_points != points or pending.qualified_at > now
                    or (pending.claim_expires_at and pending.claim_expires_at <= now)):
        raise StreakClaimError("QUALIFICATION_UNAVAILABLE", "This streak qualification is not available for collection.", 409)
    key = f"streak:{owner.pk}:{run.start.isoformat()}:{target}"
    qualified_on, qualified_at = run.days[target - 1]
    entry = credit_points(
        user=owner, amount=points, type=PointEntry.Type.EARN, source_reference=key,
        earn_category=PointEntry.EarnCategory.STREAK, earned_on=qualified_on,
        rules_version=pending.rules_version if pending else STREAK_RULES_VERSION,
    )
    if pending:
        award = pending
        award.point_entry, award.awarded_at = entry, now
        award.save(update_fields=["point_entry", "awarded_at"])
    else:
        award = QuestAward.objects.create(
            owner=owner, kind=QuestAward.Kind.STREAK, qualification_key=key,
            qualified_on=qualified_on, qualified_at=qualified_at, run_start_date=run.start,
            milestone_days=target, promised_points=points, point_entry=entry,
            rules_version=STREAK_RULES_VERSION, awarded_at=now,
            eligibility_snapshot={"basis": "VALIDATED_WALK_DAYS", "milestone_days": target,
                                  "run_start_date": run.start.isoformat(), "qualified_on": qualified_on.isoformat()},
        )
    return {"award": award, "balance": get_balance(owner), "created": True}
