"""Effective-dated per-dog goals. Calendar boundaries use rewards.policy Melbourne.

Walk duration belongs wholly to its end date (the existing walking convention).
Snapshots are final after the 12-hour upload window; reads never create credits.
"""
from datetime import UTC, timedelta

from django.contrib.auth import get_user_model
from django.core.exceptions import ValidationError
from django.db import transaction
from django.utils import timezone

from rewards.policy import local_date, local_midnight
from walks.models import WalkDog
from walks.eligibility import SUMMARY_FIELDS, TRUSTED_WALK_RULES, has_validated_movement
from .models import Dog, DogDailyGoal, DogGoalTarget

GOAL_RULES_VERSION = "manual-duration-v1"


@transaction.atomic
def lock_goal_dog(dog):
    get_user_model().objects.select_for_update().get(pk=dog.owner_id)
    current = Dog.objects.select_for_update().filter(pk=dog.pk, owner_id=dog.owner_id).first()
    if current is None:
        raise ValidationError("The dog's owner changed. Reload before configuring a target.")
    return current


@transaction.atomic
def configure_target(*, dog, target_active_seconds, effective_from,
                     calculation_policy=GOAL_RULES_VERSION, calculation_inputs=None):
    dog = lock_goal_dog(dog)
    target = DogGoalTarget(dog=dog, dog_id_snapshot=dog.pk, owner_id=dog.owner_id,
        owner_version=dog.goal_owner_version,
        target_active_seconds=target_active_seconds, effective_from=effective_from,
        calculation_policy=calculation_policy, calculation_inputs=calculation_inputs or {})
    target.full_clean()
    target.save()
    return target


def active_seconds(goal, now=None):
    now = now or timezone.now()
    if goal.finalised_at is not None:
        return goal.final_active_seconds
    # Only explicit participation in validated uploads counts. Net intervals do
    # not add time; their movement is already represented by their base walk.
    since = goal.inputs_snapshot.get("eligible_since")
    if not since:
        return 0  # Unknown legacy inputs must not establish new eligibility.
    rows = WalkDog.objects.filter(dog_id_snapshot=goal.dog_id_snapshot,
        walk__owner=goal.owner, walk__point_date=goal.local_date,
        walk__started_at__gt=since, walk__rules_version__in=TRUSTED_WALK_RULES,
        walk__active_seconds__gt=0, walk__distance_m__gt=0,
        active_seconds__isnull=False).select_related("walk")
    return sum(min(row.active_seconds, row.walk.active_seconds) for row in rows
        if has_validated_movement({field: getattr(row.walk, field) for field in SUMMARY_FIELDS}, now))


@transaction.atomic
def goal_progress(*, owner, now=None):
    """Lazily freeze eligible days, including missed days while the app was closed."""
    get_user_model().objects.select_for_update().get(pk=owner.pk)
    now = now or timezone.now()
    today = local_date(now)
    result = []
    for dog in Dog.objects.select_for_update().filter(owner=owner, archived_at__isnull=True).order_by("pk"):
        targets = list(DogGoalTarget.objects.filter(dog=dog, owner=owner,
            owner_version=dog.goal_owner_version, effective_from__lte=today))
        target_ids = {target.pk for target in targets}
        goals = {g.local_date: g for g in DogDailyGoal.objects.filter(
            dog_id_snapshot=dog.pk, owner=owner, rules_version=GOAL_RULES_VERSION)
            if g.inputs_snapshot.get("target_id") in target_ids}
        for index, target in enumerate(targets):
            until = min(today, targets[index + 1].effective_from - timedelta(days=1)) if index + 1 < len(targets) else today
            day = max(target.effective_from, local_date(dog.created_at))
            while day <= until:
                if target.target_active_seconds and day not in goals:
                    goal, _ = DogDailyGoal.objects.get_or_create(dog_id_snapshot=dog.pk, local_date=day,
                        defaults={"dog": dog, "owner": owner,
                            "target_active_seconds": target.target_active_seconds,
                            "inputs_snapshot": {"target_id": target.pk, "dog_name": dog.name,
                                "calculation_policy": target.calculation_policy,
                                "calculation_inputs": target.calculation_inputs,
                                "eligible_since": target.created_at.isoformat()},
                            "rules_version": GOAL_RULES_VERSION})
                    if (goal.owner_id == owner.pk and goal.rules_version == GOAL_RULES_VERSION
                            and goal.inputs_snapshot.get("target_id") == target.pk):
                        goals[day] = goal
                day += timedelta(days=1)
        measured = {}
        for day, goal in goals.items():
            seconds = active_seconds(goal, now=now)
            met = seconds >= goal.target_active_seconds
            measured[day] = (goal, seconds, met)
            # A just-finished day may still receive a valid offline upload.
            if goal.finalised_at is None and now >= local_midnight(day + timedelta(days=1)).astimezone(UTC) + timedelta(hours=12):
                goal.final_active_seconds = seconds
                goal.final_goal_met = met
                goal.finalised_at = now
                goal.save(update_fields=("final_active_seconds", "final_goal_met", "finalised_at"))
        streak = 0
        day = today
        if day in measured and not measured[day][2]:
            day -= timedelta(days=1)
        while day in measured and measured[day][2]:
            streak += 1
            day -= timedelta(days=1)
        days = []
        for offset in range(6, -1, -1):
            day = today - timedelta(days=offset)
            item = measured.get(day)
            days.append({"date": day, "state": (
                "NOT_ELIGIBLE" if item is None else "COMPLETED" if item[2]
                else "INCOMPLETE" if day == today else "MISSED"),
                "active_seconds": item[1] if item else 0,
                "target_seconds": item[0].target_active_seconds if item else None})
        current = measured.get(today)
        result.append({"dog_id": dog.pk, "dog_name": dog.name,
            "active_seconds": current[1] if current else 0,
            "target_seconds": current[0].target_active_seconds if current else None,
            "completed": current[2] if current else False,
            "current_streak": streak, "days": days})
    return result
