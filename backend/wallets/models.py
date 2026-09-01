from django.conf import settings
from django.db import models


class PointLot(models.Model):
    """One earned batch of points.

    The wallet cannot be a single integer because points expire 12 months
    after they are earned (TECH_STACK.md, section 6). Balance is the sum of
    `amount_remaining` across unexpired lots; spending consumes lots
    oldest-expiry-first so points closest to expiry are used first.

    `WALK`, `GOAL`, `CHECKIN`, `VET`, `COUNCIL` and `STREAK` are the earning
    sources defined in TECH_STACK.md; those apps do not exist yet. `REFUND`
    covers a refunded redemption. `ADMIN_GRANT` is not in the original spec —
    it exists only so a Vitail admin can hand-credit test points from Django
    Admin while the real earning flows (walks, check-ins) are still unbuilt.
    """

    class Source(models.TextChoices):
        WALK = "WALK", "Walk"
        GOAL = "GOAL", "Daily goal"
        CHECKIN = "CHECKIN", "Venue check-in"
        VET = "VET", "Vet checkup"
        COUNCIL = "COUNCIL", "Council registration"
        STREAK = "STREAK", "Streak bonus"
        REFUND = "REFUND", "Redemption refund"
        ADMIN_GRANT = "ADMIN_GRANT", "Admin grant (dev/testing)"

    owner = models.ForeignKey(
        settings.AUTH_USER_MODEL, on_delete=models.CASCADE, related_name="point_lots"
    )
    source = models.CharField(max_length=20, choices=Source.choices)
    amount_earned = models.PositiveIntegerField()
    amount_remaining = models.PositiveIntegerField()
    earned_at = models.DateTimeField(auto_now_add=True)
    expires_at = models.DateTimeField()

    class Meta:
        ordering = ["expires_at", "earned_at"]

    def __str__(self):
        return f"{self.owner} +{self.amount_earned} ({self.source})"


class PointLedger(models.Model):
    """An immutable record of every points change. Never change a balance
    without writing the corresponding ledger entry (TECH_STACK.md, section 6).

    `lot` links an earn or spend to the specific PointLot it touched.
    `redemption_order` links a spend/refund to the order that caused it.
    Both are optional because not every future entry type will set both —
    e.g. a future WALK entry sets `lot` but has no order.
    """

    class EntryType(models.TextChoices):
        WALK = "WALK", "Walk"
        GOAL = "GOAL", "Daily goal"
        CHECKIN = "CHECKIN", "Venue check-in"
        VET = "VET", "Vet checkup"
        COUNCIL = "COUNCIL", "Council registration"
        STREAK = "STREAK", "Streak bonus"
        ADMIN_GRANT = "ADMIN_GRANT", "Admin grant (dev/testing)"
        REDEMPTION_SPEND = "REDEMPTION_SPEND", "Redemption spend"
        REDEMPTION_REFUND = "REDEMPTION_REFUND", "Redemption refund"

    owner = models.ForeignKey(
        settings.AUTH_USER_MODEL,
        on_delete=models.CASCADE,
        related_name="point_ledger_entries",
    )
    amount = models.IntegerField(help_text="Signed: positive earns, negative spends.")
    entry_type = models.CharField(max_length=20, choices=EntryType.choices)
    lot = models.ForeignKey(
        PointLot, on_delete=models.SET_NULL, null=True, blank=True, related_name="ledger_entries"
    )
    redemption_order = models.ForeignKey(
        "redemptions.RedemptionOrder",
        on_delete=models.SET_NULL,
        null=True,
        blank=True,
        related_name="ledger_entries",
    )
    reason = models.CharField(max_length=255, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ["-created_at"]

    def __str__(self):
        sign = "+" if self.amount >= 0 else ""
        return f"{self.owner} {sign}{self.amount} ({self.entry_type})"
