"""Owner-scoped Quest reset used by the local UI test control."""

from django.contrib.auth import get_user_model
from django.db import transaction
from django.db.models import Q
from django.utils import timezone

from checkins.models import CheckIn, CheckInWalk
from checkins.services import replayable_point_entry
from evidence.models import DocumentEntitlement, DocumentSubmission, EvidenceFingerprint
from evidence.storage import private_storage
from rewards.models import PointEntry
from rewards.policy import local_date, next_midnight
from rewards.services import get_balance

from .models import QuestAward


def _delete_attachments(names):
    for name in names:
        private_storage.delete(name)


def _replayable_entitlement_ids(entitlements, owner):
    """Find reset rows whose original document ledger entry is unattached."""
    replayable = []
    for entitlement in entitlements.filter(point_entry__isnull=True):
        entry = PointEntry.objects.filter(
            user=owner,
            type=PointEntry.Type.EARN,
            source_reference=f"document-entitlement:{entitlement.pk}",
            amount=entitlement.promised_points,
            earn_category=PointEntry.EarnCategory.DOCUMENT,
            rules_version=entitlement.rules_version,
        ).first()
        if entry and not DocumentEntitlement.objects.filter(point_entry=entry).exists():
            replayable.append(entitlement.pk)
    return replayable


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
    now = timezone.now()
    day = local_date(now)
    active_context_ids = tuple(CheckInWalk.objects.filter(
        owner=owner, state__in=(CheckInWalk.State.RECORDING, CheckInWalk.State.PAUSED),
    ).values_list("pk", flat=True))
    check_in_ids = tuple(CheckIn.objects.filter(owner=owner).filter(
        Q(local_date=day) | Q(walk_context_id__in=active_context_ids),
    ).values_list("pk", flat=True))
    check_ins = CheckIn.objects.filter(pk__in=check_in_ids)
    context_ids = tuple(CheckInWalk.objects.filter(owner=owner).filter(
        Q(pk__in=active_context_ids) | Q(checkins__pk__in=check_in_ids),
    ).values_list("pk", flat=True).distinct())
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
    replayable_entitlement_ids = tuple(_replayable_entitlement_ids(entitlements, owner))
    replayable_check_in_ids = tuple(
        row.pk for row in check_ins.filter(point_entry__isnull=True)
        if replayable_point_entry(owner, row.local_date, row.category_slot, row=row) is not None
    )
    preserved_entitlement_ids = (*collected_entitlement_ids, *replayable_entitlement_ids)
    preserved_check_in_ids = (*collected_check_in_ids, *replayable_check_in_ids)

    awards.update(point_entry=None, awarded_at=None)
    entitlements.filter(pk__in=preserved_entitlement_ids).update(
        point_entry=None, collected_at=None,
    )
    # Keep the qualification row and detach its ledger receipt. A new Walk can
    # then reuse both IDs, so credit_points replays the original point entry
    # instead of increasing the balance during a test rerun.
    check_ins.filter(pk__in=preserved_check_in_ids).update(
        walk_context=None, point_entry=None, collected_at=None, ready_at=None,
        started_at=None, verified_seconds=0, last_recorded_at=None,
        last_sequence=None, last_captured_at=None, last_sample_fingerprint="",
        last_latitude=None, last_longitude=None, last_verified_at=None,
        expires_at=next_midnight(now),
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
        pk__in=(*preserved_entitlement_ids, *protected_entitlement_ids),
    )
    pending_entitlement_count = pending_entitlements.count()
    pending_entitlements.delete()
    cleared["document_entitlements"] = len(preserved_entitlement_ids) + pending_entitlement_count
    check_ins.exclude(pk__in=preserved_check_in_ids).delete()
    if context_ids:
        CheckInWalk.objects.filter(pk__in=context_ids, checkins__isnull=True).delete()

    if attachment_names:
        transaction.on_commit(lambda: _delete_attachments(tuple(attachment_names)))

    # Point entries intentionally remain and are reattached on the next claim.
    # This keeps every available point lot and the wallet balance unchanged.
    return {"reset": True, "wallet_balance": get_balance(owner), "cleared": cleared}
