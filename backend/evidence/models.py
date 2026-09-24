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
    event_date = models.DateField(null=True, blank=True)
    valid_from = models.DateField(null=True, blank=True)
    valid_to = models.DateField(null=True, blank=True)
    point_entry = models.OneToOneField("rewards.PointEntry", null=True, on_delete=models.PROTECT)
    collected_at = models.DateTimeField(null=True, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)

    class Meta:
        constraints = [models.UniqueConstraint(fields=("dog_id_snapshot", "kind", "entitlement_key"), name="evidence_entitlement_unique")]


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
    event_date = models.DateField(null=True, blank=True)
    valid_from = models.DateField(null=True, blank=True)
    valid_to = models.DateField(null=True, blank=True)
    file = models.FileField(storage=private_storage, blank=True, max_length=200)
    filename = models.CharField(max_length=150, blank=True)
    file_content_type = models.CharField(max_length=40, blank=True)
    file_sha256 = models.CharField(max_length=64, blank=True)
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
