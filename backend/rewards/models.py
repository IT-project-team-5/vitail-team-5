import calendar
import uuid
from datetime import datetime, time, timedelta
from zoneinfo import ZoneInfo

from django.conf import settings
from django.core.exceptions import ValidationError
from django.core.validators import MinValueValidator
from django.db import models
from django.utils import timezone


def add_twelve_months(value):
    """Return the same local date/time twelve calendar months later."""
    try:
        return value.replace(year=value.year + 1)
    except ValueError:
        # February 29 becomes the final valid day in February next year.
        last_day = calendar.monthrange(value.year + 1, value.month)[1]
        return value.replace(year=value.year + 1, day=last_day)


def default_point_expiry():
    return add_twelve_months(timezone.now())


def default_redemption_expiry():
    """Pending redemptions expire at the next local midnight."""
    zone = ZoneInfo("Australia/Melbourne")
    local_now = timezone.localtime(timezone.now(), timezone=zone)
    tomorrow = local_now.date() + timedelta(days=1)
    return timezone.make_aware(datetime.combine(tomorrow, time.min), timezone=zone)


def redemption_order_date():
    return timezone.localdate(timezone=ZoneInfo("Australia/Melbourne"))


def new_redemption_reference():
    return f"RDM-{uuid.uuid4().hex[:12].upper()}"


class PointEntry(models.Model):
    class EarnCategory(models.TextChoices):
        WALK = "WALK", "Walk"
        NET_WALK = "NET_WALK", "Net-walking"
        DAILY_GOAL = "DAILY_GOAL", "Daily goal"
        CHECK_IN = "CHECK_IN", "Check-in"
        STREAK = "STREAK", "Streak"
        BIRTHDAY = "BIRTHDAY", "Birthday"
        DOCUMENT = "DOCUMENT", "Document"

    class Type(models.TextChoices):
        EARN = "EARN", "Earn"
        SPEND = "SPEND", "Spend"
        REFUND = "REFUND", "Refund"
        EXPIRE = "EXPIRE", "Expire"
        ADMIN = "ADMIN", "Admin grant"

    user = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.PROTECT,
        related_name="point_entries",
    )
    amount = models.IntegerField()
    remaining_points = models.PositiveIntegerField(default=0)
    type = models.CharField(max_length=10, choices=Type.choices, default=Type.ADMIN)
    source_reference = models.CharField(
        max_length=120,
        unique=True,
        null=True,
        blank=True,
        help_text="Stable idempotency key for the event that created this entry.",
    )
    expires_at = models.DateTimeField(null=True, blank=True)
    earn_category = models.CharField(max_length=20, choices=EarnCategory.choices, null=True, blank=True)
    earned_on = models.DateField(null=True, blank=True)
    rules_version = models.CharField(max_length=40, null=True, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ("created_at", "id")
        indexes = [
            models.Index(fields=("user", "expires_at"), name="points_owner_expiry"),
            models.Index(fields=("user", "earned_on", "earn_category"), name="points_owner_day_source"),
        ]
        constraints = [
            models.CheckConstraint(
                condition=models.Q(earn_category__isnull=True, earned_on__isnull=True, rules_version__isnull=True)
                | (models.Q(type="EARN", earn_category__isnull=False, earn_category__in=["WALK", "NET_WALK", "DAILY_GOAL", "CHECK_IN", "STREAK", "BIRTHDAY", "DOCUMENT"], earned_on__isnull=False, rules_version__isnull=False) & ~models.Q(rules_version="")),
                name="point_entry_earn_source_shape",
            ),
            models.CheckConstraint(
                condition=(
                    models.Q(
                        amount__gt=0,
                        expires_at__isnull=False,
                        type__in=["EARN", "REFUND", "ADMIN"],
                    )
                    & models.Q(remaining_points__lte=models.F("amount"))
                )
                | models.Q(
                    amount__lt=0,
                    remaining_points=0,
                    expires_at__isnull=True,
                    type__in=["SPEND", "EXPIRE"],
                ),
                name="point_entry_credit_or_debit_shape",
            ),
        ]

    def clean(self):
        super().clean()
        if self.amount is None:
            return
        if self.amount == 0:
            raise ValidationError({"amount": "Point amount cannot be zero."})
        if self.amount > 0:
            if self.remaining_points > self.amount:
                raise ValidationError(
                    {"remaining_points": "Remaining points cannot exceed amount."}
                )
            if self.expires_at is None:
                raise ValidationError({"expires_at": "Credit entries must expire."})
        elif self.remaining_points != 0:
            raise ValidationError(
                {"remaining_points": "Debit entries cannot have remaining points."}
            )

    def __str__(self):
        return f"{self.user}: {self.amount:+d} ({self.type})"


class Reward(models.Model):
    venue = models.ForeignKey(
        "venues.Venue",
        on_delete=models.PROTECT,
        related_name="rewards",
    )
    name = models.CharField(max_length=100)
    description = models.TextField(blank=True)
    photo = models.FileField(upload_to="rewards/photos/", max_length=255, blank=True)
    point_cost = models.PositiveIntegerField(validators=[MinValueValidator(1)])
    is_available = models.BooleanField(default=True)
    starts_at = models.DateTimeField(null=True, blank=True)
    ends_at = models.DateTimeField(null=True, blank=True)
    daily_quantity_limit = models.PositiveIntegerField(null=True, blank=True, validators=[MinValueValidator(1)])
    terms = models.TextField(blank=True)
    requires_store_purchase = models.BooleanField(default=False)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    class Meta:
        ordering = ("venue__name", "point_cost", "name", "id")
        indexes = [models.Index(fields=("venue", "is_available"), name="reward_venue_available_idx")]
        constraints = [
            models.CheckConstraint(
                condition=models.Q(point_cost__gt=0),
                name="reward_point_cost_positive",
            ),
            models.CheckConstraint(condition=models.Q(daily_quantity_limit__isnull=True) | models.Q(daily_quantity_limit__gt=0), name="reward_daily_limit_positive"),
            models.CheckConstraint(condition=models.Q(starts_at__isnull=True) | models.Q(ends_at__isnull=True) | models.Q(ends_at__gt=models.F("starts_at")), name="reward_window_ordered"),
        ]

    def clean(self):
        super().clean()
        if self.starts_at and self.ends_at and self.ends_at <= self.starts_at:
            raise ValidationError({"ends_at": "End time must be after start time."})
        if self.venue_id and (not self.venue.manager_user_id or self.venue.manager_user.role != "CAFE" or not self.venue.is_partner):
            raise ValidationError(
                {"venue": "Products require a partner venue managed by a café account."}
            )

    def __str__(self):
        return f"{self.name} ({self.point_cost} points)"


class Redemption(models.Model):
    class Status(models.TextChoices):
        PENDING = "PENDING", "Pending"
        COLLECTED = "COLLECTED", "Collected"
        EXPIRED = "EXPIRED", "Expired"
        CANCELLED = "CANCELLED", "Cancelled"

    owner_user = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.PROTECT,
        related_name="redemptions",
    )
    reward = models.ForeignKey(
        Reward,
        on_delete=models.PROTECT,
        related_name="redemptions",
    )
    venue = models.ForeignKey("venues.Venue", on_delete=models.PROTECT, related_name="redemptions")
    reference_number = models.CharField(
        max_length=20,
        unique=True,
        default=new_redemption_reference,
        editable=False,
    )
    reward_name_snapshot = models.CharField(max_length=100)
    owner_name_snapshot = models.CharField(max_length=100)
    cafe_name_snapshot = models.CharField(max_length=100)
    cafe_user = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.PROTECT,
        related_name="cafe_redemptions",
        help_text="Café responsible when ordered; later catalogue changes do not move orders.",
    )
    request_id = models.UUIDField(null=True, blank=True)
    request_fingerprint = models.CharField(max_length=64, null=True, blank=True)
    terms_snapshot = models.TextField(blank=True)
    eligibility_snapshot = models.JSONField(default=dict, blank=True)
    order_date = models.DateField(default=redemption_order_date)
    spend_entry = models.OneToOneField(PointEntry, null=True, blank=True, on_delete=models.PROTECT, related_name="spent_redemption")
    refund_entry = models.OneToOneField(PointEntry, null=True, blank=True, on_delete=models.PROTECT, related_name="refunded_redemption")
    feed_cursor = models.PositiveBigIntegerField(default=0)
    point_cost_snapshot = models.PositiveIntegerField()
    status = models.CharField(
        max_length=10,
        choices=Status.choices,
        default=Status.PENDING,
    )
    created_at = models.DateTimeField(auto_now_add=True)
    collected_at = models.DateTimeField(null=True, blank=True)
    expires_at = models.DateTimeField(default=default_redemption_expiry)

    class Meta:
        ordering = ("-created_at", "-id")
        indexes = [
            models.Index(fields=("cafe_user", "feed_cursor"), name="redemption_cafe_cursor_idx"),
            models.Index(fields=("owner_user", "created_at"), name="redemption_owner_created_idx"),
            models.Index(fields=("reward", "order_date", "status"), name="redemption_reward_quota_idx"),
            models.Index(fields=("status", "expires_at"), name="redemption_status_expiry_idx"),
        ]
        constraints = [
            models.CheckConstraint(condition=models.Q(refund_entry__isnull=True) | models.Q(status__in=["EXPIRED", "CANCELLED"]), name="redemption_refund_terminal"),
            models.UniqueConstraint(
                fields=("owner_user", "request_id"),
                name="redemption_owner_request_unique",
            ),
            models.CheckConstraint(
                condition=models.Q(point_cost_snapshot__gt=0),
                name="redemption_point_cost_positive",
            ),
            models.CheckConstraint(
                condition=models.Q(
                    status="COLLECTED",
                    collected_at__isnull=False,
                )
                | (
                    ~models.Q(status="COLLECTED")
                    & models.Q(collected_at__isnull=True)
                ),
                name="redemption_collected_timestamp_matches_status",
            ),
        ]

    def clean(self):
        super().clean()
        if self.owner_user_id and self.owner_user.role != self.owner_user.Role.OWNER:
            raise ValidationError(
                {"owner_user": "Redemptions can only belong to a dog owner."}
            )
        if self.point_cost_snapshot is not None and self.point_cost_snapshot <= 0:
            raise ValidationError(
                {"point_cost_snapshot": "Point cost must be positive."}
            )

    def __str__(self):
        return f"{self.reference_number}: {self.reward_name_snapshot}"


class CafeOrderFeedState(models.Model):
    """Commit-ordered cursor; canonical orders retain their latest change."""

    cafe_user = models.OneToOneField(
        settings.AUTH_USER_MODEL, on_delete=models.CASCADE, primary_key=True
    )
    cursor = models.PositiveBigIntegerField(default=0)
