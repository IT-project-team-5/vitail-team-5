"""Explicit, idempotent import of the attributed Melbourne park/vet snapshot."""
import csv
import math
import re
from decimal import Decimal, InvalidOperation, ROUND_HALF_UP
from pathlib import Path

from django.core.management.base import BaseCommand, CommandError
from django.db import transaction

from venues.models import Venue


SNAPSHOT = Path(__file__).resolve().parents[2] / "data" / "melbourne_venues.csv"
FIELDS = {"source", "source_url", "name", "kind", "address", "latitude", "longitude"}


def normalized_name(value):
    return " ".join(value.casefold().split())


def nearby(row, venue):
    if venue.latitude is None or venue.longitude is None:
        return False
    latitude_delta = math.radians(float(row["latitude"] - venue.latitude))
    longitude_delta = math.radians(float(row["longitude"] - venue.longitude))
    mean_latitude = math.radians(float(row["latitude"] + venue.latitude) / 2)
    return 6_371_000 * math.hypot(latitude_delta, longitude_delta * math.cos(mean_latitude)) <= 50


def read_snapshot(path):
    rows, sources, places = [], set(), set()
    try:
        with path.open(encoding="utf-8-sig", newline="") as source_file:
            reader = csv.DictReader(source_file)
            if not FIELDS.issubset(reader.fieldnames or []):
                raise CommandError("CSV must contain: " + ", ".join(sorted(FIELDS)))
            for line, raw in enumerate(reader, start=2):
                row = {key: (raw.get(key) or "").strip() for key in FIELDS}
                if re.fullmatch(r"osm:(node|way|relation):[1-9][0-9]*", row["source"]):
                    _, object_type, object_id = row["source"].split(":")
                    expected_url = f"https://www.openstreetmap.org/{object_type}/{object_id}"
                elif re.fullmatch(r"yarra:[a-z]+(?:-[a-z]+)*", row["source"]):
                    expected_url = "https://www.yarracity.vic.gov.au/things-to-do/parks-reserves-and-playgrounds/" + row["source"].split(":")[1]
                else:
                    raise CommandError(f"Line {line}: invalid OpenStreetMap or Yarra Council source identity.")
                if row["source_url"] != expected_url:
                    raise CommandError(f"Line {line}: source URL must match its identity.")
                if not row["name"] or len(row["name"]) > 100 or not row["address"] or len(row["address"]) > 255:
                    raise CommandError(f"Line {line}: supply a name (100 characters) and address (255 characters).")
                if row["kind"] not in {Venue.Kind.VET, Venue.Kind.PARK}:
                    raise CommandError(f"Line {line}: only VET and PARK public places may be imported; onboard partners separately.")
                try:
                    for key in ("latitude", "longitude"):
                        value = Decimal(row[key])
                        if not value.is_finite():
                            raise InvalidOperation
                        row[key] = value.quantize(Decimal("0.000001"), rounding=ROUND_HALF_UP)
                except (InvalidOperation, ValueError):
                    raise CommandError(f"Line {line}: invalid coordinates.") from None
                if not (-38.6 <= row["latitude"] <= -37.3 and 144.4 <= row["longitude"] <= 145.7):
                    raise CommandError(f"Line {line}: coordinates must be in Greater Melbourne (latitude, longitude order).")
                place = (row["kind"], normalized_name(row["name"]), row["latitude"], row["longitude"])
                if row["source"] in sources or place in places:
                    raise CommandError(f"Line {line}: duplicate source or place in CSV.")
                sources.add(row["source"])
                places.add(place)
                rows.append(row)
    except OSError as error:
        raise CommandError(f"Cannot read venue CSV: {error}") from error
    if not rows:
        raise CommandError("Venue CSV is empty.")
    return rows


class Command(BaseCommand):
    help = "Import attributed Melbourne parks/vets without modifying existing venues or accounts."

    def add_arguments(self, parser):
        parser.add_argument("--file", type=Path, default=SNAPSHOT)
        parser.add_argument("--dry-run", action="store_true", help="Validate and show counts; roll back all inserts.")

    def handle(self, *args, **options):
        # Validate the whole file before any writes, then commit the import atomically.
        rows = read_snapshot(options["file"])
        created = skipped = 0
        with transaction.atomic():
            existing = list(Venue.objects.all())
            for row in rows:
                duplicate = next((venue for venue in existing if venue.import_source == row["source"]
                    or (venue.kind == row["kind"] and normalized_name(venue.name) == normalized_name(row["name"])
                        and nearby(row, venue))), None)
                if duplicate:
                    # Never relocate, enable, overwrite, or reassign a managed/manual venue.
                    skipped += 1
                    continue
                venue = Venue(
                    name=row["name"], kind=row["kind"], address=row["address"],
                    latitude=row["latitude"], longitude=row["longitude"],
                    import_source=row["source"], source_url=row["source_url"],
                    description=(("Public place data © OpenStreetMap contributors (ODbL). "
                        if row["source"].startswith("osm:") else "Location and address: Yarra City Council. ") + row["source_url"]),
                    is_active=True, checkin_enabled=True, is_partner=False,
                )
                venue.full_clean()
                venue.save()
                existing.append(venue)
                created += 1
            if options["dry_run"]:
                transaction.set_rollback(True)
        mode = "Dry run" if options["dry_run"] else "Import"
        self.stdout.write(self.style.SUCCESS(f"{mode}: {created} created, {skipped} existing places preserved."))
