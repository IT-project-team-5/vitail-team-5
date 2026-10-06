from io import StringIO
from unittest.mock import patch

from django.core.management import call_command
from django.core.management.base import CommandError
from django.test import SimpleTestCase


class SocialMaintenanceTests(SimpleTestCase):
    def test_once_runs_one_cleanup_sweep(self):
        output = StringIO()
        with patch("social.management.commands.purge_social_presence.purge_expired_presence", return_value=3) as sweep:
            call_command("purge_social_presence", stdout=output)
        sweep.assert_called_once_with()
        self.assertIn("Removed 3", output.getvalue())

    def test_worker_repeats_and_exits_cleanly_on_interrupt(self):
        with patch("social.management.commands.purge_social_presence.purge_expired_presence", return_value=0) as sweep, \
             patch("social.management.commands.purge_social_presence.time.sleep", side_effect=[None, KeyboardInterrupt]) as sleep:
            call_command("purge_social_presence", watch=True, interval=60, stdout=StringIO())
        self.assertEqual(sweep.call_count, 2)
        self.assertEqual(sleep.call_count, 2)
        sleep.assert_called_with(60)

    def test_worker_rejects_invalid_interval(self):
        with self.assertRaisesMessage(CommandError, "at least 1 second"):
            call_command("purge_social_presence", interval=0)
