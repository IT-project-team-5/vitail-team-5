"""Replace local development accounts with a small fictional demo catalogue."""

import json
import os
from pathlib import Path
import secrets

from django.conf import settings
from django.contrib.admin.models import LogEntry
from django.contrib.sessions.models import Session
from django.core.management.base import BaseCommand, CommandError
from django.db import connection, transaction
from django.utils import timezone

from accounts.models import CafeProfile, User
from dogs.models import Dog
from rewards.models import CafeOrderFeedState, PointEntry, Redemption, Reward
from rewards.services import credit_points
from walks.models import Walk


DEMO_CAFES = (
    {
        "email": "riverside@vitail.test",
        "name": "Riverside Paws Café",
        "address": "Demo address: 12 Fictional River Walk, Southbank VIC 3006",
        "description": (
            "A relaxed coffee stop after a riverside walk, with smooth espresso and "
            "freshly prepared breakfast favourites. Our dog-friendly terrace has water "
            "bowls and shaded seating, so you and your walking companion can settle in."
        ),
        "opening_hours": "Mon–Fri 7:00 am–3:00 pm; Sat–Sun 8:00 am–4:00 pm",
        "products": (
            ("Espresso", "A rich double shot with chocolate and toasted-nut notes.", 40),
            ("Flat White", "Double espresso with silky steamed milk; oat milk available.", 60),
            ("Iced Latte", "Chilled espresso poured over milk and ice.", 70),
            ("Banana Bread", "A thick slice of house-style banana bread, served warm.", 90),
            ("Avocado Toast", "Sourdough with smashed avocado, lemon and fresh herbs.", 150),
        ),
    },
    {
        "email": "garden@vitail.test",
        "name": "Garden Tails Café",
        "address": "Demo address: 28 Imaginary Garden Lane, Carlton VIC 3053",
        "description": (
            "A welcoming neighbourhood café inspired by Melbourne's leafy gardens. "
            "Bring your dog to our sunny courtyard for seasonal brunch, freshly baked "
            "muffins and a thoughtful tea selection. A quiet spot to recharge after a walk."
        ),
        "opening_hours": "Mon–Fri 7:30 am–3:30 pm; Sat–Sun 8:00 am–4:00 pm",
        "products": (
            ("Long Black", "A smooth double espresso over hot water.", 50),
            ("English Breakfast Tea", "A fragrant pot of black tea with milk on the side.", 50),
            ("Matcha Latte", "Whisked green tea with steamed milk; oat milk available.", 80),
            ("Blueberry Muffin", "A soft blueberry muffin with a golden crumble topping.", 90),
            ("Garden Veggie Toastie", "Roast vegetables, cheese and basil pesto on sourdough.", 140),
        ),
    },
    {
        "email": "laneway@vitail.test",
        "name": "Laneway Bark Espresso",
        "address": "Demo address: 7 Make-Believe Espresso Lane, Melbourne VIC 3000",
        "description": (
            "A friendly laneway coffee bar serving specialty espresso, slow-steeped "
            "cold brew and buttery bakery treats. Stop by for a quick takeaway or enjoy "
            "a hearty lunch at our outdoor tables, where dogs are always welcome."
        ),
        "opening_hours": "Mon–Fri 6:30 am–3:00 pm; Sat 8:00 am–2:00 pm; Sun closed",
        "products": (
            ("Piccolo Latte", "A small espresso with a smooth layer of steamed milk.", 50),
            ("Cappuccino", "Espresso, steamed milk and foam with a dusting of cocoa.", 60),
            ("Cold Brew", "Slow-steeped coffee served chilled with a clean, mellow finish.", 80),
            ("Butter Croissant", "A flaky, golden pastry baked with butter.", 90),
            ("Chicken Sourdough Sandwich", "Roast chicken, crisp greens and herb mayo on sourdough.", 180),
        ),
    },
)


class Command(BaseCommand):
    help = (
        "DESTRUCTIVE local demo reset: replace all accounts and their activity with "
        "one owner, one admin, and three fictional cafés with five products each. "
        "Back up the database first and stop other writers while running this command. "
        "Requires DEBUG=True and the exact current database name."
    )

    def add_arguments(self, parser):
        parser.add_argument(
            "--confirm-database", required=True,
            help="Exact configured database name; acknowledges deletion of all existing accounts.",
        )
        parser.add_argument(
            "--credentials-file", required=True,
            help="New JSON file for generated passwords (created with owner-only permissions).",
        )
        parser.add_argument(
            "--owner-points", type=int, default=10000,
            help="Demo owner's initial point balance, from 1 to 1,000,000 (default: 10,000).",
        )

    def handle(self, *args, **options):
        if not settings.DEBUG:
            raise CommandError("Demo reset is disabled when DEBUG=False.")
        database_name = str(connection.settings_dict["NAME"])
        if options["confirm_database"] != database_name:
            raise CommandError("--confirm-database must exactly match the configured database name.")
        owner_points = options["owner_points"]
        if not 1 <= owner_points <= 1_000_000:
            raise CommandError("--owner-points must be between 1 and 1,000,000.")

        # O_EXCL also refuses symlinks, so an existing file is never overwritten.
        credentials_path = Path(options["credentials_file"]).expanduser().absolute()
        try:
            descriptor = os.open(credentials_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        except OSError as error:
            raise CommandError(
                f"Cannot create a new credentials file at {credentials_path}: {error.strerror}"
            ) from error

        try:
            with os.fdopen(descriptor, "w", encoding="utf-8") as credentials_file:
                os.fchmod(credentials_file.fileno(), 0o600)
                with transaction.atomic():
                    self._delete_account_data()
                    accounts = self._create_accounts(owner_points)
                    json.dump(
                        {
                            "notice": "FICTIONAL LOCAL DEMO DATA. Keep this password file private.",
                            "database": database_name,
                            "created_at": timezone.now().isoformat(),
                            "owner_points": owner_points,
                            "accounts": accounts,
                        },
                        credentials_file, ensure_ascii=False, indent=2,
                    )
                    credentials_file.write("\n")
                    # Persist credentials before committing their accounts. A write failure
                    # must restore the old data, never leave inaccessible replacement users.
                    credentials_file.flush()
                    os.fsync(credentials_file.fileno())
                    credentials_file.close()
        except BaseException:
            credentials_path.unlink(missing_ok=True)
            raise

        self.stdout.write(self.style.SUCCESS(
            f"Demo reset complete: 1 owner ({owner_points:,} points), 1 admin, "
            f"3 cafés, 15 available products. Credentials: {credentials_path}"
        ))

    @staticmethod
    def _delete_account_data():
        # Respect protected foreign keys. DELETE preserves sequences, so a token
        # issued for a removed user cannot acquire a new account with the same ID.
        Walk.dogs.through.objects.all().delete()
        Walk.objects.all().delete()
        Redemption.objects.all().delete()
        Reward.objects.all().delete()
        PointEntry.objects.all().delete()
        CafeOrderFeedState.objects.all().delete()
        Dog.objects.all().delete()
        CafeProfile.objects.all().delete()
        Session.objects.all().delete()
        LogEntry.objects.all().delete()
        User.objects.all().delete()

    @staticmethod
    def _create_accounts(owner_points):
        accounts = []

        def create_account(*, email, name, role):
            password = secrets.token_urlsafe(32)
            create = User.objects.create_superuser if role == User.Role.ADMIN else User.objects.create_user
            user = create(email=email, display_name=name, role=role, password=password)
            accounts.append({
                "email": email, "password": password, "role": role,
                "cafe_name": name if role == User.Role.CAFE else None,
            })
            return user

        owner = create_account(email="owner@vitail.test", name="Demo Walker", role=User.Role.OWNER)
        create_account(email="admin@vitail.test", name="Demo Admin", role=User.Role.ADMIN)
        credit_points(
            user=owner, amount=owner_points, type=PointEntry.Type.ADMIN,
            source_reference=f"demo-reset:owner:{owner.pk}",
        )
        for cafe_data in DEMO_CAFES:
            cafe = create_account(email=cafe_data["email"], name=cafe_data["name"], role=User.Role.CAFE)
            CafeProfile.objects.create(
                user=cafe, address=cafe_data["address"],
                description=cafe_data["description"], opening_hours=cafe_data["opening_hours"],
            )
            for name, description, cost in cafe_data["products"]:
                Reward.objects.create(
                    cafe_user=cafe, name=name, description=description,
                    point_cost=cost, is_available=True,
                )
        return accounts
