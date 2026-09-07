from django.core.exceptions import ValidationError
from django.db import IntegrityError, transaction
from django.test import TestCase
from django.utils import timezone

from accounts.models import User
from redemptions.models import (
    CafeOrderEvent,
    RedemptionOrder,
    RedemptionOrderItem,
)
from venues.models import Venue, VenueOffer


class RedemptionModelTests(TestCase):
    def setUp(self):
        self.owner = User.objects.create_user(
            email="owner@example.com",
            password="StrongPass123!",
            display_name="Dog Owner",
            role=User.Role.OWNER,
        )
        self.other_owner = User.objects.create_user(
            email="other-owner@example.com",
            password="StrongPass123!",
            display_name="Other Owner",
            role=User.Role.OWNER,
        )
        self.cafe = User.objects.create_user(
            email="cafe@example.com",
            password="StrongPass123!",
            display_name="Example Café",
            role=User.Role.CAFE,
        )
        self.other_cafe = User.objects.create_user(
            email="other-cafe@example.com",
            password="StrongPass123!",
            display_name="Other Café",
            role=User.Role.CAFE,
        )
        self.venue = Venue.objects.create(name="Example Café", account=self.cafe)
        self.other_venue = Venue.objects.create(
            name="Other Café",
            account=self.other_cafe,
        )
        self.offer = VenueOffer.objects.create(
            venue=self.venue,
            name="Coffee",
            point_price=120,
        )

    def create_order(self, **overrides):
        values = {
            "owner": self.owner,
            "venue": self.venue,
            "total_points": 120,
        }
        values.update(overrides)
        return RedemptionOrder.objects.create(**values)

    def test_order_generates_reference_and_expires_at_local_midnight(self):
        order = self.create_order()

        self.assertRegex(order.reference_number, r"^RDM-[0-9A-F]{12}$")
        expires_local = timezone.localtime(order.expires_at)
        now_local = timezone.localtime(timezone.now())
        self.assertGreater(expires_local.date(), now_local.date())
        self.assertEqual(expires_local.time(), timezone.datetime.min.time())

    def test_order_snapshots_owner_name(self):
        order = self.create_order()

        self.owner.display_name = "Renamed Owner"
        self.owner.save(update_fields=("display_name",))
        order.refresh_from_db()

        self.assertEqual(order.owner_name_snapshot, "Dog Owner")

    def test_order_owner_is_immutable(self):
        order = self.create_order()
        order.owner = self.other_owner

        with self.assertRaisesMessage(
            ValidationError,
            "An order's owner cannot be changed.",
        ):
            order.save()

        order.refresh_from_db()
        self.assertEqual(order.owner_id, self.owner.id)

    def test_order_rejects_a_cafe_as_owner(self):
        order = RedemptionOrder(
            owner=self.cafe,
            venue=self.venue,
            total_points=120,
        )

        with self.assertRaisesMessage(
            ValidationError,
            "Only a dog owner account can place a redemption order.",
        ):
            order.full_clean()

    def test_order_item_snapshots_offer_name_and_price(self):
        order = self.create_order()

        item = RedemptionOrderItem.objects.create(
            order=order,
            venue_offer=self.offer,
            quantity=2,
        )

        self.assertEqual(item.item_name_snapshot, "Coffee")
        self.assertEqual(item.point_price_snapshot, 120)

    def test_order_item_rejects_an_offer_from_another_venue(self):
        order = self.create_order()
        other_offer = VenueOffer.objects.create(
            venue=self.other_venue,
            name="Tea",
            point_price=80,
        )
        item = RedemptionOrderItem(
            order=order,
            venue_offer=other_offer,
            item_name_snapshot="Tea",
            point_price_snapshot=80,
        )

        with self.assertRaisesMessage(
            ValidationError,
            "The offer must belong to the order's venue.",
        ):
            item.full_clean()

        with self.assertRaisesMessage(
            ValidationError,
            "The offer must belong to the order's venue.",
        ):
            item.save()

    def test_pending_order_and_item_changes_append_feed_events(self):
        order = self.create_order()
        creation_event = CafeOrderEvent.objects.get()
        self.assertEqual(creation_event.kind, CafeOrderEvent.Kind.UPSERT)
        self.assertEqual(creation_event.venue_id, self.venue.id)
        self.assertEqual(creation_event.order_id, order.id)

        RedemptionOrderItem.objects.create(
            order=order,
            venue_offer=self.offer,
        )

        self.assertEqual(CafeOrderEvent.objects.count(), 2)
        self.assertEqual(
            CafeOrderEvent.objects.latest("cursor").kind,
            CafeOrderEvent.Kind.UPSERT,
        )

    def test_leaving_pending_appends_a_remove_event(self):
        order = self.create_order()

        order.status = RedemptionOrder.Status.COLLECTED
        order.collected_at = timezone.now()
        order.save()

        self.assertEqual(
            list(CafeOrderEvent.objects.values_list("kind", flat=True)),
            [CafeOrderEvent.Kind.UPSERT, CafeOrderEvent.Kind.REMOVE],
        )

    def test_moving_a_pending_order_removes_then_upserts(self):
        order = self.create_order()

        order.venue = self.other_venue
        order.save()

        events = list(
            CafeOrderEvent.objects.values_list("venue_id", "kind")
        )
        self.assertEqual(
            events,
            [
                (self.venue.id, CafeOrderEvent.Kind.UPSERT),
                (self.venue.id, CafeOrderEvent.Kind.REMOVE),
                (self.other_venue.id, CafeOrderEvent.Kind.UPSERT),
            ],
        )

        self.venue.refresh_from_db()
        self.other_venue.refresh_from_db()
        self.assertEqual(self.venue.order_feed_cursor, 2)
        self.assertEqual(self.other_venue.order_feed_cursor, 1)

    def test_order_venue_cannot_change_after_an_item_is_added(self):
        order = self.create_order()
        RedemptionOrderItem.objects.create(
            order=order,
            venue_offer=self.offer,
        )

        order.venue = self.other_venue

        with self.assertRaisesMessage(
            ValidationError,
            "An order's venue cannot change after items are added.",
        ):
            order.save()

        order.refresh_from_db()
        self.assertEqual(order.venue_id, self.venue.id)

    def test_order_item_relations_are_immutable(self):
        order = self.create_order()
        other_order = self.create_order()
        other_offer = VenueOffer.objects.create(
            venue=self.venue,
            name="Tea",
            point_price=80,
        )
        item = RedemptionOrderItem.objects.create(
            order=order,
            venue_offer=self.offer,
        )

        item.order = other_order
        with self.assertRaisesMessage(
            ValidationError,
            "An order item's order cannot be changed.",
        ):
            item.save()

        item.refresh_from_db()
        item.venue_offer = other_offer
        with self.assertRaisesMessage(
            ValidationError,
            "An order item's venue offer cannot be changed.",
        ):
            item.save()

    def test_update_fields_events_use_the_persisted_order_state(self):
        order = self.create_order()
        CafeOrderEvent.objects.all().delete()
        order.status = RedemptionOrder.Status.COLLECTED
        order.total_points = 121

        order.save(update_fields=("total_points",))

        order.refresh_from_db()
        event = CafeOrderEvent.objects.get()
        self.assertEqual(order.status, RedemptionOrder.Status.PENDING)
        self.assertEqual(event.venue_id, self.venue.id)
        self.assertEqual(event.kind, CafeOrderEvent.Kind.UPSERT)

    def test_item_update_fields_events_use_the_persisted_relation(self):
        order = self.create_order()
        other_order = self.create_order()
        item = RedemptionOrderItem.objects.create(
            order=order,
            venue_offer=self.offer,
        )
        CafeOrderEvent.objects.all().delete()
        item.order = other_order
        item.quantity = 2

        item.save(update_fields=("quantity",))

        item.refresh_from_db()
        event = CafeOrderEvent.objects.get()
        self.assertEqual(item.order_id, order.id)
        self.assertEqual(event.order_id, order.id)

    def test_order_deletion_appends_only_a_remove_event(self):
        order = self.create_order()
        RedemptionOrderItem.objects.create(
            order=order,
            venue_offer=self.offer,
        )
        order_id = order.id
        CafeOrderEvent.objects.all().delete()

        order.delete()

        event = CafeOrderEvent.objects.get()
        self.assertEqual(event.order_id, order_id)
        self.assertEqual(event.kind, CafeOrderEvent.Kind.REMOVE)

    def test_order_deletion_uses_persisted_status_and_venue(self):
        order = self.create_order()
        order_id = order.id
        CafeOrderEvent.objects.all().delete()
        order.status = RedemptionOrder.Status.COLLECTED
        order.venue = self.other_venue

        order.delete()

        event = CafeOrderEvent.objects.get()
        self.assertEqual(event.order_id, order_id)
        self.assertEqual(event.venue_id, self.venue.id)
        self.assertEqual(event.kind, CafeOrderEvent.Kind.REMOVE)

    def test_item_deletion_uses_the_persisted_order_relation(self):
        order = self.create_order()
        other_order = self.create_order()
        item = RedemptionOrderItem.objects.create(
            order=order,
            venue_offer=self.offer,
        )
        CafeOrderEvent.objects.all().delete()
        item.order = other_order

        item.delete()

        event = CafeOrderEvent.objects.get()
        self.assertEqual(event.order_id, order.id)
        self.assertEqual(event.venue_id, self.venue.id)

    def test_order_and_feed_cursor_roll_back_together(self):
        original_cursor = self.venue.order_feed_cursor

        with self.assertRaises(RuntimeError):
            with transaction.atomic():
                self.create_order()
                raise RuntimeError("roll back")

        self.venue.refresh_from_db()
        self.assertEqual(self.venue.order_feed_cursor, original_cursor)
        self.assertFalse(RedemptionOrder.objects.exists())
        self.assertFalse(CafeOrderEvent.objects.exists())

    def test_event_cursor_is_unique_within_a_venue(self):
        order = self.create_order()
        event = CafeOrderEvent.objects.get()

        with self.assertRaises(IntegrityError), transaction.atomic():
            CafeOrderEvent.objects.create(
                venue_id=self.venue.id,
                cursor=event.cursor,
                order_id=order.id,
                kind=CafeOrderEvent.Kind.UPSERT,
            )
