"""The 72-point daily cap shared by walking and venue check-ins (README, Earning Points).

Personalised-goal awards are not built yet; add them here when they exist. Vet checkups,
council proof and streak bonuses sit outside the cap.
"""
from django.db.models import Sum

from walks.models import Walk

from .models import CheckIn


DAILY_POINT_CAP = 72


def capped_points_used(owner, local_date):
    walking = Walk.objects.filter(owner=owner, point_date=local_date).aggregate(
        total=Sum("points_awarded"))["total"] or 0
    check_ins = CheckIn.objects.filter(owner=owner, completed_local_date=local_date).aggregate(
        total=Sum("awarded_points"))["total"] or 0
    return walking + check_ins


def remaining_daily_cap(owner, local_date):
    return max(0, DAILY_POINT_CAP - capped_points_used(owner, local_date))
