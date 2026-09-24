"""Confirmed reward values; unconfirmed qualification rules are not enabled here."""
from datetime import datetime, time, timedelta
from zoneinfo import ZoneInfo

from django.utils import timezone

MELBOURNE = ZoneInfo("Australia/Melbourne")
RULES_VERSION = "2026-09-24-v3"
BIRTHDAY_POINTS = 60
DAILY_GOAL_POINTS = 20
DAILY_ACTIVITY_CAP = 72
DOCUMENT_POINTS = {"COUNCIL_REGISTRATION": 300, "MICROCHIP_REGISTRATION": 300, "VET_CHECKUP": 200}
CHECKIN_SECONDS = {"CAFE": 600, "RESTAURANT": 1200, "PARK": 300, "VET": 180}
CHECKIN_POINTS = 12
CHECKIN_RADIUS_M = 20


def local_date(value=None):
    return (value or timezone.now()).astimezone(MELBOURNE).date()


def local_midnight(day):
    return datetime.combine(day, time.min, tzinfo=MELBOURNE)


def next_midnight(value=None):
    return local_midnight(local_date(value) + timedelta(days=1))
