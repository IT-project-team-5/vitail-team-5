import hashlib
import uuid

from django.contrib.auth import get_user_model
from django.core.files.base import ContentFile
from django.db import transaction
from django.db.models import Q
from django.http import Http404
from django.utils import timezone
from rest_framework.exceptions import APIException, PermissionDenied, ValidationError

from accounts.photos import photo_url
from dogs.models import Dog
from quests.models import QuestDefinition
from rewards.models import PointEntry
from rewards.policy import DOCUMENT_POINTS as POINTS, MELBOURNE, local_date as _local_today
from rewards.services import credit_points, get_balance

from .models import DocumentEntitlement, DocumentKind, DocumentSubmission, EvidenceFingerprint
from .fingerprints import request_fingerprint
from .serializers import DocumentSubmissionSerializer
from .storage import private_storage


class RequestConflict(APIException):
    status_code = 409
    default_detail = "This request was already used for different evidence."


class DocumentsUnavailable(APIException):
    status_code = 409
    default_detail = "Document submissions are currently unavailable. Your previous submissions are still available."
    default_code = "quest_disabled"


def _lifetime_entitlement(rows):
    """Use historical awards first; never bypass an older held reservation."""
    return min(rows, key=lambda row: (row.point_entry_id is None, row.pk), default=None)


def _microchip_canonical_ids(rows):
    grouped = {}
    for row in rows:
        if row.kind == DocumentKind.MICROCHIP:
            grouped.setdefault(row.dog_id_snapshot, []).append(row)
    return {dog_id: _lifetime_entitlement(items).pk for dog_id, items in grouped.items()}


def _entitlement(owner, dog, data):
    kind = data["kind"]
    existing = list(DocumentEntitlement.objects.filter(dog_id_snapshot=dog.pk, kind=kind))
    if kind in {DocumentKind.COUNCIL, DocumentKind.MICROCHIP}:
        if existing:
            return _lifetime_entitlement(existing), False
        key = "lifetime"
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
        promised_points=POINTS[kind],
        rules_version="microchip-lifetime-2026-09-25" if kind == DocumentKind.MICROCHIP else "documents-2026-09-25",
        event_date=data.get("event_date"), valid_from=data.get("valid_from"), valid_to=data.get("valid_to"),
    ), True


def submit_document(*, owner, data):
    fingerprint = request_fingerprint(data)
    stored_name = None
    try:
        with transaction.atomic():
            owner = get_user_model().objects.select_for_update().get(pk=owner.pk)
            if owner.role != "OWNER" or not owner.is_active or owner.deleted_at:
                raise PermissionDenied("Only active dog owners can submit documents.")
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
            entitlement, _is_new = _entitlement(owner, dog, data)
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
                    if is_file and proof.entitlement_id != entitlement.pk and data["kind"] != DocumentKind.MICROCHIP:
                        raise ValidationError("This file already supported an earlier reward. Add evidence for the new registration period or visit.")
            awarded = 0
            if upload:
                stored_name = private_storage.save(
                    f"documents/{owner.pk}/{uuid.uuid4().hex}{upload['extension']}", ContentFile(upload["bytes"])
                )
            submission = DocumentSubmission.objects.create(
                owner=owner, dog=dog, dog_id_snapshot=dog.pk, dog_name_snapshot=dog.name,
                kind=data["kind"], request_id=data["request_id"], request_fingerprint=fingerprint,
                entitlement=entitlement, registration_number=data["registration_number"],
                council_name=data.get("council_name", ""), registration_year=data.get("registration_year"),
                event_date=data.get("event_date"), valid_from=data.get("valid_from"), valid_to=data.get("valid_to"),
                file=stored_name or "", filename=upload["filename"] if upload else "",
                file_content_type=upload["content_type"] if upload else "",
                file_sha256=upload["sha256"] if upload else "", awarded_points=awarded,
                file_size_bytes=len(upload["bytes"]) if upload else None,
            )
            receipt = {"submission": dict(DocumentSubmissionSerializer(submission).data),
                       "balance": get_balance(owner), "awarded_points": awarded, "created": True,
                       "entitlement_id": entitlement.pk, "reward_status": "COLLECTED" if entitlement.point_entry_id else "READY",
                       "reward_points": entitlement.promised_points, "collected_at": _iso(entitlement.collected_at)}
            submission.response_snapshot = receipt
            submission.save(update_fields=["response_snapshot"])
            return receipt, True
    except Exception:
        # Database rollback also rolls back the ledger; remove any uncommitted file.
        if stored_name:
            private_storage.delete(stored_name)
        raise


def _iso(value):
    return value.isoformat() if value else None


def _collection_receipt(entitlement, owner, created):
    return {"entitlement_id": entitlement.pk, "kind": entitlement.kind,
            "dog_id": entitlement.dog_id_snapshot, "points": entitlement.point_entry.amount,
            "balance": get_balance(owner), "collected_at": _iso(entitlement.collected_at), "created": created}


@transaction.atomic
def collect_document(*, owner, entitlement_id, now=None):
    owner = get_user_model().objects.select_for_update().get(pk=owner.pk)
    if owner.role != "OWNER" or not owner.is_active or owner.deleted_at:
        raise Http404
    candidate = DocumentEntitlement.objects.filter(pk=entitlement_id).first()
    if candidate is None:
        raise Http404
    # Shared dog lock serializes current and former owners across a profile transfer.
    dog = Dog.objects.select_for_update().filter(pk=candidate.dog_id_snapshot).first()
    entitlement = DocumentEntitlement.objects.select_for_update().get(pk=entitlement_id)
    if entitlement.point_entry_id:
        if entitlement.point_entry.user_id != owner.pk:
            raise Http404
        return _collection_receipt(entitlement, owner, False)
    if dog is None or dog.owner_id != owner.pk or not DocumentSubmission.objects.filter(entitlement=entitlement, owner=owner).exists():
        raise Http404
    if not QuestDefinition.objects.filter(code=QuestDefinition.Code.DOCUMENTS, is_enabled=True).exists():
        raise DocumentsUnavailable()
    if entitlement.eligibility_status != "ELIGIBLE":
        raise ValidationError("This document reward is unavailable pending a review outcome.")
    if entitlement.kind == DocumentKind.MICROCHIP:
        # The dog lock serializes all legacy annual reservations as one lifetime
        # qualification, including reservations submitted by a former owner.
        canonical = _lifetime_entitlement(DocumentEntitlement.objects.filter(
            dog_id_snapshot=entitlement.dog_id_snapshot, kind=DocumentKind.MICROCHIP,
        ))
        if canonical.pk != entitlement.pk:
            raise ValidationError("Microchip registration earns one reward per dog. This historical reservation cannot be collected.")
    entitlement.point_entry = credit_points(
        user=owner, amount=entitlement.promised_points, type=PointEntry.Type.EARN,
        source_reference=f"document-entitlement:{entitlement.pk}",
        earn_category=PointEntry.EarnCategory.DOCUMENT, earned_on=_local_today(now), rules_version=entitlement.rules_version,
    )
    entitlement.owner = owner
    entitlement.collected_at = now or timezone.now()
    entitlement.save(update_fields=["point_entry", "owner", "collected_at"])
    return _collection_receipt(entitlement, owner, True)


def _has_submission(row, owner):
    return any(submission.owner_id == owner.pk for submission in row.documentsubmission_set.all())


def _name(row, owner):
    if row.dog_id and row.dog.owner_id == owner.pk:
        return row.dog.name
    submission = next((item for item in row.documentsubmission_set.all() if item.owner_id == owner.pk), None)
    return submission.dog_name_snapshot if submission else "Dog"


def entitlements_for(owner):
    rows = list(DocumentEntitlement.objects.filter(documentsubmission__owner=owner).distinct().select_related("dog", "point_entry").prefetch_related("documentsubmission_set"))
    canonical_ids = _microchip_canonical_ids(DocumentEntitlement.objects.filter(
        dog_id_snapshot__in={row.dog_id_snapshot for row in rows}, kind=DocumentKind.MICROCHIP,
    ))
    enabled = QuestDefinition.objects.filter(code="DOCUMENTS", is_enabled=True).exists()
    return [{"id": row.pk, "dog_id": row.dog_id_snapshot, "dog_name": _name(row, owner), "kind": row.kind,
             "reward_status": "COLLECTED" if row.point_entry_id else "READY", "reward_points": row.promised_points,
             "collected_at": _iso(row.collected_at),
             "can_collect": bool(enabled and row.eligibility_status == "ELIGIBLE" and not row.point_entry_id
                                 and row.dog_id and row.dog.owner_id == owner.pk
                                 and (row.kind != DocumentKind.MICROCHIP or canonical_ids.get(row.dog_id_snapshot) == row.pk))}
            for row in rows]


def eligibility_for(owner, dogs):
    today = _local_today()
    rows = list(DocumentEntitlement.objects.filter(dog_id_snapshot__in=[dog.pk for dog in dogs]))
    result = []
    for dog in dogs:
        for kind in DocumentKind.values:
            reserved = [row for row in rows if row.dog_id_snapshot == dog.pk and row.kind == kind]
            earned = [row for row in reserved if row.point_entry_id]
            pending = len(reserved) - len(earned)
            remaining = None
            can_earn = None
            if kind in {DocumentKind.COUNCIL, DocumentKind.MICROCHIP}:
                canonical = _lifetime_entitlement(reserved)
                pending = int(bool(canonical and not canonical.point_entry_id))
                can_earn = not reserved
                message = "300 points once per dog. Submit evidence, then collect." if not reserved else (
                    "Ready to collect. Updated evidence will use the same reward." if pending else "Reward already collected. Updated evidence earns no extra points.")
                if pending and canonical.eligibility_status != "ELIGIBLE":
                    message = "This reward is unavailable pending a review outcome."
            else:
                remaining = max(0, 2 - sum(row.event_date.year == today.year for row in reserved))
                message = f"{remaining} of 2 slots remaining for {today.year}, including pending rewards. Visits must be at least 60 days apart."
            result.append({"dog_id": dog.pk, "kind": kind, "awards_count": len(earned), "pending_count": pending,
                           "remaining_this_year": remaining, "can_earn": can_earn, "message": message})
    return result


def quest_tasks(*, owner, dogs, request=None, now=None):
    if not QuestDefinition.objects.filter(code="DOCUMENTS", is_enabled=True).exists():
        return []
    today = _local_today(now)
    dogs = list(dogs)
    dog_by_id = {dog.pk: dog for dog in dogs}
    rows = list(DocumentEntitlement.objects.filter(
        Q(dog_id_snapshot__in=dog_by_id) | Q(owner=owner, point_entry__isnull=False)
    ).select_related("dog", "point_entry").prefetch_related("documentsubmission_set"))
    canonical_ids = _microchip_canonical_ids(rows)
    details = {
        DocumentKind.COUNCIL: "Enter your dog's current Council registration details or upload proof, then collect 300 points once per dog.",
        DocumentKind.MICROCHIP: "Enter the 15-digit microchip number or upload proof, then collect 300 points once per dog.",
        DocumentKind.VET: "Submit a photo and the check-up date, then collect 200 points. Up to two visits per calendar year, at least 60 days apart.",
    }

    def task(dog, kind, status, row=None):
        photo = photo_url(dog.uploaded_photo, request) if dog and dog.uploaded_photo else (dog.photo if dog else None)
        name = dog.name if dog else _name(row, owner)
        return {"id": f"entitlement:{row.pk}" if row else f"document:{dog.pk}:{kind}",
                "kind": kind, "status": status, "title": DocumentKind(kind).label,
                "subtitle": name, "subject_name": name, "photo": photo, "icon": "doc.text",
                "detail": details[kind], "reward_points": row.promised_points if row else POINTS[kind], "progress": None,
                "dog_id": row.dog_id_snapshot if row else dog.pk,
                "entitlement_id": row.pk if row else None, "collected_at": _iso(row.collected_at) if row else None}

    tasks = []
    for row in rows:
        dog = dog_by_id.get(row.dog_id_snapshot)
        if row.point_entry_id:
            if row.point_entry.user_id == owner.pk and row.collected_at and row.collected_at.astimezone(MELBOURNE).date() == today:
                tasks.append(task(dog, row.kind, "COLLECTED", row))
        elif (dog and row.eligibility_status == "ELIGIBLE" and _has_submission(row, owner)
              and (row.kind != DocumentKind.MICROCHIP or canonical_ids.get(row.dog_id_snapshot) == row.pk)):
            tasks.append(task(dog, row.kind, "READY", row))
    for dog in dogs:
        for kind in DocumentKind.values:
            reserved = [row for row in rows if row.dog_id_snapshot == dog.pk and row.kind == kind]
            if kind == DocumentKind.MICROCHIP:
                canonical = _lifetime_entitlement(reserved)
                if canonical:
                    if canonical.point_entry_id or canonical.eligibility_status != "ELIGIBLE":
                        continue
                    reserved = [canonical]
            if any(not row.point_entry_id and _has_submission(row, owner) for row in reserved):
                continue
            # A current owner can resubmit after a transfer to make an existing
            # unclaimed entitlement collectible without creating a second reward.
            transferred_pending = any(not row.point_entry_id for row in reserved)
            if kind in {DocumentKind.COUNCIL, DocumentKind.MICROCHIP}:
                eligible = not reserved or transferred_pending
            else:
                eligible = transferred_pending or (sum(row.event_date.year == today.year for row in reserved) < 2
                            and all(abs((today - row.event_date).days) >= 60 for row in reserved))
            if eligible:
                tasks.append(task(dog, kind, "IN_PROGRESS"))
    return tasks
