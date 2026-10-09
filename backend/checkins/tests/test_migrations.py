from datetime import timedelta

from django.db import connection
from django.db.migrations.executor import MigrationExecutor
from django.test import TransactionTestCase
from django.utils import timezone


class WalkCheckInMigrationTests(TransactionTestCase):
    def test_legacy_receipts_and_unlinked_progress_survive_without_fabricated_walks(self):
        executor = MigrationExecutor(connection)
        leaves = executor.loader.graph.leaf_nodes()
        try:
            executor.migrate([("checkins", "0001_initial")])
            executor = MigrationExecutor(connection)
            old = executor.loader.project_state(list(executor.loader.applied_migrations)).apps
            User = old.get_model("accounts", "User")
            Venue = old.get_model("venues", "Venue")
            CheckIn = old.get_model("checkins", "CheckIn")
            Entry = old.get_model("rewards", "PointEntry")
            owner = User.objects.create(email="venue-migration@example.com", display_name="Owner", role="OWNER")
            venue = Venue.objects.create(name="Legacy Cafe", kind="CAFE", latitude=0, longitude=0, checkin_enabled=True)
            now = timezone.now()
            common = dict(owner=owner, venue=venue, venue_name_snapshot=venue.name, local_date=now.date(),
                          center_latitude=0, center_longitude=0, started_at=now - timedelta(minutes=20),
                          expires_at=now + timedelta(hours=1), required_seconds=600)
            receipt = CheckIn.objects.create(**common, category_slot="CAFE", verified_seconds=600, ready_at=now - timedelta(minutes=1))
            entry = Entry.objects.create(user=owner, amount=12, remaining_points=12, type="EARN",
                source_reference=f"checkin:{receipt.pk}", expires_at=now + timedelta(days=365),
                earn_category="CHECK_IN", earned_on=now.date(), rules_version="legacy-test")
            receipt.point_entry = entry
            receipt.collected_at = now
            receipt.save()
            pending = CheckIn.objects.create(**common, category_slot="PARK", verified_seconds=30)
            executor = MigrationExecutor(connection)
            executor.migrate(leaves)
            current = executor.loader.project_state(leaves).apps
            upgraded = current.get_model("checkins", "CheckIn")
            self.assertEqual(upgraded.objects.get(pk=receipt.pk).point_entry_id, entry.pk)
            self.assertIsNone(upgraded.objects.get(pk=receipt.pk).walk_context_id)
            self.assertEqual(upgraded.objects.get(pk=pending.pk).verified_seconds, 30)
            self.assertIsNone(upgraded.objects.get(pk=pending.pk).last_captured_at)
            self.assertEqual(current.get_model("checkins", "CheckInWalk").objects.count(), 0)
            self.assertEqual(current.get_model("rewards", "PointEntry").objects.count(), 1)
        finally:
            MigrationExecutor(connection).migrate(leaves)
