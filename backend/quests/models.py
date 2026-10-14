from django.conf import settings
from django.db import models
from django.utils import timezone

from rewards.policy import local_date


class QuestDefinition(models.Model):
    """A small typed catalogue, not a second progress counter or point wallet.

    Enabling a catalogue entry only makes its existing capability visible. It
    does not activate unimplemented qualification rules or award any points.
    """

    class Code(models.TextChoices):
        DAILY_GOAL = "DAILY_GOAL", "Daily goal"
        STREAK = "STREAK", "Walking streak"
        BIRTHDAY = "BIRTHDAY", "Dog birthday"
        CHECK_IN = "CHECK_IN", "Venue check-in"
        DOCUMENTS = "DOCUMENTS", "Documents"

    code = models.CharField(max_length=20, choices=Code.choices, unique=True)
    title = models.CharField(max_length=100)
    description = models.CharField(max_length=500, blank=True)
    is_enabled = models.BooleanField(default=True)
    sort_order = models.PositiveSmallIntegerField(default=0)
    rules_version = models.CharField(max_length=40, default="2026-09-24")
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ("sort_order", "code")

    def __str__(self):
        return self.title


class QuestAward(models.Model):
    """Typed qualifications for explicit birthday and walking-streak collection."""

    class Kind(models.TextChoices):
        BIRTHDAY = "BIRTHDAY", "Birthday"
        DAILY_GOAL = "DAILY_GOAL", "Daily goal"
        STREAK = "STREAK", "Streak"

    owner = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.PROTECT, related_name="quest_awards")
    kind = models.CharField(max_length=20, choices=Kind.choices)
    dog = models.ForeignKey("dogs.Dog", null=True, on_delete=models.SET_NULL, related_name="quest_awards")
    dog_id_snapshot = models.PositiveBigIntegerField(null=True, blank=True)
    dog_name_snapshot = models.CharField(max_length=100, blank=True)
    year = models.PositiveSmallIntegerField(null=True, blank=True)
    qualification_key = models.CharField(max_length=120, unique=True)
    qualified_on = models.DateField(default=local_date)
    qualified_at = models.DateTimeField(default=timezone.now)
    run_start_date = models.DateField(null=True, blank=True)
    milestone_days = models.PositiveIntegerField(null=True, blank=True)
    promised_points = models.PositiveIntegerField(default=0)
    eligibility_snapshot = models.JSONField(default=dict)
    claim_expires_at = models.DateTimeField(null=True, blank=True)
    point_entry = models.OneToOneField("rewards.PointEntry", null=True, blank=True, on_delete=models.PROTECT, related_name="quest_award")
    rules_version = models.CharField(max_length=40)
    awarded_at = models.DateTimeField(null=True, blank=True)

    class Meta:
        ordering = ("-awarded_at", "-id")
        indexes = [models.Index(fields=("owner", "awarded_at"), name="quest_owner_collection")]
        constraints = [
            models.UniqueConstraint(fields=("kind", "dog_id_snapshot", "year"), name="quest_award_dog_year_unique"),
            models.UniqueConstraint(fields=("kind", "dog_id_snapshot", "qualified_on"), name="quest_award_dog_day_unique"),
            models.CheckConstraint(condition=~models.Q(qualification_key="") & models.Q(promised_points__gt=0), name="quest_qualification_required"),
            models.CheckConstraint(condition=models.Q(point_entry__isnull=True, awarded_at__isnull=True) | models.Q(point_entry__isnull=False, awarded_at__isnull=False), name="quest_collection_shape"),
            models.CheckConstraint(condition=(
                models.Q(kind="BIRTHDAY", dog_id_snapshot__isnull=False, year__isnull=False, run_start_date__isnull=True, milestone_days__isnull=True)
                | models.Q(kind="DAILY_GOAL", year__isnull=True, run_start_date__isnull=True, milestone_days__isnull=True)
                | models.Q(kind="STREAK", dog_id_snapshot__isnull=True, year__isnull=True, run_start_date__isnull=False, milestone_days__isnull=False, milestone_days__gt=0)
            ), name="quest_kind_shape"),
        ]
