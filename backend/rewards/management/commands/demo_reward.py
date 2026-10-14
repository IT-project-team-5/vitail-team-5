"""Non-destructive, opt-in local redemption fixture; never grants points."""
from django.conf import settings
from django.contrib.auth import get_user_model
from django.core.management.base import BaseCommand, CommandError
from django.db import transaction

from rewards.catalogue import DEMO_REWARD_EMAIL
from rewards.models import Reward
from venues.services import venue_for


class Command(BaseCommand):
    help = "Configure a fictional 5-point reward (DEBUG only). No real redemption value."

    def add_arguments(self, parser):
        parser.add_argument("--state", choices=("available", "unavailable"), default="available")
        parser.add_argument("--exclusive", action="store_true",
                            help="Also disable other rewards in this development database to test an empty catalogue.")

    @transaction.atomic
    def handle(self, *args, **options):
        if not settings.DEBUG:
            raise CommandError("Demo rewards are disabled when DEBUG=False.")
        user, created = get_user_model().objects.get_or_create(
            email=DEMO_REWARD_EMAIL,
            defaults={"display_name": "Vitail Demo — no real value", "role": "CAFE"},
        )
        if created:
            user.set_unusable_password()
            user.save(update_fields=["password"])
        venue = venue_for(user)
        reward, _ = Reward.objects.update_or_create(
            venue=venue, name="DUMMY reward — no real redemption value",
            defaults={"description": "Development test only. Costs 5 points. Cannot be exchanged for goods, services or cash.",
                      "terms": "DUMMY / DEMO ONLY — no real redemption value.",
                      "point_cost": 5, "is_available": options["state"] == "available",
                      "starts_at": None, "ends_at": None, "daily_quantity_limit": None},
        )
        if options["exclusive"]:
            count = Reward.objects.exclude(pk=reward.pk).update(is_available=False)
            self.stdout.write(f"Disabled {count} other development rewards; re-enable them through café product settings.")
        self.stdout.write(f"Dummy reward {reward.pk}: {options['state']}, 5 points, no real value. Wallets unchanged.")
