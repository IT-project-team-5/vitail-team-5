import time

from django.core.management.base import BaseCommand, CommandError
from django.db import close_old_connections

from rewards.services import expire_points, expire_redemptions


class Command(BaseCommand):
    help = "Refund uncollected expired orders and expire remaining old points. Safe to repeat."

    def add_arguments(self, parser):
        parser.add_argument("--watch", action="store_true", help="Repeat until stopped.")
        parser.add_argument("--interval", type=int, default=60, help="Seconds between sweeps (default 60).")

    def handle(self, *args, **options):
        if options["interval"] < 1:
            raise CommandError("--interval must be at least 1 second.")
        try:
            while True:
                if options["watch"]:
                    close_old_connections()
                orders = expire_redemptions()
                points = expire_points()
                if orders or points or not options["watch"]:
                    self.stdout.write(f"Refunded {orders} expired order(s); expired {points} point lot(s).")
                if not options["watch"]:
                    return
                time.sleep(options["interval"])
        except KeyboardInterrupt:
            return
