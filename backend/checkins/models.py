import uuid

from django.conf import settings
from django.db import models
from django.db.models import F, Q

from rewards.policy import CHECKIN_POINTS, CHECKIN_RADIUS_M, RULES_VERSION
from venues.models import Venue


class CheckInWalk(models.Model):
    """Venue evidence follows a manual walk, independently of social presence."""

    class State(models.TextChoices):
        RECORDING = "RECORDING", "Recording"
        PAUSED = "PAUSED", "Paused"
        FINISHED = "FINISHED", "Finished"
        CANCELLED = "CANCELLED", "Cancelled"

    owner = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.PROTECT)
    request_id = models.UUIDField()
    started_at = models.DateTimeField()
    ended_at = models.DateTimeField(null=True, blank=True)
    state = models.CharField(max_length=12, choices=State.choices)
    walk = models.OneToOneField("walks.Walk", null=True, blank=True, on_delete=models.PROTECT,
                               related_name="checkin_context")
    settled_at = models.DateTimeField(null=True, blank=True)

    class Meta:
        constraints = [
            models.UniqueConstraint(fields=("owner", "request_id"), name="checkin_walk_request_unique"),
            models.CheckConstraint(condition=Q(state__in=("RECORDING", "PAUSED"), ended_at__isnull=True)
                                   | Q(state__in=("FINISHED", "CANCELLED"), ended_at__isnull=False, ended_at__gte=F("started_at")),
                                   name="checkin_walk_state_shape"),
            models.CheckConstraint(condition=Q(settled_at__isnull=True) | Q(walk__isnull=False, state="FINISHED"),
                                   name="checkin_walk_settled_shape"),
        ]


class CheckIn(models.Model):
    """One shared map/Quest opportunity, not a client-authored GPS verdict."""

    owner = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.PROTECT)
    walk_context = models.ForeignKey(CheckInWalk, null=True, blank=True, on_delete=models.PROTECT,
                                     related_name="checkins")
    venue = models.ForeignKey(Venue, null=True, blank=True, on_delete=models.PROTECT)
    venue_name_snapshot = models.CharField(max_length=100, blank=True)
    local_date = models.DateField()
    category_slot = models.CharField(max_length=16, choices=Venue.Kind.choices)
    attempt_id = models.UUIDField(default=uuid.uuid4, unique=True)
    radius_m = models.PositiveIntegerField(default=CHECKIN_RADIUS_M)
    center_latitude = models.DecimalField(max_digits=9, decimal_places=6, null=True, blank=True)
    center_longitude = models.DecimalField(max_digits=9, decimal_places=6, null=True, blank=True)
    required_seconds = models.PositiveIntegerField()
    verified_seconds = models.PositiveIntegerField(default=0)
    last_recorded_at = models.DateTimeField(null=True, blank=True)
    last_sequence = models.PositiveBigIntegerField(null=True, blank=True)
    last_captured_at = models.DateTimeField(null=True, blank=True)
    last_sample_fingerprint = models.CharField(max_length=64, blank=True)
    last_latitude = models.DecimalField(max_digits=9, decimal_places=6, null=True, blank=True)
    last_longitude = models.DecimalField(max_digits=9, decimal_places=6, null=True, blank=True)
    last_verified_at = models.DateTimeField(null=True, blank=True)
    started_at = models.DateTimeField(null=True, blank=True)
    ready_at = models.DateTimeField(null=True, blank=True)
    expires_at = models.DateTimeField()
    promised_points = models.PositiveIntegerField(default=CHECKIN_POINTS)
    point_entry = models.OneToOneField("rewards.PointEntry", null=True, blank=True, on_delete=models.PROTECT)
    collected_at = models.DateTimeField(null=True, blank=True)
    rules_version = models.CharField(max_length=40, default=RULES_VERSION)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        constraints = [
            models.UniqueConstraint(fields=("walk_context", "venue"), name="checkin_walk_venue_unique"),
            models.CheckConstraint(condition=Q(category_slot__in=Venue.Kind.values), name="checkin_category_known"),
            models.CheckConstraint(condition=Q(required_seconds__gt=0, radius_m__gt=0, promised_points__gt=0), name="checkin_positive_targets"),
            models.CheckConstraint(condition=Q(verified_seconds__lte=F("required_seconds")), name="checkin_progress_bounded"),
            models.CheckConstraint(condition=Q(started_at__isnull=True) | Q(venue__isnull=False, center_latitude__isnull=False, center_longitude__isnull=False, expires_at__gt=F("started_at")), name="checkin_started_shape"),
            models.CheckConstraint(condition=Q(ready_at__isnull=True) | Q(started_at__isnull=False, verified_seconds=F("required_seconds")), name="checkin_ready_shape"),
            models.CheckConstraint(condition=Q(ready_at__isnull=True) | Q(started_at__isnull=False, ready_at__gte=F("started_at"), ready_at__lte=F("expires_at")), name="checkin_ready_time_valid"),
            models.CheckConstraint(condition=Q(point_entry__isnull=True, collected_at__isnull=True) | Q(point_entry__isnull=False, collected_at__isnull=False, ready_at__isnull=False), name="checkin_collection_shape"),
            models.CheckConstraint(condition=Q(collected_at__isnull=True) | Q(ready_at__isnull=False, collected_at__gte=F("ready_at")), name="checkin_collection_time_valid"),
            models.CheckConstraint(condition=Q(center_latitude__isnull=True) | Q(center_latitude__gte=-90, center_latitude__lte=90), name="checkin_latitude_range"),
            models.CheckConstraint(condition=Q(center_longitude__isnull=True) | Q(center_longitude__gte=-180, center_longitude__lte=180), name="checkin_longitude_range"),
        ]
        indexes = [models.Index(fields=("owner", "collected_at"), name="checkin_owner_collection")]

    @property
    def status(self):
        if self.point_entry_id:
            return "COLLECTED"
        return "READY" if self.ready_at else "IN_PROGRESS"

    @property
    def reward_category(self):
        return "PARTNER" if self.category_slot in ("CAFE", "RESTAURANT") else self.category_slot

    @property
    def is_accumulating(self):
        return bool(self.last_verified_at and not self.ready_at and not self.point_entry_id
                    and self.walk_context_id and self.walk_context.state == CheckInWalk.State.RECORDING)
