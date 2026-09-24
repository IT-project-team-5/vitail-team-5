import uuid

from django.conf import settings
from django.db import models
from django.db.models import F, Q

from rewards.policy import CHECKIN_POINTS, CHECKIN_RADIUS_M, RULES_VERSION
from venues.models import Venue


class CheckIn(models.Model):
    """One shared map/Quest opportunity, not a client-authored GPS verdict."""

    owner = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.PROTECT)
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
            models.UniqueConstraint(fields=("owner", "local_date", "category_slot"), name="checkin_owner_day_slot_unique"),
            models.CheckConstraint(condition=Q(category_slot__in=Venue.Kind.values), name="checkin_category_known"),
            models.CheckConstraint(condition=Q(required_seconds__gt=0, radius_m__gt=0, promised_points__gt=0), name="checkin_positive_targets"),
            models.CheckConstraint(condition=Q(verified_seconds__lte=F("required_seconds")), name="checkin_progress_bounded"),
            models.CheckConstraint(condition=Q(started_at__isnull=True) | Q(venue__isnull=False, center_latitude__isnull=False, center_longitude__isnull=False, expires_at__gt=F("started_at")), name="checkin_started_shape"),
            models.CheckConstraint(condition=Q(ready_at__isnull=True) | Q(started_at__isnull=False, verified_seconds=F("required_seconds")), name="checkin_ready_shape"),
            models.CheckConstraint(condition=Q(ready_at__isnull=True) | Q(started_at__isnull=False, ready_at__gte=F("started_at"), ready_at__lte=F("expires_at")), name="checkin_ready_time_valid"),
            models.CheckConstraint(condition=Q(point_entry__isnull=True, collected_at__isnull=True) | Q(point_entry__isnull=False, collected_at__isnull=False, ready_at__isnull=False), name="checkin_collection_shape"),
            models.CheckConstraint(condition=Q(collected_at__isnull=True) | Q(ready_at__isnull=False, collected_at__gte=F("ready_at"), collected_at__lt=F("expires_at")), name="checkin_collection_time_valid"),
            models.CheckConstraint(condition=Q(center_latitude__isnull=True) | Q(center_latitude__gte=-90, center_latitude__lte=90), name="checkin_latitude_range"),
            models.CheckConstraint(condition=Q(center_longitude__isnull=True) | Q(center_longitude__gte=-180, center_longitude__lte=180), name="checkin_longitude_range"),
        ]
        indexes = [models.Index(fields=("owner", "collected_at"), name="checkin_owner_collection")]

    @property
    def status(self):
        if self.point_entry_id:
            return "COLLECTED"
        return "READY" if self.ready_at else "IN_PROGRESS"
