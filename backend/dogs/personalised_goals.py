"""Owner recommendations; exact decimal arithmetic, final seconds rounded half up.

Age is evaluated on the revision's effective date. Saved revisions never
recalculate when a profile, breed or policy changes.
"""
import calendar
from datetime import date, timedelta
from decimal import Decimal, InvalidOperation, ROUND_HALF_UP

from django.core.exceptions import ValidationError
from django.db import transaction

from rewards.policy import local_date
from .goals import configure_target, lock_goal_dog
from .models import DogGoalTarget, age_in_months

POLICY = "personalised-duration-v1"
ENERGY = {"LOW": Decimal("0.75"), "MODERATE": Decimal("1"),
          "HIGH": Decimal("1.25"), "VERY_HIGH": Decimal("1.50")}


def adjustment_value(value):
    try:
        adjustment = Decimal(str(value))
    except (InvalidOperation, ValueError):
        raise ValidationError({"owner_adjustment": "Choose an adjustment from 0.50 to 2.00."})
    if not adjustment.is_finite() or not Decimal("0.50") <= adjustment <= Decimal("2.00"):
        raise ValidationError({"owner_adjustment": "Choose an adjustment from 0.50 to 2.00."})
    # Percent precision; reject rather than silently round the owner's input.
    if adjustment != adjustment.quantize(Decimal("0.01")):
        raise ValidationError({"owner_adjustment": "Use whole percentage points."})
    return adjustment


def recommend(*, dog, effective_from, owner_adjustment=Decimal("1.00")):
    adjustment = adjustment_value(owner_adjustment)
    missing = []
    if dog.weight_kg is None or dog.weight_kg <= 0:
        missing.append("weight_kg")
    if dog.date_of_birth is None or dog.date_of_birth > local_date():
        missing.append("date_of_birth")
    if not dog.breed_id:
        missing.append("breed")
    if dog.is_brachycephalic is None:
        missing.append("is_brachycephalic")
    result = {"eligible": False, "missing_inputs": missing, "reason": None,
              "effective_from": effective_from, "policy_version": POLICY,
              "owner_adjustment": str(adjustment), "suggested_minutes": None,
              "target_minutes": None, "target_seconds": None}
    if missing:
        result["reason"] = "Complete the required profile inputs before setting a personalised goal."
        return result
    months = age_in_months(dog.date_of_birth, effective_from)
    if months < 4:
        result["reason"] = "Personalised goals start at four calendar months."
        return result
    tenth_birthday = dog.date_of_birth.replace(year=dog.date_of_birth.year + 10,
        day=min(dog.date_of_birth.day, calendar.monthrange(dog.date_of_birth.year + 10, dog.date_of_birth.month)[1]))
    age = Decimal("0.50" if months < 7 else "0.75" if months < 12 or effective_from > tenth_birthday else "1.00")
    baseline = next((minutes for limit, minutes in ((5, 30), (10, 40), (25, 50), (40, 60))
                     if dog.weight_kg < limit), 60)
    energy = ENERGY.get(dog.breed.energy_level, Decimal("1.00"))
    brachy = Decimal("0.70" if dog.is_brachycephalic else "1.00")
    suggested = Decimal(baseline) * energy * age * brachy
    target = suggested * adjustment  # Exercise level IS this single adjustment.
    seconds = int((target * 60).quantize(Decimal("1"), rounding=ROUND_HALF_UP))
    result.update(eligible=True, suggested_minutes=str(suggested), target_minutes=str(target),
        target_seconds=seconds, calculation_inputs={
            "weight_kg": str(dog.weight_kg), "date_of_birth": dog.date_of_birth.isoformat(),
            "age_on": effective_from.isoformat(), "age_months": months,
            "breed_id": dog.breed_id, "breed_name": dog.breed.name, "breed_energy": dog.breed.energy_level,
            "is_brachycephalic": dog.is_brachycephalic, "baseline_minutes": baseline,
            "energy_factor": str(energy), "age_factor": str(age), "brachycephalic_factor": str(brachy),
            "owner_adjustment": str(adjustment), "suggested_minutes": str(suggested),
            "target_minutes": str(target), "rounding": "nearest_second_half_up"})
    return result


def next_effective_date(dog):
    targets = DogGoalTarget.objects.filter(dog=dog)
    day = local_date() + timedelta(days=1) if targets.exists() else local_date()
    latest = targets.filter(owner_id=dog.owner_id, owner_version=dog.goal_owner_version).last()
    if latest and latest.effective_from < date.max:
        day = max(day, latest.effective_from + timedelta(days=1))
    # At the calendar limit there is no following date. Offer the first free
    # permitted date instead; do not let one legal far-future revision break GET.
    # An earlier owner's future schedule must not postpone this owner's setup.
    # The existing dog/date uniqueness still reserves those exact dates.
    for occupied in targets.filter(effective_from__gte=day).values_list("effective_from", flat=True):
        if occupied != day:
            break
        if day == date.max:
            raise ValidationError({"effective_from": "No available effective date remains."})
        day += timedelta(days=1)
    return day


def target_data(target):
    if target is None:
        return None
    return {"id": target.pk, "effective_from": target.effective_from,
            "target_seconds": target.target_active_seconds, "policy_version": target.calculation_policy,
            "calculation_inputs": target.calculation_inputs}


@transaction.atomic
def owner_goal(*, dog, owner, effective_from=None, owner_adjustment=Decimal("1.00"), save=False):
    if dog.owner_id != owner.pk:
        raise ValidationError("This dog does not belong to you.")
    dog = lock_goal_dog(dog)
    if dog.archived_at is not None:
        raise ValidationError("Archived dogs cannot configure goals.")
    effective_from = effective_from or next_effective_date(dog)
    result = recommend(dog=dog, effective_from=effective_from, owner_adjustment=owner_adjustment)
    if save:
        if not result["eligible"]:
            raise ValidationError({"profile": result["reason"], "missing_inputs": result["missing_inputs"]})
        target = configure_target(dog=dog, effective_from=effective_from,
            target_active_seconds=result["target_seconds"], calculation_policy=POLICY,
            calculation_inputs=result["calculation_inputs"])
        result["saved_target"] = target_data(target)
    targets = DogGoalTarget.objects.filter(dog=dog, owner=owner, owner_version=dog.goal_owner_version)
    result["current_target"] = target_data(targets.filter(effective_from__lte=local_date()).last())
    result["scheduled_targets"] = [target_data(t) for t in targets.filter(effective_from__gt=local_date())]
    return result
