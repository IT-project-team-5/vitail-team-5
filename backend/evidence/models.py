from django.conf import settings
from django.db import models

from .storage import private_storage


class DocumentKind(models.TextChoices):
    COUNCIL = "COUNCIL_REGISTRATION", "Council registration"
    MICROCHIP = "MICROCHIP_REGISTRATION", "Microchip registration"
    VET = "VET_CHECKUP", "Vet check-up"


class DocumentEntitlement(models.Model):
    owner = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.PROTECT)
    dog = models.ForeignKey("dogs.Dog", null=True, on_delete=models.SET_NULL)
    dog_id_snapshot = models.PositiveBigIntegerField()
    kind = models.CharField(max_length=30, choices=DocumentKind.choices)
    entitlement_key = models.CharField(max_length=80)
    registration_year = models.PositiveSmallIntegerField(null=True, blank=True)
    event_date = models.DateField(null=True, blank=True)
    valid_from = models.DateField(null=True, blank=True)
    valid_to = models.DateField(null=True, blank=True)
    point_entry = models.OneToOneField("rewards.PointEntry", null=True, on_delete=models.PROTECT)
    collected_at = models.DateTimeField(null=True, blank=True)
    promised_points = models.PositiveIntegerField(default=0)
    rules_version = models.CharField(max_length=40, default="documents-2026-09-25")
    eligibility_status = models.CharField(max_length=12, choices=[("ELIGIBLE", "Eligible"), ("ON_HOLD", "On hold"), ("REJECTED", "Rejected")], default="ELIGIBLE")
    eligibility_reason = models.CharField(max_length=500, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        constraints = [
            models.UniqueConstraint(fields=("dog_id_snapshot", "kind", "entitlement_key"), name="evidence_entitlement_unique"),
            models.UniqueConstraint(fields=("dog_id_snapshot", "kind", "registration_year"), name="council_dog_year_unique"),
            models.CheckConstraint(condition=(models.Q(kind=DocumentKind.COUNCIL, registration_year__isnull=False, registration_year__gte=1)
                                              | (~models.Q(kind=DocumentKind.COUNCIL) & models.Q(registration_year__isnull=True))), name="council_reward_year_shape"),
            models.CheckConstraint(condition=models.Q(promised_points__gt=0), name="document_reward_positive"),
            models.CheckConstraint(condition=models.Q(point_entry__isnull=True, collected_at__isnull=True) | models.Q(point_entry__isnull=False, collected_at__isnull=False), name="document_collection_shape"),
            models.CheckConstraint(condition=models.Q(eligibility_status="ELIGIBLE") | (models.Q(eligibility_status__in=("ON_HOLD", "REJECTED")) & ~models.Q(eligibility_reason="")), name="document_eligibility_reason"),
        ]
        indexes = [models.Index(fields=("owner", "collected_at"), name="evidence_owner_collection"), models.Index(fields=("dog_id_snapshot", "kind", "event_date"), name="evidence_dog_event")]


class DocumentSubmission(models.Model):
    owner = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.PROTECT)
    dog = models.ForeignKey("dogs.Dog", null=True, on_delete=models.SET_NULL)
    dog_id_snapshot = models.PositiveBigIntegerField()
    dog_name_snapshot = models.CharField(max_length=100)
    kind = models.CharField(max_length=30, choices=DocumentKind.choices)
    status = models.CharField(max_length=20, default="SELF_REPORTED", editable=False)
    request_id = models.UUIDField()
    request_fingerprint = models.CharField(max_length=64)
    entitlement = models.ForeignKey(DocumentEntitlement, on_delete=models.PROTECT)
    registration_number = models.CharField(max_length=100, blank=True)
    council_name = models.CharField(max_length=100, blank=True)
    registration_year = models.PositiveSmallIntegerField(null=True, blank=True)
    event_date = models.DateField(null=True, blank=True)
    valid_from = models.DateField(null=True, blank=True)
    valid_to = models.DateField(null=True, blank=True)
    file = models.FileField(storage=private_storage, blank=True, max_length=200)
    filename = models.CharField(max_length=150, blank=True)
    file_content_type = models.CharField(max_length=40, blank=True)
    file_sha256 = models.CharField(max_length=64, blank=True)
    file_size_bytes = models.PositiveBigIntegerField(null=True, blank=True)
    audit_status = models.CharField(max_length=16, choices=[("NOT_REVIEWED", "Not reviewed"), ("VERIFIED", "Verified"), ("REJECTED", "Rejected")], default="NOT_REVIEWED")
    reviewed_by = models.ForeignKey(settings.AUTH_USER_MODEL, null=True, blank=True, on_delete=models.PROTECT, related_name="reviewed_evidence")
    reviewed_at = models.DateTimeField(null=True, blank=True)
    review_reason = models.CharField(max_length=500, blank=True)
    awarded_points = models.PositiveIntegerField(default=0)
    response_snapshot = models.JSONField(default=dict)
    submitted_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        ordering = ("-submitted_at", "-id")
        constraints = [models.UniqueConstraint(fields=("owner", "request_id"), name="evidence_owner_request_unique")]


class EvidenceFingerprint(models.Model):
    """Track proof reuse per dog; a family certificate may cover several dogs."""
    owner = models.ForeignKey(settings.AUTH_USER_MODEL, on_delete=models.PROTECT)
    kind = models.CharField(max_length=30, choices=DocumentKind.choices)
    fingerprint = models.CharField(max_length=64)
    dog_id_snapshot = models.PositiveBigIntegerField()
    entitlement = models.ForeignKey(DocumentEntitlement, on_delete=models.PROTECT)
    is_file = models.BooleanField()

    class Meta:
        constraints = [models.UniqueConstraint(fields=("owner", "dog_id_snapshot", "kind", "fingerprint"), name="evidence_fingerprint_unique")]
