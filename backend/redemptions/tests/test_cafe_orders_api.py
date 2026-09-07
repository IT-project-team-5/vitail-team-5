from django.utils import timezone
from django.test import override_settings
from rest_framework import status
from rest_framework.test import APITestCase

from accounts.models import User
from redemptions.models import CafeOrderEvent, RedemptionOrder, RedemptionOrderItem
from redemptions.views import CURSOR_HEADER
from venues.models import Venue, VenueOffer


class CafeOrderFeedApiTests(APITestCase):
    url = "/api/cafe/orders"

    def setUp(self):
        self.owner = User.objects.create_user(
            email="owner@example.com",
            password="StrongPass123!",
            display_name="Taylor",
            role=User.Role.OWNER,
        )
        self.cafe = User.objects.create_user(
            email="cafe@example.com",
            password="StrongPass123!",
            display_name="First Café",
            role=User.Role.CAFE,
        )
        self.other_cafe = User.objects.create_user(
            email="other-cafe@example.com",
            password="StrongPass123!",
            display_name="Second Café",
            role=User.Role.CAFE,
        )
        self.venue = Venue.objects.create(name="First Café", account=self.cafe)
        self.other_venue = Venue.objects.create(
            name="Second Café",
            account=self.other_cafe,
        )
        self.offer = VenueOffer.objects.create(
            venue=self.venue,
            name="Flat white",
            point_price=150,
        )
        self.other_offer = VenueOffer.objects.create(
            venue=self.other_venue,
            name="Muffin",
            point_price=200,
        )

    def create_order(
        self,
        *,
        venue=None,
        offer=None,
        status_value=RedemptionOrder.Status.PENDING,
        item_name=None,
    ):
        venue = venue or self.venue
        offer = offer or self.offer
        order = RedemptionOrder.objects.create(
            owner=self.owner,
            venue=venue,
            status=status_value,
            total_points=offer.point_price,
            collected_at=(
                timezone.now()
                if status_value == RedemptionOrder.Status.COLLECTED
                else None
            ),
        )
        RedemptionOrderItem.objects.create(
            order=order,
            venue_offer=offer,
            item_name_snapshot=item_name or offer.name,
            point_price_snapshot=offer.point_price,
            quantity=2,
        )
        return order

    def authenticate(self, user=None):
        self.client.force_authenticate(user=user or self.cafe)

    def test_feed_requires_authentication(self):
        response = self.client.get(self.url)

        self.assertEqual(response.status_code, status.HTTP_401_UNAUTHORIZED)

    def test_feed_rejects_an_owner_account(self):
        self.authenticate(self.owner)

        response = self.client.get(self.url)

        self.assertEqual(response.status_code, status.HTTP_403_FORBIDDEN)

    def test_feed_is_read_only(self):
        order = self.create_order()
        self.authenticate()

        response = self.client.post(self.url, {"order_id": order.id}, format="json")

        self.assertEqual(response.status_code, status.HTTP_405_METHOD_NOT_ALLOWED)
        order.refresh_from_db()
        self.assertEqual(order.status, RedemptionOrder.Status.PENDING)

    def test_feed_reports_when_cafe_has_no_attached_venue(self):
        cafe_without_venue = User.objects.create_user(
            email="unattached@example.com",
            password="StrongPass123!",
            display_name="Unattached Café",
            role=User.Role.CAFE,
        )
        self.authenticate(cafe_without_venue)

        response = self.client.get(self.url)

        self.assertEqual(response.status_code, status.HTTP_404_NOT_FOUND)
        self.assertEqual(response.data["code"], "CAFE_VENUE_NOT_FOUND")

    def test_initial_feed_is_pending_only_scoped_and_newest_first(self):
        older = self.create_order(item_name="Older flat white")
        newer = self.create_order(item_name="Newer flat white")
        collected = self.create_order(
            status_value=RedemptionOrder.Status.COLLECTED,
        )
        other_cafe_order = self.create_order(
            venue=self.other_venue,
            offer=self.other_offer,
        )
        self.authenticate()

        response = self.client.get(self.url)

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(
            [order["id"] for order in response.data["upserts"]],
            [newer.id, older.id],
        )
        self.assertNotIn(
            collected.id,
            [item["id"] for item in response.data["upserts"]],
        )
        self.assertNotIn(
            other_cafe_order.id,
            [item["id"] for item in response.data["upserts"]],
        )
        self.assertEqual(response.data["removed_ids"], [])
        self.assertIs(response.data["reset"], True)
        self.assertEqual(
            set(response.data["upserts"][0]),
            {"id", "reference_number", "owner_name", "items", "ordered_at"},
        )
        self.assertEqual(response.data["upserts"][0]["owner_name"], "Taylor")
        self.assertEqual(
            response.data["upserts"][0]["items"],
            [{"name": "Newer flat white", "quantity": 2}],
        )
        self.assertEqual(response[CURSOR_HEADER], str(response.data["cursor"]))
        self.assertEqual(response["Cache-Control"], "no-store")

    def test_customer_name_is_the_order_time_snapshot(self):
        order = self.create_order()
        self.owner.display_name = "Renamed Owner"
        self.owner.save(update_fields=("display_name",))
        self.authenticate()

        response = self.client.get(self.url)

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["upserts"][0]["id"], order.id)
        self.assertEqual(response.data["upserts"][0]["owner_name"], "Taylor")

    def test_delta_coalesces_order_and_item_events_into_one_upsert(self):
        self.authenticate()
        initial = self.client.get(self.url)

        order = self.create_order()
        response = self.client.get(self.url, {"since": initial.data["cursor"]})

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual([item["id"] for item in response.data["upserts"]], [order.id])
        self.assertEqual(response.data["removed_ids"], [])
        self.assertIs(response.data["reset"], False)
        self.assertGreater(response.data["cursor"], initial.data["cursor"])

    def test_delta_removes_an_order_after_it_leaves_pending(self):
        order = self.create_order()
        self.authenticate()
        initial = self.client.get(self.url)

        order.status = RedemptionOrder.Status.COLLECTED
        order.collected_at = timezone.now()
        order.save()
        response = self.client.get(self.url, {"since": initial.data["cursor"]})

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["upserts"], [])
        self.assertEqual(response.data["removed_ids"], [order.id])

    def test_delta_upserts_a_pending_order_when_an_item_changes(self):
        order = self.create_order()
        self.authenticate()
        initial = self.client.get(self.url)

        item = order.items.get()
        item.quantity = 3
        item.save()
        response = self.client.get(self.url, {"since": initial.data["cursor"]})

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertEqual(response.data["upserts"][0]["id"], order.id)
        self.assertEqual(response.data["upserts"][0]["items"][0]["quantity"], 3)

    def test_other_venue_changes_do_not_advance_this_venues_cursor(self):
        self.authenticate()
        initial = self.client.get(self.url)

        self.create_order(venue=self.other_venue, offer=self.other_offer)
        response = self.client.get(self.url, {"since": initial.data["cursor"]})

        self.assertEqual(response.status_code, status.HTTP_304_NOT_MODIFIED)
        self.assertEqual(response[CURSOR_HEADER], str(initial.data["cursor"]))
        self.assertEqual(response.content, b"")

    def test_no_change_at_current_cursor_returns_304(self):
        self.create_order()
        self.authenticate()
        initial = self.client.get(self.url)

        response = self.client.get(self.url, {"since": initial.data["cursor"]})

        self.assertEqual(response.status_code, status.HTTP_304_NOT_MODIFIED)

    def test_invalid_cursor_values_are_rejected(self):
        self.authenticate()
        for value in ("", "-1", "1.5", "not-a-cursor", "9" * 100):
            with self.subTest(value=value):
                response = self.client.get(f"{self.url}?since={value}")
                self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
                self.assertEqual(response.data["code"], "INVALID_CURSOR")

        duplicate = self.client.get(f"{self.url}?since=0&since=0")
        self.assertEqual(duplicate.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(duplicate.data["code"], "INVALID_CURSOR")

    def test_cursor_ahead_of_server_is_rejected(self):
        self.authenticate()

        response = self.client.get(self.url, {"since": 1})

        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)
        self.assertEqual(response.data["code"], "INVALID_CURSOR")

    @override_settings(CAFE_ORDER_EVENT_RETENTION=2)
    def test_cursor_older_than_retained_history_gets_reset_snapshot(self):
        self.authenticate()
        initial = self.client.get(self.url)
        first = self.create_order(item_name="First")
        second = self.create_order(item_name="Second")

        response = self.client.get(self.url, {"since": initial.data["cursor"]})

        self.venue.refresh_from_db()
        retained_event_count = CafeOrderEvent.objects.filter(
            venue_id=self.venue.id
        ).count()
        self.assertEqual(retained_event_count, 2)
        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertIs(response.data["reset"], True)
        self.assertEqual(response.data["cursor"], self.venue.order_feed_cursor)
        self.assertEqual(
            [item["id"] for item in response.data["upserts"]],
            [second.id, first.id],
        )
        self.assertEqual(response.data["removed_ids"], [])

    @override_settings(CAFE_ORDER_EVENT_RETENTION=2)
    def test_oldest_available_delta_does_not_force_a_reset(self):
        self.create_order(item_name="Existing")
        self.authenticate()
        initial = self.client.get(self.url)
        order = self.create_order(item_name="Changed")

        response = self.client.get(self.url, {"since": initial.data["cursor"]})

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertIs(response.data["reset"], False)
        self.assertEqual(
            [item["id"] for item in response.data["upserts"]],
            [order.id],
        )

    def test_missing_event_range_gets_reset_snapshot(self):
        order = self.create_order()
        self.authenticate()
        CafeOrderEvent.objects.filter(
            venue_id=self.venue.id,
            cursor=1,
        ).delete()

        response = self.client.get(self.url, {"since": 0})

        self.assertEqual(response.status_code, status.HTTP_200_OK)
        self.assertIs(response.data["reset"], True)
        self.assertEqual(
            [item["id"] for item in response.data["upserts"]],
            [order.id],
        )
