"""Owner-scoped Quest reset used by the local UI test control."""

from django.contrib.auth import get_user_model
from django.db import transaction

from checkins.models import CheckIn
from evidence.models import DocumentEntitlement, DocumentSubmission, EvidenceFingerprint
from evidence.storage import private_storage
from rewards.services import get_balance

from .models import QuestAward


def _delete_attachments(names):
    for name in names:
        private_storage.delete(name)


@transaction.atomic
def reset_quest_test_state(*, owner):
    """Clear one owner's replayable Quest state without changing their wallet."""
    owner = get_user_model().objects.select_for_update().get(pk=owner.pk)
    if owner.role != owner.Role.OWNER:
        raise ValueError("Quest test state belongs to owner accounts only.")

    submissions = DocumentSubmission.objects.filter(owner=owner)
    attachment_names = set(submissions.exclude(file="").values_list("file", flat=True))
    shared_names = set(DocumentSubmission.objects.exclude(owner=owner).filter(
        file__in=attachment_names,
    ).values_list("file", flat=True))
    attachment_names -= shared_names

    fingerprints = EvidenceFingerprint.objects.filter(owner=owner)
    entitlements = DocumentEntitlement.objects.filter(owner=owner, dog__owner=owner)
    awards = QuestAward.objects.filter(owner=owner)
    check_ins = CheckIn.objects.filter(owner=owner)
    cleared = {
        "quest_awards": awards.count(),
        "document_submissions": submissions.count(),
        "document_entitlements": 0,
        "evidence_fingerprints": fingerprints.count(),
        "check_ins": check_ins.count(),
    }

    # Keep collected qualification IDs so their existing idempotency keys replay
    # the original ledger entry instead of awarding points a second time.
    collected_entitlement_ids = tuple(entitlements.filter(
        point_entry__isnull=False,
    ).values_list("pk", flat=True))
    collected_check_in_ids = tuple(check_ins.filter(
        point_entry__isnull=False,
    ).values_list("pk", flat=True))

    awards.update(point_entry=None, awarded_at=None)
    entitlements.filter(pk__in=collected_entitlement_ids).update(
        point_entry=None, collected_at=None,
    )
    check_ins.filter(pk__in=collected_check_in_ids).update(
        point_entry=None, collected_at=None, ready_at=None, started_at=None,
        verified_seconds=0, last_recorded_at=None, last_latitude=None,
        last_longitude=None, last_verified_at=None,
    )

    # Remove upload dependants before deleting never-collected reservations. An
    # entitlement referenced by another owner after transfer remains untouched.
    fingerprints.delete()
    submissions.delete()
    protected_entitlement_ids = set(DocumentSubmission.objects.filter(
        entitlement__owner=owner,
    ).values_list("entitlement_id", flat=True))
    protected_entitlement_ids.update(EvidenceFingerprint.objects.filter(
        entitlement__owner=owner,
    ).values_list("entitlement_id", flat=True))
    pending_entitlements = entitlements.filter(point_entry__isnull=True).exclude(
        pk__in=(*collected_entitlement_ids, *protected_entitlement_ids),
    )
    pending_entitlement_count = pending_entitlements.count()
    pending_entitlements.delete()
    cleared["document_entitlements"] = len(collected_entitlement_ids) + pending_entitlement_count
    check_ins.exclude(pk__in=collected_check_in_ids).delete()

    if attachment_names:
        transaction.on_commit(lambda: _delete_attachments(tuple(attachment_names)))

    # Point entries intentionally remain and are reattached on the next claim.
    # This keeps every available point lot and the wallet balance unchanged.
    return {"reset": True, "wallet_balance": get_balance(owner), "cleared": cleared}
