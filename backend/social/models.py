from django.conf import settings
from django.core.exceptions import ValidationError
from django.db import models
from django.db.models import F, Q


# Stable API values. The empty key means “use my uploaded profile photo”.
VIRTUAL_AVATAR_KEYS = ("", "walker", "paw", "dog", "coffee")

AVATAR_HAT_CODES = ("baseballCap", "beanie", "sunHat")
AVATAR_BANDANA_CODES = ("stripedBandana", "polkaDotBandana")
AVATAR_EXTRA_CODES = ("roundGlasses", "starBadge")
AVATAR_PRODUCT_CODES = (*AVATAR_HAT_CODES, *AVATAR_BANDANA_CODES, *AVATAR_EXTRA_CODES)


class AvatarPurchase(models.Model):
    """Permanent item ownership and the original wallet charge snapshot."""

    owner = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE, related_name="avatar_purchases")
    product_code = models.CharField(max_length=40)
    request_id = models.UUIDField(editable=False)
    point_cost_snapshot = models.PositiveIntegerField(editable=False)
    spend_entry = models.OneToOneField("rewards.PointEntry", on_delete=models.PROTECT, related_name="avatar_purchase", editable=False)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        constraints = [
            models.UniqueConstraint(fields=("owner", "product_code"), name="avatar_purchase_owner_product"),
            models.UniqueConstraint(fields=("owner", "request_id"), name="avatar_purchase_owner_request"),
            models.CheckConstraint(condition=Q(point_cost_snapshot__gt=0), name="avatar_purchase_cost_positive"),
            models.CheckConstraint(condition=Q(product_code__in=AVATAR_PRODUCT_CODES), name="avatar_purchase_product_known"),
        ]

    def save(self, *args, **kwargs):
        # Purchase snapshots cannot be rewritten through ordinary model saves.
        if not self._state.adding:
            fields = ("owner_id", "product_code", "request_id", "point_cost_snapshot", "spend_entry_id", "created_at")
            original = type(self).objects.filter(pk=self.pk).values(*fields).first()
            if original and any(original[field] != getattr(self, field) for field in fields):
                raise ValidationError("Avatar purchase records are immutable.")
        super().save(*args, **kwargs)


class AvatarPurchaseRequest(models.Model):
    """Tracks every UUID, including no-charge requests for an owned item."""

    owner = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE, related_name="avatar_purchase_requests")
    request_id = models.UUIDField(editable=False)
    purchase = models.ForeignKey(AvatarPurchase, on_delete=models.PROTECT, related_name="requests", editable=False)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        constraints = [
            models.UniqueConstraint(fields=("owner", "request_id"), name="avatar_request_owner_uuid"),
        ]


class AvatarWardrobe(models.Model):
    owner = models.OneToOneField(settings.AUTH_USER_MODEL, on_delete=models.CASCADE, related_name="avatar_wardrobe")
    hat_product_code = models.CharField(max_length=40, null=True, blank=True)
    bandana_product_code = models.CharField(max_length=40, null=True, blank=True)
    extra_product_code = models.CharField(max_length=40, null=True, blank=True)

    class Meta:
        constraints = [
            models.CheckConstraint(condition=Q(hat_product_code__isnull=True) | Q(hat_product_code__in=AVATAR_HAT_CODES), name="avatar_wardrobe_hat_known"),
            models.CheckConstraint(condition=Q(bandana_product_code__isnull=True) | Q(bandana_product_code__in=AVATAR_BANDANA_CODES), name="avatar_wardrobe_bandana_known"),
            models.CheckConstraint(condition=Q(extra_product_code__isnull=True) | Q(extra_product_code__in=AVATAR_EXTRA_CODES), name="avatar_wardrobe_extra_known"),
        ]


class Friendship(models.Model):
    class Status(models.TextChoices):
        PENDING = "PENDING", "Pending"
        ACCEPTED = "ACCEPTED", "Accepted"
        DECLINED = "DECLINED", "Declined"

    user_low = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE, related_name="friendships_low")
    user_high = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE, related_name="friendships_high")
    requested_by = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE, related_name="friend_requests_sent")
    status = models.CharField(max_length=10, choices=Status.choices, default=Status.PENDING)
    created_at = models.DateTimeField(auto_now_add=True)
    responded_at = models.DateTimeField(null=True, blank=True)

    class Meta:
        constraints = [
            models.UniqueConstraint(fields=("user_low", "user_high"), name="friendship_pair_unique"),
            models.CheckConstraint(condition=Q(user_low__lt=F("user_high")), name="friendship_pair_ordered"),
            models.CheckConstraint(condition=Q(requested_by=F("user_low")) | Q(requested_by=F("user_high")), name="friendship_requester_in_pair"),
            models.CheckConstraint(condition=Q(status="PENDING", responded_at__isnull=True) | Q(status__in=("ACCEPTED", "DECLINED"), responded_at__isnull=False), name="friendship_response_shape"),
        ]
        indexes = [models.Index(fields=("user_high", "status"), name="friendship_high_status")]


class UserBlock(models.Model):
    blocker = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE, related_name="blocks_created")
    blocked = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE, related_name="blocks_received")
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        constraints = [
            models.UniqueConstraint(fields=("blocker", "blocked"), name="user_block_pair_unique"),
            models.CheckConstraint(condition=~Q(blocker=F("blocked")), name="user_block_not_self"),
        ]
        indexes = [models.Index(fields=("blocked", "blocker"), name="user_block_reverse")]


class NetWalkInvitation(models.Model):
    """Explicit, revocable consent for one pair of existing live walk sessions."""

    class Status(models.TextChoices):
        PENDING = "PENDING", "Pending"
        ACTIVE = "ACTIVE", "Walking together"
        DECLINED = "DECLINED", "Declined"
        ENDED = "ENDED", "Ended"
        EXPIRED = "EXPIRED", "Expired"
        CANCELLED = "CANCELLED", "Cancelled"

    sender = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE, related_name="net_invitations_sent")
    recipient = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.CASCADE, related_name="net_invitations_received")
    sender_session = models.ForeignKey("walks.WalkSession", on_delete=models.CASCADE, related_name="net_invitations_sent")
    recipient_session = models.ForeignKey("walks.WalkSession", on_delete=models.CASCADE, related_name="net_invitations_received")
    status = models.CharField(max_length=10, choices=Status.choices, default=Status.PENDING)
    created_at = models.DateTimeField(auto_now_add=True)
    expires_at = models.DateTimeField()
    accepted_at = models.DateTimeField(null=True, blank=True)
    ended_at = models.DateTimeField(null=True, blank=True)
    end_reason = models.CharField(max_length=40, blank=True)

    class Meta:
        constraints = [
            models.CheckConstraint(condition=~Q(sender=F("recipient")), name="net_invitation_not_self"),
            models.CheckConstraint(
                condition=(
                    Q(status="PENDING", accepted_at__isnull=True, ended_at__isnull=True)
                    | Q(status="ACTIVE", accepted_at__isnull=False, ended_at__isnull=True)
                    | Q(status="ENDED", accepted_at__isnull=False, ended_at__isnull=False)
                    | Q(
                        status__in=("DECLINED", "EXPIRED", "CANCELLED"),
                        accepted_at__isnull=True,
                        ended_at__isnull=False,
                    )
                ),
                name="net_invitation_status_time_shape",
            ),
            models.CheckConstraint(
                condition=Q(expires_at__gt=F("created_at")),
                name="net_invitation_expiry_after_create",
            ),
            models.CheckConstraint(
                condition=Q(accepted_at__isnull=True) | Q(accepted_at__gte=F("created_at")),
                name="net_invitation_accept_after_create",
            ),
            models.CheckConstraint(
                condition=(
                    Q(ended_at__isnull=True)
                    | Q(accepted_at__isnull=False, ended_at__gte=F("accepted_at"))
                    | Q(accepted_at__isnull=True, ended_at__gte=F("created_at"))
                ),
                name="net_invitation_end_chronological",
            ),
        ]
        indexes = [
            # Mutable status must not be part of a foreign-key support index:
            # MySQL then rechecks both parent owners during a status update,
            # inverting the normal owner-before-invitation lock order.
            models.Index(fields=("sender",), name="net_inv_sender_owner"),
            models.Index(fields=("recipient",), name="net_inv_recipient_owner"),
            models.Index(fields=("status", "sender"), name="net_inv_status_sender"),
            models.Index(fields=("status", "recipient"), name="net_inv_status_recipient"),
        ]
