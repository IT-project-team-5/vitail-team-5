"""Quest projections from accepted walks and dog profiles.

Pending product decisions stay unavailable. Only the confirmed birthday rule
can create awards; elapsed walk time is never treated as verified active time.
"""

from datetime import date, datetime, time, timedelta
from decimal import Decimal
from zoneinfo import ZoneInfo

from django.contrib.auth import get_user_model
from django.db import transaction
from django.db.models import Sum
from django.utils import timezone

from accounts.photos import photo_url
from dogs.models import Dog
from rewards.models import PointEntry
from rewards.services import credit_points, get_balance
from walks.models import Walk

from .models import QuestAward, QuestDefinition


MELBOURNE = ZoneInfo("Australia/Melbourne")
BIRTHDAY_POINTS = 60
BIRTHDAY_RULES_VERSION = "birthday-2026-09-25"


class BirthdayClaimError(Exception):
    def __init__(self, code, message, status_code):
        self.code = code
        self.message = message
        self.status_code = status_code
        super().__init__(message)


def local_midnight(day):
    # Construct the next local calendar boundary, not now + 24 elapsed hours:
    # daylight-saving transitions can make a local day 23 or 25 hours long.
    return datetime.combine(day, time.min, tzinfo=MELBOURNE)


def _dog_photo(dog, request):
    if dog.uploaded_photo:
        return photo_url(dog.uploaded_photo, request)
    return dog.photo or None


def _dog_identity(dog, request):
    return {"dog_id": dog.pk, "name": dog.name, "photo": _dog_photo(dog, request)}


def _next_birthday(birthday, today):
    if birthday is None or birthday > today:
        return None
    # Only actual calendar anniversaries are displayed. An observed date for
    # 29 February in a non-leap year is a reward-policy decision still pending.
    for year in range(today.year, today.year + 5):
        try:
            anniversary = date(year, birthday.month, birthday.day)
        except ValueError:
            continue
        if anniversary >= today:
            return anniversary
    return None


def _is_birthday_today(birthday, today):
    return bool(birthday and birthday <= today and (birthday.month, birthday.day) == (today.month, today.day))


def _streak(days, today):
    ordered = sorted(set(days))
    longest = run = 0
    previous = None
    for day in ordered:
        run = run + 1 if previous is not None and day == previous + timedelta(days=1) else 1
        longest = max(longest, run)
        previous = day
    current = run if previous in (today, today - timedelta(days=1)) else 0
    next_days = 7 if current < 7 else 30 if current < 30 else (current // 30 + 1) * 30
    return {
        "current_days": current,
        "longest_days": longest,
        "active_today": today in days,
        "milestones": [{"days": 7, "reward_points": 20}, {"days": 30, "reward_points": 100}],
        "next_milestone": {"days": next_days, "reward_points": 20 if next_days == 7 else 100},
        "award_status": "NOT_ENABLED",
    }


def _birthday_tasks(*, owner, dogs, claimed_dog_ids, now, request=None):
    today = now.astimezone(MELBOURNE).date()
    by_id = {dog.pk: dog for dog in dogs}
    tasks = []
    for dog in dogs:
        if dog.pk in claimed_dog_ids or not _is_birthday_today(dog.date_of_birth, today):
            continue
        tasks.append({
            "id": f"birthday:{dog.pk}:{today.year}", "kind": "BIRTHDAY", "status": "READY",
            "title": "Birthday bonus", "subtitle": "Birthday today", "subject_name": dog.name,
            "photo": _dog_photo(dog, request), "icon": "gift.fill",
            "detail": f"Celebrate {dog.name}'s birthday. Collect {BIRTHDAY_POINTS} points once per dog each year.",
            "reward_points": BIRTHDAY_POINTS, "progress": None, "dog_id": dog.pk,
            "entitlement_id": None, "collected_at": None,
        })
    # Today's receipts remain visible even after a profile edit, transfer or
    # deletion. Only their recipient sees them, never the next dog's owner.
    collected = QuestAward.objects.filter(
        owner=owner, kind=QuestAward.Kind.BIRTHDAY,
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


def quest_dashboard(*, owner, request=None, now=None):
    now = now or timezone.now()
    today = now.astimezone(MELBOURNE).date()
    definitions = {entry.code: entry for entry in QuestDefinition.objects.all()}

    def availability(code, supported_status):
        definition = definitions.get(code)
        return supported_status if definition and definition.is_enabled else "DISABLED"

    dogs = list(Dog.objects.filter(owner=owner))
    claimed_birthdays = set(QuestAward.objects.filter(
        dog_id_snapshot__in=[dog.pk for dog in dogs],
        kind=QuestAward.Kind.BIRTHDAY, year=today.year,
    ).values_list("dog_id_snapshot", flat=True))
    accepted = Walk.objects.filter(owner=owner, ended_at__lte=now, point_date__lte=today)
    per_dog_distance = {
        row["dogs"]: row["distance"]
        for row in accepted.filter(point_date=today, dogs__owner=owner)
        .values("dogs").annotate(distance=Sum("distance_m"))
    }
    active_dates = set(accepted.filter(distance_m__gt=0).values_list("point_date", flat=True))
    tasks = []
    if availability(QuestDefinition.Code.BIRTHDAY, "AVAILABLE") == "AVAILABLE":
        tasks.extend(_birthday_tasks(owner=owner, dogs=dogs, claimed_dog_ids=claimed_birthdays, now=now, request=request))
    if availability(QuestDefinition.Code.DOCUMENTS, "AVAILABLE") == "AVAILABLE":
        from evidence.services import quest_tasks as document_quest_tasks
        tasks.extend(document_quest_tasks(owner=owner, dogs=dogs, request=request, now=now))
    status_order = {"READY": 0, "IN_PROGRESS": 1, "COLLECTED": 2}
    tasks.sort(key=lambda task: (status_order[task["status"]], task["kind"], task["dog_id"] or 0, task["id"]))
    return {
        "server_time": now,
        "timezone": MELBOURNE.key,
        "local_date": today,
        "next_reset_at": local_midnight(today + timedelta(days=1)),
        "tasks": tasks,
        "daily_goal": {
            "status": availability(QuestDefinition.Code.DAILY_GOAL, "RULES_PENDING"),
            "dogs": [
                {
                    **_dog_identity(dog, request),
                    "distance_m": per_dog_distance.get(dog.pk, Decimal("0.00")),
                    "target_distance_m": None,
                    "active_seconds": None,
                    "target_active_seconds": None,
                    "progress": None,
                }
                for dog in dogs
            ],
            "reward_points": None,
            "message": "Daily goal targets and rewards are awaiting confirmed rules. Recorded distance is shown without a completion percentage.",
        },
        "streak": {
            "status": availability(QuestDefinition.Code.STREAK, "AVAILABLE"),
            **_streak(active_dates, today),
        },
        "birthdays": {
            "status": availability(QuestDefinition.Code.BIRTHDAY, "AVAILABLE"),
            "reward_points": BIRTHDAY_POINTS,
            "dogs": [
                {
                    **_dog_identity(dog, request),
                    "date_of_birth": dog.date_of_birth,
                    "next_birthday": _next_birthday(dog.date_of_birth, today),
                    "is_birthday_today": _is_birthday_today(dog.date_of_birth, today),
                    "status": (
                        "CLAIMED" if dog.pk in claimed_birthdays
                        else "MISSING_BIRTHDAY" if dog.date_of_birth is None
                        else "INVALID_BIRTHDAY" if dog.date_of_birth > today
                        else "AVAILABLE" if _is_birthday_today(dog.date_of_birth, today)
                        else "UPCOMING"
                    ),
                }
                for dog in dogs
            ],
            "message": "Collect 60 points on each dog's birthday, once per dog per year.",
        },
        "check_ins": {
            "status": availability(QuestDefinition.Code.CHECK_IN, "NOT_AVAILABLE"),
            "items": [],
            "message": "Venue check-in progress will appear here when check-ins are available.",
        },
        "documents": {
            "status": availability(QuestDefinition.Code.DOCUMENTS, "AVAILABLE"),
            "items": [
                {"kind": "COUNCIL_REGISTRATION", "title": "Council registration", "reward_points": 300},
                {"kind": "MICROCHIP_REGISTRATION", "title": "Microchip registration", "reward_points": 300},
                {"kind": "VET_CHECKUP", "title": "Vet check-up", "reward_points": 200},
            ],
            "message": "Submit your dog's documents, then collect eligible points. Submissions may be checked later.",
        },
    }


@transaction.atomic
def collect_birthday(*, owner, dog_id, now=None):
    """Owner lock serializes qualification, wallet credit and repeat requests."""
    owner = get_user_model().objects.select_for_update().get(pk=owner.pk)
    if owner.role != owner.Role.OWNER:
        raise BirthdayClaimError("OWNER_REQUIRED", "Only dog owner accounts can collect birthday points.", 403)
    today = (now or timezone.now()).astimezone(MELBOURNE).date()
    # A lost response remains replayable by its recipient after a dog transfer
    # or deletion. Never return another owner's award or wallet in that path.
    existing = QuestAward.objects.select_related("point_entry").filter(
        owner=owner, kind=QuestAward.Kind.BIRTHDAY, dog_id_snapshot=dog_id, year=today.year,
    ).first()
    if existing:
        return {"award": existing, "balance": get_balance(owner), "created": False}
    dog = Dog.objects.select_for_update().filter(pk=dog_id, owner=owner).first()
    if dog is None:
        raise BirthdayClaimError("DOG_NOT_FOUND", "This dog is not available.", 404)
    # The entitlement follows the dog, not its current owner's account.
    # Check ownership before exposing even the fact that it was already used.
    if QuestAward.objects.filter(kind=QuestAward.Kind.BIRTHDAY, dog_id_snapshot=dog.pk, year=today.year).exists():
        raise BirthdayClaimError("BIRTHDAY_ALREADY_CLAIMED", "This dog's birthday reward has already been collected for this year.", 409)
    if not QuestDefinition.objects.filter(code=QuestDefinition.Code.BIRTHDAY, is_enabled=True).exists():
        raise BirthdayClaimError("QUEST_DISABLED", "Birthday rewards are currently unavailable.", 409)
    if dog.date_of_birth is None:
        raise BirthdayClaimError("BIRTHDAY_REQUIRED", "Add your dog's date of birth first.", 400)
    if dog.date_of_birth > today:
        raise BirthdayClaimError("BIRTHDAY_IN_FUTURE", "Update your dog's birthday to a date that is not in the future.", 400)
    if not _is_birthday_today(dog.date_of_birth, today):
        raise BirthdayClaimError("BIRTHDAY_NOT_TODAY", "Birthday points can only be collected on your dog's birthday.", 409)
    entry = credit_points(
        user=owner, amount=BIRTHDAY_POINTS, type=PointEntry.Type.EARN,
        source_reference=f"birthday:{dog.pk}:{today.year}",
    )
    award = QuestAward.objects.create(
        owner=owner, kind=QuestAward.Kind.BIRTHDAY, dog=dog,
        dog_id_snapshot=dog.pk, dog_name_snapshot=dog.name,
        year=today.year, point_entry=entry, rules_version=BIRTHDAY_RULES_VERSION,
    )
    return {"award": award, "balance": get_balance(owner), "created": True}
