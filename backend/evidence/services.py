import hashlib
import json
import uuid

from django.contrib.auth import get_user_model
from django.core.files.base import ContentFile
from django.db import transaction
from django.utils import timezone
from rest_framework.exceptions import APIException, ValidationError

from dogs.models import Dog
from quests.models import QuestDefinition
from rewards.models import PointEntry
from rewards.services import credit_points, get_balance

from .models import DocumentEntitlement, DocumentKind, DocumentSubmission, EvidenceFingerprint
from .serializers import DocumentSubmissionSerializer, first_anniversary
from .storage import private_storage

POINTS = {DocumentKind.COUNCIL: 300, DocumentKind.MICROCHIP: 300, DocumentKind.VET: 200}


class RequestConflict(APIException):
    status_code = 409
    default_detail = "This request was already used for different evidence."


class DocumentsUnavailable(APIException):
    status_code = 409
    default_detail = "Document submissions are currently unavailable. Your previous submissions are still available."
    default_code = "quest_disabled"


def request_fingerprint(data):
    fields = {key: value for key, value in data.items() if key not in {"request_id", "upload"}}
    upload = data.get("upload")
    if upload:
        fields["upload"] = {key: upload[key] for key in ("sha256", "filename", "content_type")}
    return hashlib.sha256(json.dumps(fields, sort_keys=True, default=str, separators=(",", ":")).encode()).hexdigest()


def _entitlement(owner, dog, data):
    kind = data["kind"]
    existing = list(DocumentEntitlement.objects.filter(dog_id_snapshot=dog.pk, kind=kind))
    if kind == DocumentKind.COUNCIL:
        if existing:
            return existing[0], False
        key = "lifetime"
    elif kind == DocumentKind.MICROCHIP:
        start, end = data["valid_from"], data["valid_to"]
        for item in existing:
            if item.valid_from < first_anniversary(start) and start < first_anniversary(item.valid_from):
                # Small changes to a submitted annual window never create another reward.
                return item, False
        if not start <= timezone.localdate() <= end:
            raise ValidationError("The annual registration period must cover today.")
        key = f"period:{start.isoformat()}"
    else:
        event = data["event_date"]
        same_visit = next((item for item in existing if item.event_date == event), None)
        if same_visit:
            return same_visit, False
        if sum(item.event_date.year == event.year for item in existing) >= 2:
            raise ValidationError("This dog has already received two vet check-up rewards for that calendar year.")
        if any(abs((item.event_date - event).days) < 60 for item in existing):
            raise ValidationError("Rewarded vet check-ups must be at least 60 days apart, including across New Year.")
        key = f"visit:{event.isoformat()}"
    return DocumentEntitlement.objects.create(
        owner=owner, dog=dog, dog_id_snapshot=dog.pk, kind=kind, entitlement_key=key,
        event_date=data.get("event_date"), valid_from=data.get("valid_from"), valid_to=data.get("valid_to"),
    ), True


def submit_document(*, owner, data):
    fingerprint = request_fingerprint(data)
    stored_name = None
    try:
        with transaction.atomic():
            owner = get_user_model().objects.select_for_update().get(pk=owner.pk)
            previous = DocumentSubmission.objects.filter(owner=owner, request_id=data["request_id"]).first()
            if previous:
                if previous.request_fingerprint != fingerprint:
                    raise RequestConflict()
                # Replay the original receipt, including its balance, unchanged.
                return previous.response_snapshot, False
            if not QuestDefinition.objects.filter(code=QuestDefinition.Code.DOCUMENTS, is_enabled=True).exists():
                raise DocumentsUnavailable()
            dog = Dog.objects.select_for_update().filter(pk=data["dog_id"], owner=owner).first()
            if dog is None:
                raise ValidationError({"dog_id": "Choose one of your dogs."})
            if data["kind"] == DocumentKind.VET and dog.date_of_birth and data["event_date"] < dog.date_of_birth:
                raise ValidationError({"event_date": "The check-up date cannot be before your dog's birthday."})
            entitlement, is_new = _entitlement(owner, dog, data)
            upload = data.get("upload")
            fingerprints = []
            if data["registration_number"]:
                number = " ".join(data["registration_number"].casefold().split())
                fingerprints.append((hashlib.sha256(("number:" + number).encode()).hexdigest(), False))
            if upload:
                fingerprints.append((upload["sha256"], True))
            for proof_hash, is_file in fingerprints:
                proof, created = EvidenceFingerprint.objects.get_or_create(
                    owner=owner, dog_id_snapshot=dog.pk, kind=data["kind"], fingerprint=proof_hash,
                    defaults={"entitlement": entitlement, "is_file": is_file},
                )
                if not created:
                    if is_file and proof.entitlement_id != entitlement.pk:
                        raise ValidationError("This file already supported an earlier reward. Add evidence for the new registration period or visit.")
            awarded = POINTS[data["kind"]] if is_new else 0
            if awarded:
                entitlement.point_entry = credit_points(
                    user=owner, amount=awarded, type=PointEntry.Type.EARN,
                    source_reference=f"document-entitlement:{entitlement.pk}",
                )
                entitlement.save(update_fields=["point_entry"])
            if upload:
                stored_name = private_storage.save(
                    f"documents/{owner.pk}/{uuid.uuid4().hex}{upload['extension']}", ContentFile(upload["bytes"])
                )
            submission = DocumentSubmission.objects.create(
                owner=owner, dog=dog, dog_id_snapshot=dog.pk, dog_name_snapshot=dog.name,
                kind=data["kind"], request_id=data["request_id"], request_fingerprint=fingerprint,
                entitlement=entitlement, registration_number=data["registration_number"],
                event_date=data.get("event_date"), valid_from=data.get("valid_from"), valid_to=data.get("valid_to"),
                file=stored_name or "", filename=upload["filename"] if upload else "",
                file_content_type=upload["content_type"] if upload else "",
                file_sha256=upload["sha256"] if upload else "", awarded_points=awarded,
            )
            receipt = {"submission": dict(DocumentSubmissionSerializer(submission).data),
                       "balance": get_balance(owner), "awarded_points": awarded, "created": True}
            submission.response_snapshot = receipt
            submission.save(update_fields=["response_snapshot"])
            return receipt, True
    except Exception:
        # Database rollback also rolls back the ledger; remove any uncommitted file.
        if stored_name:
            private_storage.delete(stored_name)
        raise


def eligibility_for(owner, dogs):
    today = timezone.localdate()
    rows = list(DocumentEntitlement.objects.filter(dog_id_snapshot__in=[dog.pk for dog in dogs]))
    result = []
    for dog in dogs:
        for kind in DocumentKind.values:
            earned = [row for row in rows if row.dog_id_snapshot == dog.pk and row.kind == kind]
            remaining = None
            can_earn = None
            if kind == DocumentKind.COUNCIL:
                can_earn = not earned
                message = "300 points once per dog." if can_earn else "Reward already received. You can add updated evidence for 0 points."
            elif kind == DocumentKind.MICROCHIP:
                message = "300 points per annual registration period. Re-uploading or overlapping a rewarded period adds no points."
            else:
                remaining = max(0, 2 - sum(row.event_date.year == today.year for row in earned))
                message = f"{remaining} of 2 rewards remaining for {today.year}. Visits must be at least 60 days apart."
            result.append({"dog_id": dog.pk, "kind": kind, "awards_count": len(earned),
                           "remaining_this_year": remaining, "can_earn": can_earn, "message": message})
    return result
