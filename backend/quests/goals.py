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
from dogs.goals import active_seconds
from dogs.models import DogDailyGoal
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
    ids = snapshot.get("required_goal_ids", [])
    if (not snapshot.get("approved_policy_version") or not snapshot.get("reward_scope")
            or not ids or len(set(ids)) != len(ids)
            or award.promised_points != DAILY_GOAL_POINTS
            or award.qualified_on != local_date(now) or award.qualified_at > now
            or award.claim_expires_at is None or award.claim_expires_at <= now):
        raise ValidationError("The approved goal policy and current qualification are required.")
    goals = list(DogDailyGoal.objects.select_for_update().filter(pk__in=ids,
        owner=owner, local_date=award.qualified_on))
    if len(goals) != len(ids) or any(active_seconds(goal, now=now) < goal.target_active_seconds for goal in goals):
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
