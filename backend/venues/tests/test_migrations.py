from datetime import datetime, timedelta, timezone as datetime_timezone
from tempfile import TemporaryDirectory
from uuid import uuid4

from django.core.files.base import ContentFile
from django.core.files.storage import default_storage
from django.db import connection
from django.db.migrations.executor import MigrationExecutor
from django.test import TransactionTestCase, override_settings
from django.utils import timezone

from accounts.models import User
from rewards.models import PointEntry, Redemption, Reward
from venues.models import Venue


class VenueMigrationTests(TransactionTestCase):
    def test_all_cafe_identities_profiles_photos_and_historical_orders_are_preserved(self):
        executor = MigrationExecutor(connection)
        latest = executor.loader.graph.leaf_nodes()
        old = [("accounts", "0003_cafeprofile_google_maps_url_user_photo"), ("rewards", "0002_connected_redemptions")]
        with TemporaryDirectory() as media, override_settings(MEDIA_ROOT=media):
            try:
                executor.migrate(old + [("venues", None)])
                apps = executor.loader.project_state(old).apps
                OldUser = apps.get_model("accounts", "User")
                OldProfile = apps.get_model("accounts", "CafeProfile")
                OldReward = apps.get_model("rewards", "Reward")
                OldOrder = apps.get_model("rewards", "Redemption")
                OldPoint = apps.get_model("rewards", "PointEntry")
                owner = OldUser.objects.create(email="venue-migration-owner@example.com", display_name="Owner", role="OWNER")
                cafe = OldUser.objects.create(email="venue-migration-cafe@example.com", display_name="Current Café", role="CAFE", password="same-password-hash")
                empty_cafe = OldUser.objects.create(email="venue-migration-empty@example.com", display_name="No profile or products", role="CAFE")
                former = OldUser.objects.create(email="venue-migration-former@example.com", display_name="Former café account", role="OWNER", is_active=False)
                missing_photo = OldUser.objects.create(email="venue-migration-missing@example.com", display_name="Missing photo", role="CAFE", photo="avatars/people/missing.jpg")
                original_photo = default_storage.save("avatars/people/legacy.jpg", ContentFile(b"existing-photo-bytes"))
                OldUser.objects.filter(pk=cafe.pk).update(photo=original_photo)
                OldProfile.objects.create(user=cafe, address="1 Original Street", description="Original description", opening_hours="9–5", google_maps_url="https://maps.app.goo.gl/Original")
                reward = OldReward.objects.create(cafe_user=cafe, name="Current item", point_cost=90)
                request_id = uuid4()
                created_at = datetime(2026, 9, 24, 14, 15, tzinfo=datetime_timezone.utc)  # Sep 25 in Melbourne.
                order = OldOrder.objects.create(owner_user=owner, cafe_user=former, reward=reward,
                    request_id=request_id, reference_number="RDM-MIGRATEVENUE", reward_name_snapshot="Historic item", point_cost_snapshot=40,
                    owner_name_snapshot="Historic owner", cafe_name_snapshot="Historic café", status="CANCELLED",
                    expires_at=created_at + timedelta(hours=2), feed_cursor=7)
                OldOrder.objects.filter(pk=order.pk).update(created_at=created_at)
                spend = OldPoint.objects.create(user=owner, amount=-40, type="SPEND", source_reference=f"redemption:{order.reference_number}")
                refund = OldPoint.objects.create(user=owner, amount=40, remaining_points=40, type="REFUND", source_reference=f"refund:{order.reference_number}", expires_at=timezone.now() + timedelta(days=300))
                missing_ledger = OldOrder.objects.create(owner_user=owner, cafe_user=cafe, reward=reward,
                    reference_number="RDM-MIGRATENOLEDGER", reward_name_snapshot="No matching ledger", point_cost_snapshot=15,
                    owner_name_snapshot="Owner", cafe_name_snapshot="Current Café", expires_at=timezone.now() + timedelta(hours=2))
                before_points = list(OldPoint.objects.order_by("pk").values("pk", "amount", "remaining_points", "type", "source_reference", "created_at", "expires_at"))
                MigrationExecutor(connection).migrate(latest)

                self.assertEqual(Venue.objects.count(), 4)
                migrated = Venue.objects.get(manager_user_id=cafe.pk)
                self.assertEqual((migrated.name, migrated.address, migrated.description, migrated.opening_hours, migrated.google_maps_url),
                    ("Current Café", "1 Original Street", "Original description", "9–5", "https://maps.app.goo.gl/Original"))
                self.assertTrue(migrated.is_partner)
                self.assertFalse(migrated.checkin_enabled)
                self.assertIsNone(migrated.latitude)
                self.assertIsNone(migrated.longitude)
                self.assertEqual(Venue.objects.get(manager_user_id=empty_cafe.pk).name, "No profile or products")
                historic_venue = Venue.objects.get(manager_user_id=former.pk)
                self.assertFalse(historic_venue.is_active)
                self.assertFalse(Venue.objects.get(manager_user_id=missing_photo.pk).photo)
                self.assertEqual(User.objects.get(pk=cafe.pk).password, "same-password-hash")
                self.assertEqual(User.objects.get(pk=cafe.pk).photo.name, original_photo)
                self.assertNotEqual(migrated.photo.name, original_photo)
                with default_storage.open(migrated.photo.name) as file:
                    self.assertEqual(file.read(), b"existing-photo-bytes")
                default_storage.delete(original_photo)
                self.assertTrue(default_storage.exists(migrated.photo.name))

                product = Reward.objects.get(pk=reward.pk)
                self.assertEqual((product.venue_id, product.name, product.point_cost), (migrated.pk, "Current item", 90))
                self.assertEqual(product.updated_at, product.created_at)
                self.assertIsNone(product.daily_quantity_limit)
                self.assertIsNone(product.starts_at)
                self.assertIsNone(product.ends_at)
                migrated_order = Redemption.objects.get(pk=order.pk)
                self.assertEqual(migrated_order.venue_id, historic_venue.pk)
                self.assertEqual((migrated_order.cafe_user_id, migrated_order.request_id, migrated_order.reference_number), (former.pk, request_id, order.reference_number))
                self.assertEqual((migrated_order.owner_name_snapshot, migrated_order.reward_name_snapshot, migrated_order.cafe_name_snapshot, migrated_order.point_cost_snapshot), ("Historic owner", "Historic item", "Historic café", 40))
                self.assertEqual(migrated_order.created_at, created_at)
                self.assertEqual(migrated_order.order_date.isoformat(), "2026-09-25")
                self.assertEqual(migrated_order.terms_snapshot, "")
                self.assertEqual(migrated_order.eligibility_snapshot, {})
                self.assertEqual((migrated_order.spend_entry_id, migrated_order.refund_entry_id), (spend.pk, refund.pk))
                self.assertEqual(migrated_order.feed_cursor, 7)
                self.assertEqual(len(migrated_order.request_fingerprint), 64)
                self.assertIsNone(Redemption.objects.get(pk=missing_ledger.pk).spend_entry_id)
                self.assertEqual(list(PointEntry.objects.order_by("pk").values("pk", "amount", "remaining_points", "type", "source_reference", "created_at", "expires_at")), before_points)
                self.assertNotIn("accounts_cafeprofile", connection.introspection.table_names())
            finally:
                MigrationExecutor(connection).migrate(latest)
