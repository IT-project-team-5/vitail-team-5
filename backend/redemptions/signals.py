from django.conf import settings
from django.db import transaction
from django.db.models.signals import post_delete, post_save, pre_delete, pre_save
from django.dispatch import receiver

from venues.models import Venue

from .models import CafeOrderEvent, RedemptionOrder, RedemptionOrderItem


def _event_retention():
    return max(1, int(settings.CAFE_ORDER_EVENT_RETENTION))


def emit_order_events(*, events, using):
    """Append events with commit-ordered cursors for every affected venue."""
    events = list(events)
    if not events:
        return

    venue_ids = sorted({event["venue_id"] for event in events})
    with transaction.atomic(using=using):
        venues = {
            venue.pk: venue
            for venue in Venue.objects.using(using)
            .select_for_update()
            .filter(pk__in=venue_ids)
            .order_by("pk")
        }
        missing_venue_ids = set(venue_ids) - venues.keys()
        if missing_venue_ids:
            raise Venue.DoesNotExist(
                "Cannot emit café order events for venues "
                f"{sorted(missing_venue_ids)}."
            )

        rows = []
        for event in events:
            venue = venues[event["venue_id"]]
            venue.order_feed_cursor += 1
            rows.append(
                CafeOrderEvent(
                    venue_id=venue.pk,
                    cursor=venue.order_feed_cursor,
                    order_id=event["order_id"],
                    kind=event["kind"],
                )
            )

        for venue_id in venue_ids:
            venues[venue_id].save(
                using=using,
                update_fields=("order_feed_cursor",),
            )
        CafeOrderEvent.objects.using(using).bulk_create(rows)

        retention = _event_retention()
        for venue_id in venue_ids:
            prune_through = venues[venue_id].order_feed_cursor - retention
            if prune_through > 0:
                CafeOrderEvent.objects.using(using).filter(
                    venue_id=venue_id,
                    cursor__lte=prune_through,
                ).delete()


@receiver(pre_save, sender=RedemptionOrder)
def capture_previous_order_feed_state(sender, instance, raw, using, **kwargs):
    if raw:
        return

    if hasattr(instance, "_previous_cafe_feed_state"):
        return

    previous = None
    if instance.pk:
        previous = (
            sender.objects.using(using)
            .filter(pk=instance.pk)
            .values("venue_id", "status")
            .first()
        )
    instance._previous_cafe_feed_state = previous


@receiver(post_save, sender=RedemptionOrder)
def record_order_feed_change(sender, instance, created, raw, using, **kwargs):
    if raw:
        return

    current = (
        sender.objects.using(using)
        .filter(pk=instance.pk)
        .values("venue_id", "status")
        .get()
    )
    previous = getattr(instance, "_previous_cafe_feed_state", None)
    events = []

    if (
        previous
        and previous["status"] == RedemptionOrder.Status.PENDING
        and previous["venue_id"] != current["venue_id"]
    ):
        events.append(
            {
                "venue_id": previous["venue_id"],
                "order_id": instance.pk,
                "kind": CafeOrderEvent.Kind.REMOVE,
            }
        )

    if current["status"] == RedemptionOrder.Status.PENDING:
        events.append(
            {
                "venue_id": current["venue_id"],
                "order_id": instance.pk,
                "kind": CafeOrderEvent.Kind.UPSERT,
            }
        )
    elif not created:
        # Repeating REMOVE for a saved non-pending order is harmless and makes
        # the event reflect persisted truth even after a stale model save.
        events.append(
            {
                "venue_id": current["venue_id"],
                "order_id": instance.pk,
                "kind": CafeOrderEvent.Kind.REMOVE,
            }
        )

    emit_order_events(events=events, using=using)


@receiver(pre_delete, sender=RedemptionOrder)
def capture_deleted_order_feed_state(sender, instance, using, **kwargs):
    instance._deleted_cafe_feed_state = (
        sender.objects.using(using)
        .select_for_update()
        .filter(pk=instance.pk)
        .values("venue_id", "status")
        .first()
    )


@receiver(post_delete, sender=RedemptionOrder)
def record_pending_order_deletion(sender, instance, using, **kwargs):
    deleted_state = getattr(instance, "_deleted_cafe_feed_state", None)
    if deleted_state and deleted_state["status"] == RedemptionOrder.Status.PENDING:
        emit_order_events(
            events=(
                {
                    "venue_id": deleted_state["venue_id"],
                    "order_id": instance.pk,
                    "kind": CafeOrderEvent.Kind.REMOVE,
                },
            ),
            using=using,
        )


def _is_cascading_order_delete(origin):
    if isinstance(origin, RedemptionOrder):
        return True
    return getattr(origin, "model", None) is RedemptionOrder


def _pending_order_event(*, order_id, using):
    order = (
        RedemptionOrder.objects.using(using)
        .filter(pk=order_id, status=RedemptionOrder.Status.PENDING)
        .values("id", "venue_id")
        .first()
    )
    if order is None:
        return None
    return {
        "venue_id": order["venue_id"],
        "order_id": order["id"],
        "kind": CafeOrderEvent.Kind.UPSERT,
    }


@receiver(post_save, sender=RedemptionOrderItem)
def record_order_item_save(sender, instance, raw, using, **kwargs):
    if raw:
        return

    current_order_id = (
        sender.objects.using(using)
        .filter(pk=instance.pk)
        .values_list("order_id", flat=True)
        .get()
    )
    order_ids = {
        order_id
        for order_id in (
            getattr(instance, "_previous_order_id", None),
            current_order_id,
        )
        if order_id is not None
    }
    events = [
        event
        for order_id in sorted(order_ids)
        if (event := _pending_order_event(order_id=order_id, using=using)) is not None
    ]
    emit_order_events(events=events, using=using)


@receiver(pre_delete, sender=RedemptionOrderItem)
def capture_deleted_order_item_state(sender, instance, using, **kwargs):
    instance._deleted_order_id = (
        sender.objects.using(using)
        .select_for_update()
        .filter(pk=instance.pk)
        .values_list("order_id", flat=True)
        .first()
    )


@receiver(post_delete, sender=RedemptionOrderItem)
def record_order_item_delete(sender, instance, origin, using, **kwargs):
    if _is_cascading_order_delete(origin):
        return

    order_id = getattr(instance, "_deleted_order_id", None)
    event = (
        _pending_order_event(order_id=order_id, using=using)
        if order_id is not None
        else None
    )
    emit_order_events(events=(() if event is None else (event,)), using=using)
