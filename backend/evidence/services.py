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
from .policy import council_entitlement, needs_expiry, reward_status
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
    if kind == DocumentKind.COUNCIL:
        today = _local_today()
        current = council_entitlement(existing, today)
        expected = data.get("expected_entitlement_id")
        if expected is not None and (current is None or current.pk != expected):
            raise RequestConflict("This registration has changed or expired. Refresh the Quest before submitting again.")
        expiry = data["valid_to"]
        if current:
            if current.valid_to is None:
                # Bind an unknown legacy qualification once, including an actual
                # past expiry. This updates no receipt, ledger or promised reward.
                current.valid_to = expiry
                current.save(update_fields=["valid_to"])
            elif current.valid_to != expiry:
                raise ValidationError({"valid_to": "This registration already has a confirmed expiry. A new reward is available after it expires."})
            return current, False
        if expiry < today:
            raise ValidationError({"valid_to": "This registration has expired. Submit your current registration."})
        key = f"expiry:{expiry.isoformat()}"
    elif data.get("expected_entitlement_id") is not None:
        if kind != DocumentKind.MICROCHIP or not existing or _lifetime_entitlement(existing).pk != data["expected_entitlement_id"]:
            raise RequestConflict("This document reward changed. Refresh the Quest before submitting again.")
        return _lifetime_entitlement(existing), False
    elif kind == DocumentKind.MICROCHIP:
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
        registration_year=None,
        promised_points=POINTS[kind],
        rules_version=("council-expiry-2026-09-27" if kind == DocumentKind.COUNCIL else
                       "microchip-lifetime-2026-09-25" if kind == DocumentKind.MICROCHIP else "documents-2026-09-25"),
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
                if data["kind"] == DocumentKind.COUNCIL:
                    # A transfer does not make last year's certificate reusable
                    # for another reward. The shared dog lock protects this check.
                    reused = EvidenceFingerprint.objects.filter(
                        dog_id_snapshot=dog.pk, kind=DocumentKind.COUNCIL,
                        fingerprint=upload["sha256"], is_file=True,
                    ).exclude(entitlement_id=entitlement.pk).exists()
                    if reused:
                        raise ValidationError("This file already supported another registration. Add the renewed registration document.")
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
                registry_name=data.get("registry_name", ""), document_dog_name=data.get("document_dog_name", ""),
                document_reading=data.get("document_reading"),
                event_date=data.get("event_date"), valid_from=data.get("valid_from"), valid_to=data.get("valid_to"),
                file=stored_name or "", filename=upload["filename"] if upload else "",
                file_content_type=upload["content_type"] if upload else "",
                file_sha256=upload["sha256"] if upload else "", awarded_points=awarded,
                file_size_bytes=len(upload["bytes"]) if upload else None,
            )
            receipt = {"submission": dict(DocumentSubmissionSerializer(submission).data),
                       "balance": get_balance(owner), "awarded_points": awarded, "created": True,
                       "entitlement_id": entitlement.pk, "reward_status": reward_status(entitlement), "valid_to": _iso(entitlement.valid_to),
                       "needs_expiry": needs_expiry(entitlement),
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
            "registration_year": entitlement.registration_year,
            "valid_to": _iso(entitlement.valid_to), "needs_expiry": needs_expiry(entitlement),
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
    if entitlement.kind == DocumentKind.COUNCIL:
        current = council_entitlement(DocumentEntitlement.objects.filter(
            dog_id_snapshot=entitlement.dog_id_snapshot, kind=DocumentKind.COUNCIL,
        ), _local_today(now))
        if current is None or current.pk != entitlement.pk:
            raise ValidationError({"code": "EXPIRED", "detail": "This registration expired or was superseded. Submit your current registration."})
        if entitlement.valid_to is None:
            raise ValidationError({"code": "EXPIRY_REQUIRED", "detail": "Confirm the expiry printed on the registration before collecting."})
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
    all_rows = list(DocumentEntitlement.objects.filter(dog_id_snapshot__in={row.dog_id_snapshot for row in rows}))
    canonical_ids = _microchip_canonical_ids(all_rows)
    today = _local_today()
    council_ids = {dog_id: current.pk for dog_id in {row.dog_id_snapshot for row in rows}
                   if (current := council_entitlement([item for item in all_rows if item.dog_id_snapshot == dog_id and item.kind == DocumentKind.COUNCIL], today))}
    enabled = QuestDefinition.objects.filter(code="DOCUMENTS", is_enabled=True).exists()
    result = []
    for row in rows:
        status = reward_status(row, today, canonical=row.kind != DocumentKind.COUNCIL or council_ids.get(row.dog_id_snapshot) == row.pk)
        result.append({"id": row.pk, "dog_id": row.dog_id_snapshot, "dog_name": _name(row, owner), "kind": row.kind,
                       "registration_year": row.registration_year, "valid_to": _iso(row.valid_to), "needs_expiry": needs_expiry(row),
                       "reward_status": status, "reward_points": row.promised_points, "collected_at": _iso(row.collected_at),
                       "can_collect": bool(enabled and status == "READY" and row.eligibility_status == "ELIGIBLE"
                                           and row.dog_id and row.dog.owner_id == owner.pk
                                           and (row.kind != DocumentKind.MICROCHIP or canonical_ids.get(row.dog_id_snapshot) == row.pk))})
    return result


def eligibility_for(owner, dogs):
    today = _local_today()
    rows = list(DocumentEntitlement.objects.filter(dog_id_snapshot__in=[dog.pk for dog in dogs]))
    result = []
    for dog in dogs:
        for kind in DocumentKind.values:
            reserved = [row for row in rows if row.dog_id_snapshot == dog.pk and row.kind == kind]
            canonical = council_entitlement(reserved, today) if kind == DocumentKind.COUNCIL else _lifetime_entitlement(reserved)
            if kind == DocumentKind.COUNCIL:
                reserved = [canonical] if canonical else []
            earned = [row for row in reserved if row.point_entry_id]
            pending = len(reserved) - len(earned)
            remaining = None
            can_earn = None
            if kind in {DocumentKind.COUNCIL, DocumentKind.MICROCHIP}:
                pending = int(bool(canonical and not canonical.point_entry_id))
                can_earn = not reserved
                rule = "300 points per dog for a current registration. Renew after its actual expiry." if kind == DocumentKind.COUNCIL else "300 points once per dog. Submit evidence, then collect."
                message = rule if not canonical else (
                    "Ready to collect. Updated evidence will use the same reward." if pending else "Reward already collected. Updated evidence earns no extra points.")
                if canonical and needs_expiry(canonical):
                    message = "Confirm the expiry printed on this registration. Updating an already collected reward earns no extra points."
                if canonical and canonical.eligibility_status != "ELIGIBLE":
                    message = "This reward is unavailable pending a review outcome."
            else:
                remaining = max(0, 2 - sum(row.event_date.year == today.year for row in reserved))
                message = f"{remaining} of 2 slots remaining for {today.year}, including pending rewards. Visits must be at least 60 days apart."
            result.append({"dog_id": dog.pk, "kind": kind, "awards_count": len(earned), "pending_count": pending,
                           "registration_year": None, "valid_to": _iso(canonical.valid_to) if canonical and kind == DocumentKind.COUNCIL else None,
                           "needs_expiry": bool(canonical and needs_expiry(canonical)),
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
        DocumentKind.COUNCIL: "Confirm the number, Council and expiry printed on your registration, then collect 300 points. A new reward is available after this registration expires.",
        DocumentKind.MICROCHIP: "Enter the 15-digit microchip number or upload proof, then collect 300 points once per dog.",
        DocumentKind.VET: "Submit a photo and the check-up date, then collect 200 points. Up to two visits per calendar year, at least 60 days apart.",
    }

    def task(dog, kind, status, row=None):
        photo = photo_url(dog.uploaded_photo, request) if dog and dog.uploaded_photo else (dog.photo if dog else None)
        name = dog.name if dog else _name(row, owner)
        dog_id = row.dog_id_snapshot if row else dog.pk
        task_id = f"entitlement:{row.pk}" if row else f"document:{dog_id}:{kind}"
        unknown = bool(row and needs_expiry(row))
        if kind == DocumentKind.COUNCIL:
            task_id = f"council:{dog_id}:entitlement:{row.pk}" if row else f"council:{dog_id}:new"
        detail = "Confirm the expiry printed on this registration. This updates the existing reward." if unknown else details[kind]
        return {"id": task_id,
                "kind": kind, "status": status, "title": DocumentKind(kind).label,
                "subtitle": name, "registration_year": row.registration_year if row else None,
                "valid_to": _iso(row.valid_to) if row else None, "needs_expiry": unknown,
                "subject_name": name, "photo": photo, "icon": "doc.text",
                "detail": detail, "reward_points": (0 if unknown and row.point_entry_id else row.promised_points) if row else POINTS[kind], "progress": None,
                "dog_id": dog_id,
                "entitlement_id": row.pk if row else None, "collected_at": _iso(row.collected_at) if row else None}

    tasks = []
    for row in rows:
        if row.kind == DocumentKind.COUNCIL:
            continue
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
            if kind == DocumentKind.COUNCIL:
                current = council_entitlement(reserved, today)
                if current is None:
                    tasks.append(task(dog, kind, "IN_PROGRESS"))
                elif current.eligibility_status == "ELIGIBLE":
                    if needs_expiry(current):
                        tasks.append(task(dog, kind, "IN_PROGRESS", current))
                    elif current.point_entry_id:
                        if current.point_entry.user_id == owner.pk and current.collected_at.astimezone(MELBOURNE).date() == today:
                            tasks.append(task(dog, kind, "COLLECTED", current))
                    else:
                        tasks.append(task(dog, kind, "READY" if _has_submission(current, owner) else "IN_PROGRESS", current))
                continue
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
