import csv
import io
import tempfile
from decimal import Decimal
from pathlib import Path

from django.core.management import call_command
from django.core.management.base import CommandError
from django.test import TestCase

from accounts.models import User
from venues.models import Venue


class MelbourneVenueImportTests(TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        self.path = Path(self.folder.name) / "venues.csv"
        self.row = {
            "source": "osm:node:599890343",
            "source_url": "https://www.openstreetmap.org/node/599890343",
            "name": "Carlton Veterinary Surgery", "kind": "VET",
            "address": "603 Rathdowne Street", "latitude": "-37.790930", "longitude": "144.971347",
        }

    def write_rows(self, rows):
        with self.path.open("w", encoding="utf-8", newline="") as output:
            writer = csv.DictWriter(output, fieldnames=self.row.keys())
            writer.writeheader()
            writer.writerows(rows)

    def run_import(self, **kwargs):
        output = io.StringIO()
        call_command("import_melbourne_venues", file=self.path, stdout=output, **kwargs)
        return output.getvalue()

    def test_import_is_idempotent_and_never_creates_accounts_or_partner_claims(self):
        self.write_rows([self.row])
        self.assertIn("1 created", self.run_import())
        venue = Venue.objects.get()
        self.assertEqual(venue.latitude, Decimal("-37.790930"))
        self.assertEqual(venue.import_source, self.row["source"])
        self.assertTrue(venue.checkin_enabled)
        self.assertFalse(venue.is_partner)
        self.assertEqual(User.objects.count(), 0)
        self.assertIn("0 created, 1 existing", self.run_import())
        self.assertEqual(Venue.objects.count(), 1)

    def test_preserves_manual_or_managed_nearby_place_and_disabled_flag(self):
        manager = User.objects.create_user(email="import-manager@example.com", role="CAFE")
        venue = Venue.objects.create(
            name="  Carlton   Veterinary Surgery ", kind="VET", manager_user=manager,
            latitude="-37.790931", longitude="144.971348", address="Manually verified address",
            checkin_enabled=False,
        )
        self.write_rows([self.row])
        self.assertIn("0 created, 1 existing", self.run_import())
        venue.refresh_from_db()
        self.assertEqual(venue.address, "Manually verified address")
        self.assertEqual(venue.manager_user_id, manager.pk)
        self.assertFalse(venue.checkin_enabled)
        self.assertIsNone(venue.import_source)

    def test_dry_run_has_no_persistent_writes(self):
        self.write_rows([self.row])
        self.assertIn("Dry run: 1 created", self.run_import(dry_run=True))
        self.assertFalse(Venue.objects.exists())

    def test_entire_file_validated_before_import_including_reversed_coordinates(self):
        for invalid in (
            {"latitude": "144.971347", "longitude": "-37.790930"},
            {"latitude": "NaN"}, {"kind": "CAFE"}, {"address": ""},
            {"source_url": "https://www.openstreetmap.org/node/1"},
        ):
            with self.subTest(invalid=invalid):
                bad = self.row | {"source": "osm:node:999", "source_url": "https://www.openstreetmap.org/node/999"} | invalid
                self.write_rows([self.row, bad])
                with self.assertRaises(CommandError):
                    self.run_import()
                self.assertFalse(Venue.objects.exists())

    def test_rejects_duplicate_source_or_same_place(self):
        for second in (self.row, self.row | {"source": "osm:node:999", "source_url": "https://www.openstreetmap.org/node/999"}):
            with self.subTest(second=second):
                self.write_rows([self.row, second])
                with self.assertRaises(CommandError):
                    self.run_import()
                self.assertFalse(Venue.objects.exists())

    def test_bundled_snapshot_has_both_categories_and_can_be_imported_twice(self):
        output = io.StringIO()
        call_command("import_melbourne_venues", stdout=output)
        self.assertEqual(set(Venue.objects.values_list("kind", flat=True)), {"VET", "PARK"})
        count = Venue.objects.count()
        self.assertGreaterEqual(count, 6)
        call_command("import_melbourne_venues", stdout=output)
        self.assertEqual(Venue.objects.count(), count)
