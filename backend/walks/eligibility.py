"""Shared persisted evidence check for walking-day and daily-goal progress."""
from datetime import UTC

from rewards.policy import local_date

# Extend deliberately when another persisted validator has equivalent evidence.
TRUSTED_WALK_RULES = ("walk-gps-v2",)
SUMMARY_FIELDS = ("point_date", "started_at", "ended_at", "active_seconds", "validation_summary", "rules_version")


def has_validated_movement(walk, now):
    if walk["rules_version"] not in TRUSTED_WALK_RULES or walk["ended_at"] > now:
        return False
    summary = walk["validation_summary"]
    moving = summary.get("accepted_moving_segments") if isinstance(summary, dict) else None
    return (type(moving) is int and moving > 0
        and walk["active_seconds"] is not None
        and 0 < walk["active_seconds"] <= (walk["ended_at"].astimezone(UTC) - walk["started_at"].astimezone(UTC)).total_seconds()
        and walk["point_date"] == local_date(walk["ended_at"]))
