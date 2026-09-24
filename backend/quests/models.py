from django.conf import settings
from django.db import models


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
    """Birthday qualification linked to the canonical point ledger.

    Dog identity and reward year are retained even if its profile is deleted.
    No independent balance or editable progress is stored here.
    """

    class Kind(models.TextChoices):
        BIRTHDAY = "BIRTHDAY", "Birthday"

    owner = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.PROTECT, related_name="quest_awards")
    kind = models.CharField(max_length=20, choices=Kind.choices)
    dog = models.ForeignKey("dogs.Dog", null=True, on_delete=models.SET_NULL, related_name="quest_awards")
    dog_id_snapshot = models.PositiveBigIntegerField()
    dog_name_snapshot = models.CharField(max_length=100)
    year = models.PositiveSmallIntegerField()
    point_entry = models.OneToOneField("rewards.PointEntry", on_delete=models.PROTECT, related_name="quest_award")
    rules_version = models.CharField(max_length=40)
    awarded_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ("-awarded_at", "-id")
        constraints = [
            models.UniqueConstraint(fields=("kind", "dog_id_snapshot", "year"), name="quest_award_dog_year_unique"),
        ]
