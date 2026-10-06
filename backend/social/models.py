from django.conf import settings
from django.db import models
from django.db.models import F, Q


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
        constraints = [models.CheckConstraint(condition=~Q(sender=F("recipient")), name="net_invitation_not_self")]
        indexes = [
            # Mutable status must not be part of a foreign-key support index:
            # MySQL then rechecks both parent owners during a status update,
            # inverting the normal owner-before-invitation lock order.
            models.Index(fields=("sender",), name="net_inv_sender_owner"),
            models.Index(fields=("recipient",), name="net_inv_recipient_owner"),
        ]
