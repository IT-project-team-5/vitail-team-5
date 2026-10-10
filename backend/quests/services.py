"""Actionable Quest rows and server-authoritative birthday collection."""
from datetime import timedelta

from django.contrib.auth import get_user_model
from django.db import transaction
from django.utils import timezone

from accounts.photos import photo_url
from dogs.models import Dog
from rewards.models import PointEntry
from rewards.policy import BIRTHDAY_POINTS, MELBOURNE, local_date, local_midnight
from rewards.services import credit_points, get_balance
from .models import QuestAward, QuestDefinition

BIRTHDAY_RULES_VERSION = "birthday-2026-09-25"


class BirthdayClaimError(Exception):
    def __init__(self, code, message, status_code):
        self.code = code
        self.message = message
        self.status_code = status_code
        super().__init__(message)


def _dog_photo(dog, request):
    if dog.uploaded_photo:
        return photo_url(dog.uploaded_photo, request)
    return dog.photo or None


def _is_birthday_today(birthday, today):
    return bool(birthday and birthday <= today and (birthday.month, birthday.day) == (today.month, today.day))


def _birthday_tasks(*, owner, dogs, claimed_dog_ids, now, request=None):
    today = now.astimezone(MELBOURNE).date()
    by_id = {dog.pk: dog for dog in dogs}
    qualifications = {award.dog_id_snapshot: award for award in QuestAward.objects.filter(
        kind=QuestAward.Kind.BIRTHDAY, dog_id_snapshot__in=by_id, year=today.year,
        point_entry__isnull=True,
    )}
    tasks = []
    for dog in dogs:
        if dog.pk in claimed_dog_ids or not _is_birthday_today(dog.date_of_birth, today):
            continue
        qualification = qualifications.get(dog.pk)
        if qualification and (qualification.qualified_at > now or
                              (qualification.claim_expires_at and qualification.claim_expires_at <= now)):
            continue
        points = qualification.promised_points if qualification else BIRTHDAY_POINTS
        tasks.append({
            "id": f"birthday:{dog.pk}:{today.year}", "kind": "BIRTHDAY", "status": "READY",
            "title": "Birthday bonus", "subtitle": "Birthday today", "subject_name": dog.name,
            "photo": _dog_photo(dog, request), "icon": "gift.fill",
            "detail": f"Celebrate {dog.name}'s birthday. Collect {points} points once per dog each year.",
            "reward_points": points, "progress": None, "dog_id": dog.pk,
            "entitlement_id": None, "collected_at": None,
        })
    # Today's receipts remain visible even after a profile edit, transfer or
    # deletion. Only their recipient sees them, never the next dog's owner.
    collected = QuestAward.objects.filter(
        owner=owner, kind=QuestAward.Kind.BIRTHDAY, point_entry__isnull=False,
        awarded_at__gte=local_midnight(today), awarded_at__lte=now,
    ).select_related("point_entry")
    for award in collected:
        dog = by_id.get(award.dog_id_snapshot)
        tasks.append({
            "id": f"birthday:{award.dog_id_snapshot}:{award.year}", "kind": "BIRTHDAY", "status": "COLLECTED",
            "title": "Birthday bonus", "subtitle": "Collected today", "subject_name": award.dog_name_snapshot,
            "photo": _dog_photo(dog, request) if dog else None, "icon": "gift.fill",
            "detail": "This year's birthday reward has been collected.",
            "reward_points": award.point_entry.amount, "progress": None,
            "dog_id": award.dog_id_snapshot, "entitlement_id": None, "collected_at": award.awarded_at,
        })
    return tasks


@transaction.atomic
def collect_birthday(*, owner, dog_id, now=None):
    """Owner lock serializes qualification, wallet credit and repeat requests."""
    owner = get_user_model().objects.select_for_update().get(pk=owner.pk)
    if owner.role != owner.Role.OWNER or not owner.is_active or owner.deleted_at:
        raise BirthdayClaimError("OWNER_REQUIRED", "Only dog owner accounts can collect birthday points.", 403)
    now = now or timezone.now()
    today = local_date(now)
    # A lost response remains replayable by its recipient after a dog transfer
    # or deletion. Never return another owner's award or wallet in that path.
    existing = QuestAward.objects.select_related("point_entry").filter(
        owner=owner, kind=QuestAward.Kind.BIRTHDAY, dog_id_snapshot=dog_id, year=today.year, point_entry__isnull=False,
    ).first()
    if existing:
        return {"award": existing, "balance": get_balance(owner), "created": False}
    dog = Dog.objects.select_for_update().filter(pk=dog_id, owner=owner).first()
    if dog is None:
        raise BirthdayClaimError("DOG_NOT_FOUND", "This dog is not available.", 404)
    # The entitlement follows the dog, not its current owner's account.
    # Check ownership before exposing even the fact that it was already used.
    if QuestAward.objects.filter(kind=QuestAward.Kind.BIRTHDAY, dog_id_snapshot=dog.pk, year=today.year, point_entry__isnull=False).exists():
        raise BirthdayClaimError("BIRTHDAY_ALREADY_CLAIMED", "This dog's birthday reward has already been collected for this year.", 409)
    if not QuestDefinition.objects.filter(code=QuestDefinition.Code.BIRTHDAY, is_enabled=True).exists():
        raise BirthdayClaimError("QUEST_DISABLED", "Birthday rewards are currently unavailable.", 409)
    if dog.date_of_birth is None:
        raise BirthdayClaimError("BIRTHDAY_REQUIRED", "Add your dog's date of birth first.", 400)
    if dog.date_of_birth > today:
        raise BirthdayClaimError("BIRTHDAY_IN_FUTURE", "Update your dog's birthday to a date that is not in the future.", 400)
    if not _is_birthday_today(dog.date_of_birth, today):
        raise BirthdayClaimError("BIRTHDAY_NOT_TODAY", "Birthday points can only be collected on your dog's birthday.", 409)
    qualification = QuestAward.objects.select_for_update().filter(
        kind=QuestAward.Kind.BIRTHDAY, dog_id_snapshot=dog.pk, year=today.year,
    ).first()
    if qualification and (qualification.qualified_at > now or
                          (qualification.claim_expires_at and qualification.claim_expires_at <= now)):
        raise BirthdayClaimError("QUALIFICATION_UNAVAILABLE", "This birthday reward is not available for collection.", 409)
    points = qualification.promised_points if qualification else BIRTHDAY_POINTS
    rules_version = qualification.rules_version if qualification else BIRTHDAY_RULES_VERSION
    entry = credit_points(
        user=owner, amount=points, type=PointEntry.Type.EARN,
        source_reference=f"birthday:{dog.pk}:{today.year}",
        earn_category=PointEntry.EarnCategory.BIRTHDAY, earned_on=today, rules_version=rules_version,
    )
    if qualification:
        qualification.owner = owner
        qualification.point_entry = entry
        qualification.awarded_at = now
        qualification.save(update_fields=["owner", "point_entry", "awarded_at"])
        return {"award": qualification, "balance": get_balance(owner), "created": True}
    award = QuestAward.objects.create(
        owner=owner, kind=QuestAward.Kind.BIRTHDAY, dog=dog,
        dog_id_snapshot=dog.pk, dog_name_snapshot=dog.name,
        year=today.year, point_entry=entry, rules_version=BIRTHDAY_RULES_VERSION,
        qualification_key=f"birthday:{dog.pk}:{today.year}", promised_points=BIRTHDAY_POINTS,
        qualified_on=today, qualified_at=now, awarded_at=now,
        eligibility_snapshot={"date_of_birth": dog.date_of_birth.isoformat()},
    )
    return {"award": award, "balance": get_balance(owner), "created": True}


def quest_dashboard(*, owner, request=None, now=None):
    from dogs.goals import goal_progress
    now = now or timezone.now()
    today = local_date(now)
    enabled = set(QuestDefinition.objects.filter(is_enabled=True).values_list("code", flat=True))
    dogs = list(Dog.objects.filter(owner=owner))
    tasks = []
    if QuestDefinition.Code.STREAK in enabled:
        from .streaks import streak_task
        tasks.append(streak_task(owner=owner, now=now))
    if QuestDefinition.Code.BIRTHDAY in enabled:
        claimed = set(QuestAward.objects.filter(kind="BIRTHDAY", year=today.year,
            dog_id_snapshot__in=[dog.pk for dog in dogs], point_entry__isnull=False
        ).values_list("dog_id_snapshot", flat=True))
        tasks.extend(_birthday_tasks(owner=owner, dogs=dogs, claimed_dog_ids=claimed, now=now, request=request))
    if QuestDefinition.Code.DOCUMENTS in enabled:
        from evidence.services import quest_tasks
        tasks.extend(quest_tasks(owner=owner, dogs=dogs, request=request, now=now))
    progress = goal_progress(owner=owner, request=request, now=now)
    if QuestDefinition.Code.DAILY_GOAL in enabled:
        from .goals import daily_goal_tasks
        tasks.extend(daily_goal_tasks(owner=owner, progress=progress, now=now))
    order = {"READY": 0, "IN_PROGRESS": 1, "COLLECTED": 2}
    tasks.sort(key=lambda task: (order[task["status"]], task["kind"], task["dog_id"] or 0, task["id"]))
    return {"server_time": now, "timezone": MELBOURNE.key, "local_date": today,
            "next_reset_at": local_midnight(today + timedelta(days=1)), "tasks": tasks,
            "daily_goals": progress,
            "goal_rewards_status": "AVAILABLE" if QuestDefinition.Code.DAILY_GOAL in enabled else "DISABLED"}
