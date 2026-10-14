"""Explicit per-dog daily collection using the existing qualification and ledger."""
from datetime import timedelta
from django.contrib.auth import get_user_model
from django.db import transaction
from django.utils import timezone
from rest_framework.exceptions import ValidationError

from checkins.services import daily_activity_points
from dogs.goals import GOAL_RULES_VERSION, active_seconds, goal_progress
from dogs.models import Dog, DogDailyGoal, DogGoalTarget
from rewards.models import PointEntry
from rewards.policy import DAILY_ACTIVITY_CAP, DAILY_GOAL_POINTS, local_date, local_midnight
from rewards.services import credit_points, get_balance
from .models import QuestAward, QuestDefinition

POLICY = "per-dog-goal-2026-10-10"


@transaction.atomic
def collect_daily_goal(*, owner, dog_id, day, now=None):
    owner = get_user_model().objects.select_for_update().get(pk=owner.pk)
    if owner.role != "OWNER" or not owner.is_active or owner.deleted_at:
        raise ValidationError("An active owner is required.")
    now = now or timezone.now()
    key = f"dog-daily-goal:{dog_id}:{day.isoformat()}"
    existing = QuestAward.objects.filter(qualification_key=key).first()
    # A lost successful response can be replayed by its recipient after midnight.
    if existing and existing.owner_id == owner.pk and existing.point_entry_id:
        return {"award": existing, "balance": get_balance(owner), "created": False}
    dog = Dog.objects.select_for_update().filter(pk=dog_id, owner=owner, archived_at__isnull=True).first()
    if not dog:
        raise ValidationError("This dog is not available.")
    if day != local_date(now):
        raise ValidationError("Collect today's reward before Melbourne midnight.")
    if not QuestDefinition.objects.filter(code="DAILY_GOAL", is_enabled=True).exists():
        raise ValidationError("Daily goal rewards are currently unavailable.")
    goal_progress(owner=owner, now=now)
    goal = DogDailyGoal.objects.filter(dog=dog, owner=owner, local_date=day).first()
    if not goal or active_seconds(goal, now=now) < goal.target_active_seconds:
        raise ValidationError("Complete this dog's walking goal before collecting.")
    if existing and existing.owner_id != owner.pk:
        raise ValidationError("This dog's reward has already been reserved for this day.")
    award = existing or QuestAward.objects.create(owner=owner, kind="DAILY_GOAL", dog=dog,
        dog_id_snapshot=dog.pk, dog_name_snapshot=dog.name, qualification_key=key,
        qualified_on=day, qualified_at=now, promised_points=DAILY_GOAL_POINTS, rules_version=POLICY,
        claim_expires_at=local_midnight(day + timedelta(days=1)),
        eligibility_snapshot={"approved_policy_version": POLICY, "reward_scope": "dog/day",
                              "required_goal_ids": [goal.pk]})
    return settle_reserved_goal(owner=owner, qualification_id=award.pk, now=now)


def daily_goal_tasks(*, owner, progress, now):
    day = local_date(now)
    remaining = max(0, DAILY_ACTIVITY_CAP - daily_activity_points(owner, day))
    paid = {row.dog_id_snapshot: row for row in QuestAward.objects.filter(owner=owner,
        kind="DAILY_GOAL", qualified_on=day, point_entry__isnull=False, rules_version=POLICY)}
    tasks = []
    for goal in progress:
        if not goal["target_seconds"]:
            continue
        award = paid.get(goal["dog_id"])
        ready = goal["completed"] and remaining >= DAILY_GOAL_POINTS
        detail = ("Collected for this dog today." if award else
            f"Only {remaining} of 72 activity points remain today. Collection needs the full 20 points."
            if goal["completed"] and not ready else
            "Complete this dog's walking goal, then collect 20 points before Melbourne midnight. The 72-point activity cap is shared by your account.")
        tasks.append({"id": f"daily-goal:{goal['dog_id']}:{day}", "kind": "DAILY_GOAL",
            "status": "COLLECTED" if award else "READY" if ready else "IN_PROGRESS",
            "title": "Daily walking goal", "subtitle": detail, "subject_name": goal["dog_name"],
            "photo": goal["photo"], "icon": "figure.walk", "detail": detail,
            "reward_points": DAILY_GOAL_POINTS, "progress": min(1, goal["active_seconds"] / goal["target_seconds"]),
            "dog_id": goal["dog_id"], "entitlement_id": None,
            "collected_at": award.awarded_at if award else None})
    return tasks


@transaction.atomic
def settle_reserved_goal(*, owner, qualification_id, now=None):
    """Credit only a backend-reserved, versioned qualification, never client progress.

    The backend qualifier freezes its scope, required goal IDs, policy version
    and expiry before calling. No account/day or dog/day reward scope is inferred
    here. Its unique qualification_key and ledger reference identify one award.
    """
    owner = get_user_model().objects.select_for_update().get(pk=owner.pk)
    if owner.role != "OWNER" or not owner.is_active or owner.deleted_at:
        raise ValidationError("An active owner is required.")
    award = QuestAward.objects.select_for_update().filter(pk=qualification_id,
        owner=owner, kind=QuestAward.Kind.DAILY_GOAL).first()
    if award is None:
        raise ValidationError("No approved goal qualification is available.")
    if award.point_entry_id:
        return {"award": award, "balance": get_balance(owner), "created": False}
    now = now or timezone.now()
    snapshot = award.eligibility_snapshot
    if not isinstance(snapshot, dict):
        raise ValidationError("The approved goal policy and current qualification are required.")
    ids = snapshot.get("required_goal_ids", [])
    if (not isinstance(ids, list) or not ids or any(type(pk) is not int or pk <= 0 for pk in ids)
            or len(set(ids)) != len(ids)
            or any(not isinstance(value, str) or not value.strip() for value in
                   (snapshot.get("approved_policy_version"), snapshot.get("reward_scope"), award.rules_version))
            or award.promised_points != DAILY_GOAL_POINTS
            or award.qualified_on != local_date(now) or award.qualified_at > now
            or award.claim_expires_at is None or award.claim_expires_at <= now):
        raise ValidationError("The approved goal policy and current qualification are required.")
    # Same lock order as uploads and configuration: owner, dogs, snapshots.
    dogs = {dog.pk: dog for dog in Dog.objects.select_for_update().filter(owner=owner,
        archived_at__isnull=True, pk__in=DogDailyGoal.objects.filter(pk__in=ids).values("dog_id"))
        .order_by("pk")}
    targets = {target.pk: target for target in DogGoalTarget.objects.filter(dog_id__in=dogs, owner=owner)}
    goals = list(DogDailyGoal.objects.select_for_update().filter(pk__in=ids,
        owner=owner, local_date=award.qualified_on, rules_version=GOAL_RULES_VERSION))
    def eligible(goal):
        dog = dogs.get(goal.dog_id_snapshot)
        target_id = goal.inputs_snapshot.get("target_id") if isinstance(goal.inputs_snapshot, dict) else None
        target = targets.get(target_id) if type(target_id) is int else None
        return (dog is not None and goal.dog_id == dog.pk and target is not None
            and target.dog_id == dog.pk and target.owner_version == dog.goal_owner_version
            and target.effective_from <= goal.local_date
            and target.target_active_seconds == goal.target_active_seconds
            and goal.inputs_snapshot.get("eligible_since") == target.created_at.isoformat()
            and active_seconds(goal, now=now) >= goal.target_active_seconds)
    if len(goals) != len(ids) or not all(eligible(goal) for goal in goals):
        raise ValidationError("The required daily goals are incomplete.")
    # Walking, both dogs' goals and check-ins share the owner's 72-point cap.
    # Never displace earlier credits or invent a partial goal award.
    if daily_activity_points(owner, award.qualified_on) + award.promised_points > DAILY_ACTIVITY_CAP:
        raise ValidationError("Insufficient daily allowance for the full goal reward.")
    award.point_entry = credit_points(user=owner, amount=award.promised_points,
        type=PointEntry.Type.EARN, source_reference=f"daily-goal:{award.pk}",
        earn_category=PointEntry.EarnCategory.DAILY_GOAL, earned_on=award.qualified_on,
        rules_version=award.rules_version)
    award.awarded_at = now
    award.save(update_fields=("point_entry", "awarded_at"))
    return {"award": award, "balance": get_balance(owner), "created": True}
