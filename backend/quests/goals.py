"""Settlement foundation for a future approved daily-goal qualification engine.

No API, upload hook, admin action or read creates these qualifications or calls
this function. Payouts remain disabled pending per-dog/account scope and any/all
participant decisions. QuestDefinition alone cannot enable them.
"""
from django.contrib.auth import get_user_model
from django.db import transaction
from django.utils import timezone
from rest_framework.exceptions import ValidationError

from checkins.services import daily_activity_points
from dogs.goals import GOAL_RULES_VERSION, active_seconds
from dogs.models import Dog, DogDailyGoal, DogGoalTarget
from rewards.models import PointEntry
from rewards.policy import DAILY_ACTIVITY_CAP, DAILY_GOAL_POINTS, local_date
from rewards.services import credit_points, get_balance
from .models import QuestAward


@transaction.atomic
def settle_reserved_goal(*, owner, qualification_id, now=None):
    """Credit only a backend-reserved, versioned qualification, never client progress.

    The future qualifier must freeze its scope, required goal IDs, policy version
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
    # The approved baseline is 40 walking + 20 goal + 12 check-in within 72.
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
