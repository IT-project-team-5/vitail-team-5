from concurrent.futures import ThreadPoolExecutor
from threading import Barrier
from unittest import skipUnless

from django.db import close_old_connections, connection
from django.test import TransactionTestCase
from rest_framework.exceptions import ValidationError

from checkins.models import CheckIn
from checkins.services import collect_checkin, daily_activity_points, settle_walk_checkins
from checkins.tests.test_checkins import CheckInFixture
from rewards.models import PointEntry
from rewards.policy import local_date


@skipUnless(connection.vendor == "mysql", "Exercises production MySQL owner/wallet locks")
class CheckInConcurrencyTests(CheckInFixture, TransactionTestCase):
    def parallel(self, operation):
        barrier = Barrier(2)
        def worker(index):
            close_old_connections()
            try:
                barrier.wait(timeout=10)
                return operation(index)
            finally:
                close_old_connections()
        with ThreadPoolExecutor(max_workers=2) as pool:
            futures = [pool.submit(worker, index) for index in range(2)]
            return [future.result(timeout=20) for future in futures]

    def test_two_walk_finishes_cannot_reward_same_category_twice(self):
        first = self.opportunity()
        other_context = self.walk_context()
        second = self.opportunity("CAFE", walk_context=other_context)
        walks = [self.completed_walk(), self.completed_walk(context=other_context)]
        self.parallel(lambda index: settle_walk_checkins(walks[index], now=self.now))
        self.assertEqual(CheckIn.objects.filter(point_entry__isnull=False).count(), 1)
        self.assertEqual(PointEntry.objects.filter(earn_category="CHECK_IN").count(), 1)
        self.assertEqual(daily_activity_points(self.owner, local_date(self.now)), 12)

    def test_two_walk_finishes_compete_for_last_full_daily_award(self):
        self.credit(60)
        self.opportunity("VET")
        other = self.walk_context()
        self.opportunity("PARK", walk_context=other)
        walks = [self.completed_walk(), self.completed_walk(context=other)]
        self.parallel(lambda index: settle_walk_checkins(walks[index], now=self.now))
        self.assertEqual(CheckIn.objects.filter(point_entry__isnull=False).count(), 1)
        self.assertEqual(daily_activity_points(self.owner, local_date(self.now)), 72)

    def test_settlement_retry_and_legacy_collect_share_one_award(self):
        row = self.opportunity()
        walk = self.completed_walk()
        def operation(index):
            if index == 0:
                settle_walk_checkins(walk, now=self.now)
                return
            try:
                collect_checkin(owner=self.owner, checkin_id=row.pk)
            except ValidationError:
                pass
        self.parallel(operation)
        self.parallel(lambda index: settle_walk_checkins(walk, now=self.now))
        self.assertEqual(PointEntry.objects.filter(earn_category="CHECK_IN").count(), 1)
        self.assertEqual(daily_activity_points(self.owner, local_date(self.now)), 12)
