from datetime import UTC

from django.conf import settings
from django.core.exceptions import ValidationError
from django.db import models
from django.db.models import F, Q


class Walk(models.Model):
    owner = models.ForeignKey(
        settings.AUTH_USER_MODEL, on_delete=models.PROTECT, related_name="walks"
    )
    request_id = models.UUIDField()
    request_fingerprint = models.CharField(max_length=64, editable=False)
    dogs = models.ManyToManyField("dogs.Dog", through="WalkDog", related_name="walks")
    started_at = models.DateTimeField()
    ended_at = models.DateTimeField()
    point_date = models.DateField()
    distance_m = models.DecimalField(max_digits=10, decimal_places=2)
    active_seconds = models.PositiveIntegerField(null=True, blank=True)
    points_awarded = models.PositiveSmallIntegerField(default=0)
    base_point_entry = models.OneToOneField(
        "rewards.PointEntry", null=True, blank=True, on_delete=models.PROTECT,
        related_name="base_walk",
    )
    net_distance_m = models.DecimalField(max_digits=10, decimal_places=2, null=True, blank=True)
    net_point_entry = models.OneToOneField(
        "rewards.PointEntry", null=True, blank=True, on_delete=models.PROTECT,
        related_name="net_walk",
    )
    net_settled_at = models.DateTimeField(null=True, blank=True)
    rules_version = models.CharField(max_length=40, null=True, blank=True)
    validation_summary = models.JSONField(null=True, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ("-ended_at", "-id")
        indexes = [
            models.Index(fields=("owner", "point_date"), name="walk_owner_point_date"),
            models.Index(fields=("owner", "ended_at"), name="walk_owner_ended_at"),
        ]
        constraints = [
            models.UniqueConstraint(
                fields=("owner", "request_id"), name="walk_owner_request_unique"
            ),
            models.CheckConstraint(
                condition=models.Q(ended_at__gt=models.F("started_at")),
                name="walk_end_after_start",
            ),
            models.CheckConstraint(
                condition=models.Q(distance_m__gte=0), name="walk_distance_nonnegative"
            ),
            models.CheckConstraint(
                condition=models.Q(points_awarded__lte=40), name="walk_points_at_most_40"
            ),
            models.CheckConstraint(condition=Q(net_distance_m__isnull=True) | Q(net_distance_m__gte=0), name="walk_net_distance_nonnegative"),
            models.CheckConstraint(condition=Q(net_point_entry__isnull=True) | Q(net_settled_at__isnull=False, net_distance_m__isnull=False, net_distance_m__gt=0), name="walk_net_award_settled"),
        ]

    def clean(self):
        super().clean()
        if self.active_seconds is not None and self.started_at and self.ended_at:
            if self.active_seconds > (self.ended_at.astimezone(UTC) - self.started_at.astimezone(UTC)).total_seconds():
                raise ValidationError({"active_seconds": "Active time cannot exceed elapsed time."})
        for field in ("base_point_entry", "net_point_entry"):
            entry = getattr(self, field) if getattr(self, field + "_id") else None
            if entry and (entry.user_id != self.owner_id or entry.type != "EARN" or entry.amount <= 0):
                raise ValidationError({field: "The earning must belong to this walk's owner."})
        if self.base_point_entry_id and self.base_point_entry.amount != self.points_awarded:
            raise ValidationError({"points_awarded": "Base points must match their ledger entry."})

    def __str__(self):
        return f"{self.owner}: {self.distance_m} m, {self.points_awarded} points"


class WalkDogQuerySet(models.QuerySet):
    def bulk_create(self, objs, **kwargs):
        # Preserve the existing .dogs.add/set interface for new associations.
        # Historical migrations use historical models and never infer old names.
        objs = list(objs)
        dog_model = self.model._meta.get_field("dog").remote_field.model
        dogs = dog_model.objects.using(self.db).in_bulk({obj.dog_id for obj in objs if obj.dog_id})
        for obj in objs:
            if obj.dog_id_snapshot is None and obj.dog_id:
                obj.dog_id_snapshot = obj.dog_id
                obj.dog_name_snapshot = dogs[obj.dog_id].name
        return super().bulk_create(objs, **kwargs)


class WalkDog(models.Model):
    walk = models.ForeignKey(Walk, on_delete=models.CASCADE, related_name="participants")
    dog = models.ForeignKey("dogs.Dog", null=True, blank=True, on_delete=models.SET_NULL, related_name="walk_participations")
    dog_id_snapshot = models.BigIntegerField()
    dog_name_snapshot = models.CharField(max_length=100, null=True, blank=True)
    active_seconds = models.PositiveIntegerField(null=True, blank=True)
    distance_m = models.DecimalField(max_digits=10, decimal_places=2, null=True, blank=True)

    objects = WalkDogQuerySet.as_manager()

    class Meta:
        db_table = "walks_walk_dogs"
        constraints = [
            models.UniqueConstraint(fields=("walk", "dog_id_snapshot"), name="walk_dog_snapshot_unique"),
            models.CheckConstraint(condition=Q(dog_id_snapshot__gt=0), name="walk_dog_snapshot_positive"),
            models.CheckConstraint(condition=Q(distance_m__isnull=True) | Q(distance_m__gte=0), name="walk_dog_distance_nonnegative"),
        ]
        indexes = [models.Index(fields=("dog_id_snapshot", "walk"), name="walk_dog_history")]

    def save(self, *args, **kwargs):
        if self.dog_id_snapshot is None and self.dog_id:
            self.dog_id_snapshot = self.dog_id
            self.dog_name_snapshot = self.dog.name
        return super().save(*args, **kwargs)

    def clean(self):
        super().clean()
        if self.dog_id and self.dog_id != self.dog_id_snapshot:
            raise ValidationError({"dog_id_snapshot": "The participant must identify the same dog."})
        if self._state.adding and self.dog_id and self.walk_id and self.dog.owner_id != self.walk.owner_id:
            raise ValidationError({"dog": "Only the walk owner's dogs can be confirmed."})
        if self.walk_id and self.active_seconds is not None and self.walk.active_seconds is not None and self.active_seconds > self.walk.active_seconds:
            raise ValidationError({"active_seconds": "Dog activity cannot exceed the walk's validated activity."})


class WalkSession(models.Model):
    class State(models.TextChoices):
        RECORDING = "RECORDING", "Recording"
        PAUSED = "PAUSED", "Paused"
        FINISHED = "FINISHED", "Finished"
        TIMED_OUT = "TIMED_OUT", "Timed out"
        CANCELLED = "CANCELLED", "Cancelled"

    owner = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.PROTECT, related_name="walk_sessions")
    request_id = models.UUIDField()
    walk = models.OneToOneField(Walk, null=True, blank=True, on_delete=models.PROTECT, related_name="session")
    state = models.CharField(max_length=12, choices=State.choices)
    started_at = models.DateTimeField()
    ended_at = models.DateTimeField(null=True, blank=True)
    heartbeat_at = models.DateTimeField()
    last_latitude = models.DecimalField(max_digits=9, decimal_places=6, null=True, blank=True)
    last_longitude = models.DecimalField(max_digits=9, decimal_places=6, null=True, blank=True)
    last_accuracy_m = models.DecimalField(max_digits=7, decimal_places=2, null=True, blank=True)
    location_recorded_at = models.DateTimeField(null=True, blank=True)
    location_expires_at = models.DateTimeField(null=True, blank=True)
    verified_active_seconds = models.PositiveIntegerField(default=0)
    verified_distance_m = models.DecimalField(max_digits=10, decimal_places=2, default=0)
    net_consent_at = models.DateTimeField(null=True, blank=True)
    net_consent_withdrawn_at = models.DateTimeField(null=True, blank=True)
    validation_version = models.CharField(max_length=40)

    class Meta:
        constraints = [
            models.UniqueConstraint(fields=("owner", "request_id"), name="session_owner_request_unique"),
            models.CheckConstraint(condition=Q(state__in=("RECORDING", "PAUSED"), ended_at__isnull=True) | Q(state__in=("FINISHED", "TIMED_OUT", "CANCELLED"), ended_at__isnull=False, ended_at__gte=F("started_at")), name="session_state_time_shape"),
            models.CheckConstraint(condition=Q(verified_distance_m__gte=0), name="session_distance_nonnegative"),
            models.CheckConstraint(condition=Q(last_latitude__isnull=True, last_longitude__isnull=True) | Q(last_latitude__isnull=False, last_longitude__isnull=False, last_latitude__gte=-90, last_latitude__lte=90, last_longitude__gte=-180, last_longitude__lte=180), name="session_coordinates_valid"),
            models.CheckConstraint(condition=Q(location_expires_at__isnull=True, location_recorded_at__isnull=True) | Q(location_expires_at__isnull=False, location_recorded_at__isnull=False, location_expires_at__gt=F("location_recorded_at")), name="session_presence_expiry_valid"),
            models.CheckConstraint(condition=Q(net_consent_withdrawn_at__isnull=True) | Q(net_consent_at__isnull=False, net_consent_withdrawn_at__gte=F("net_consent_at")), name="session_consent_time_valid"),
        ]
        indexes = [
            models.Index(fields=("state", "heartbeat_at"), name="session_state_heartbeat"),
            models.Index(fields=("location_expires_at",), name="session_location_expiry"),
        ]

    def clean(self):
        super().clean()
        if self.walk_id and self.walk.owner_id != self.owner_id:
            raise ValidationError({"walk": "A session and walk must belong to the same owner."})


class LocationSample(models.Model):
    """Dormant short-lived evidence; no endpoint collects GPS until retention is agreed."""
    owner = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.PROTECT, related_name="location_samples")
    session = models.ForeignKey(WalkSession, null=True, blank=True, on_delete=models.CASCADE, related_name="samples")
    checkin = models.ForeignKey("checkins.CheckIn", null=True, blank=True, on_delete=models.CASCADE, related_name="samples")
    checkin_attempt_id = models.UUIDField(null=True, blank=True)
    stream_id = models.UUIDField()
    sequence = models.PositiveBigIntegerField()
    segment_id = models.PositiveIntegerField()
    recorded_at = models.DateTimeField()
    received_at = models.DateTimeField()
    latitude = models.DecimalField(max_digits=9, decimal_places=6)
    longitude = models.DecimalField(max_digits=9, decimal_places=6)
    accuracy_m = models.DecimalField(max_digits=7, decimal_places=2)
    speed_mps = models.DecimalField(max_digits=7, decimal_places=2, null=True, blank=True)
    source_flags = models.JSONField(default=dict)
    accepted = models.BooleanField(default=False)
    rejection_reason = models.CharField(max_length=80, blank=True)

    class Meta:
        constraints = [
            models.UniqueConstraint(fields=("owner", "stream_id", "sequence"), name="sample_stream_sequence_unique"),
            models.CheckConstraint(condition=Q(session__isnull=False) | Q(checkin__isnull=False), name="sample_purpose_required"),
            models.CheckConstraint(condition=Q(checkin__isnull=True, checkin_attempt_id__isnull=True) | Q(checkin__isnull=False, checkin_attempt_id__isnull=False), name="sample_checkin_attempt_shape"),
            models.CheckConstraint(condition=Q(latitude__gte=-90, latitude__lte=90, longitude__gte=-180, longitude__lte=180), name="sample_coordinates_valid"),
            models.CheckConstraint(condition=Q(accuracy_m__gte=0), name="sample_accuracy_nonnegative"),
            models.CheckConstraint(condition=Q(speed_mps__isnull=True) | Q(speed_mps__gte=0), name="sample_speed_nonnegative"),
            models.CheckConstraint(condition=Q(accepted=False) | Q(rejection_reason=""), name="sample_accepted_no_rejection"),
        ]
        indexes = [
            models.Index(fields=("owner", "recorded_at"), name="sample_owner_time"),
            models.Index(fields=("session", "recorded_at"), name="sample_session_time"),
            models.Index(fields=("checkin", "recorded_at"), name="sample_checkin_time"),
            models.Index(fields=("received_at",), name="sample_received_at"),
        ]

    def clean(self):
        super().clean()
        for field in ("session", "checkin"):
            if getattr(self, field + "_id") and getattr(self, field).owner_id != self.owner_id:
                raise ValidationError({field: "GPS evidence must belong to the same owner."})
        if self.checkin_id and self.checkin_attempt_id != self.checkin.attempt_id:
            raise ValidationError({"checkin_attempt_id": "The check-in attempt has changed."})


class NetWalkInterval(models.Model):
    session_low = models.ForeignKey(WalkSession, on_delete=models.PROTECT, related_name="net_intervals_low")
    session_high = models.ForeignKey(WalkSession, on_delete=models.PROTECT, related_name="net_intervals_high")
    started_at = models.DateTimeField()
    ended_at = models.DateTimeField()
    low_distance_m = models.DecimalField(max_digits=10, decimal_places=2)
    high_distance_m = models.DecimalField(max_digits=10, decimal_places=2)
    rules_version = models.CharField(max_length=40)
    validation_summary = models.JSONField(default=dict)
    verified_at = models.DateTimeField()

    class Meta:
        constraints = [
            models.UniqueConstraint(fields=("session_low", "session_high", "started_at", "ended_at"), name="net_interval_identity_unique"),
            models.CheckConstraint(condition=Q(session_low__lt=F("session_high")), name="net_session_pair_ordered"),
            models.CheckConstraint(condition=Q(ended_at__gt=F("started_at")), name="net_interval_end_after_start"),
            models.CheckConstraint(condition=Q(low_distance_m__gte=0, high_distance_m__gte=0), name="net_distances_nonnegative"),
        ]
        indexes = [models.Index(fields=("session_high", "started_at"), name="net_high_session_time")]

    def clean(self):
        super().clean()
        if not (self.session_low_id and self.session_high_id and self.started_at and self.ended_at):
            return
        sessions = (self.session_low, self.session_high)
        if sessions[0].owner_id == sessions[1].owner_id:
            raise ValidationError("Net-walking requires two different owners.")
        for session in sessions:
            if self.started_at < session.started_at or (session.ended_at and self.ended_at > session.ended_at):
                raise ValidationError("The interval must be inside both sessions.")
            if session.net_consent_at is None or session.net_consent_at > self.started_at or (session.net_consent_withdrawn_at and session.net_consent_withdrawn_at < self.ended_at):
                raise ValidationError("Both owners must consent throughout the interval.")
        if type(self).objects.filter(session_low_id=self.session_low_id, session_high_id=self.session_high_id, started_at__lt=self.ended_at, ended_at__gt=self.started_at).exclude(pk=self.pk).exists():
            raise ValidationError("Intervals for the same session pair cannot overlap.")
