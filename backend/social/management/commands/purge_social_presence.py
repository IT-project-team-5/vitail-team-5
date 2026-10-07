import time

from django.core.management.base import BaseCommand, CommandError
from django.db import close_old_connections

from social.live import purge_expired_presence


class Command(BaseCommand):
    help = "Clear expired live positions and remove raw social GPS older than fifteen minutes."

    def add_arguments(self, parser):
        parser.add_argument("--watch", action="store_true", help="Repeat until stopped.")
        parser.add_argument("--interval", type=int, default=60, help="Seconds between sweeps (default 60).")

    def handle(self, *args, **options):
        if options["interval"] < 1:
            raise CommandError("--interval must be at least 1 second.")
        try:
            while True:
                close_old_connections()
                count = purge_expired_presence()
                if count or not options["watch"]:
                    self.stdout.write(f"Removed {count} expired GPS evidence rows and cleared expired positions.")
                if not options["watch"]:
                    return
                time.sleep(options["interval"])
        except KeyboardInterrupt:
            return
