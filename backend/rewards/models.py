import calendar
import uuid
from datetime import datetime, time, timedelta

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
    local_now = timezone.localtime()
    tomorrow = local_now.date() + timedelta(days=1)
    return timezone.make_aware(datetime.combine(tomorrow, time.min))


def new_redemption_reference():
    return f"RDM-{uuid.uuid4().hex[:12].upper()}"


class PointEntry(models.Model):
    class Type(models.TextChoices):
        EARN = "EARN", "Earn"
        SPEND = "SPEND", "Spend"
        REFUND = "REFUND", "Refund"
        EXPIRE = "EXPIRE", "Expire"
        ADMIN = "ADMIN", "Admin grant"

    user = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.CASCADE,
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
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ("created_at", "id")
        constraints = [
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
    cafe_user = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.PROTECT,
        related_name="rewards",
    )
    name = models.CharField(max_length=100)
    description = models.TextField(blank=True)
    point_cost = models.PositiveIntegerField(validators=[MinValueValidator(1)])
    is_available = models.BooleanField(default=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ("cafe_user__display_name", "point_cost", "name", "id")
        constraints = [
            models.CheckConstraint(
                condition=models.Q(point_cost__gt=0),
                name="reward_point_cost_positive",
            )
        ]

    def clean(self):
        super().clean()
        if self.cafe_user_id and self.cafe_user.role != self.cafe_user.Role.CAFE:
            raise ValidationError(
                {"cafe_user": "Rewards can only belong to a café account."}
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
        on_delete=models.CASCADE,
        related_name="redemptions",
    )
    reward = models.ForeignKey(
        Reward,
        on_delete=models.PROTECT,
        related_name="redemptions",
    )
    reference_number = models.CharField(
        max_length=20,
        unique=True,
        default=new_redemption_reference,
        editable=False,
    )
    reward_name_snapshot = models.CharField(max_length=100)
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
        constraints = [
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

    @property
    def cafe_user(self):
        return self.reward.cafe_user

    def __str__(self):
        return f"{self.reference_number}: {self.reward_name_snapshot}"
