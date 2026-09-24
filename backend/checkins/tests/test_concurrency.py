import math
from concurrent.futures import ThreadPoolExecutor
from datetime import timedelta
from threading import Barrier
from unittest import skipUnless
from uuid import uuid4

from django.db import close_old_connections, connection
from django.test import TransactionTestCase
from rest_framework.exceptions import ValidationError

from checkins.models import CheckIn
from checkins.services import collect_checkin, daily_activity_points
from checkins.tests.test_checkins import CheckInFixture
from dogs.models import Breed, Dog
from rewards.models import PointEntry
from rewards.policy import local_date
from walks.services import create_walk


@skipUnless(connection.vendor == "mysql", "Exercises MySQL wallet/qualification locks")
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

    def test_map_and_quest_collect_same_qualification_once(self):
        row = self.opportunity()
        result = self.parallel(lambda index: collect_checkin(owner=self.owner, checkin_id=row.pk, now=self.now)["check_in"].point_entry_id)
        self.assertEqual(result[0], result[1])
        self.assertEqual(PointEntry.objects.filter(user=self.owner).count(), 1)
        self.assertEqual(daily_activity_points(self.owner, local_date(self.now)), 12)

    def test_two_different_collects_compete_for_last_full_reward(self):
        first, second = self.opportunity(), self.opportunity("PARK")
        self.credit(36)
        self.credit(24, category="CHECK_IN")

        def collect(index):
            row = first if index == 0 else second
            try:
                collect_checkin(owner=self.owner, checkin_id=row.pk, now=self.now)
                return "collected"
            except ValidationError:
                return "cap"

        self.assertCountEqual(self.parallel(collect), ["collected", "cap"])
        self.assertEqual(CheckIn.objects.filter(owner=self.owner, point_entry__isnull=False).count(), 1)
        self.assertEqual(daily_activity_points(self.owner, local_date(self.now)), 72)

    def test_checkin_and_walk_share_owner_lock_and_never_exceed_cap(self):
        # Use actual time for the existing walk upload's 12-hour acceptance.
        from django.utils import timezone
        self.now = timezone.now()
        row = self.opportunity()
        self.credit(28)
        self.credit(24, category="CHECK_IN")
        breed = Breed.objects.create(name="Cap race breed", energy_level="LOW", default_size="SMALL")
        dog = Dog.objects.create(owner=self.owner, breed=breed, name="Race dog", age_months=12, size="SMALL", is_brachycephalic=False)
        # A same-date 2km route at 2m/s; skip the very first minutes of a day
        # rather than silently attributing a previous-day walk to today's cap.
        started_at = self.now - timedelta(seconds=1100)
        if local_date(started_at) != local_date(self.now):
            self.skipTest("Needs 1,100 seconds elapsed in the Melbourne business day")
        distance = 2001
        samples = [dict(latitude=0, longitude=math.degrees(distance * i / 101 / 6_371_000),
                        recorded_at=started_at + timedelta(seconds=10 * i), accuracy_m=5, is_simulated=False, segment_id=0)
                   for i in range(102)]

        def operation(index):
            if index == 0:
                try:
                    return collect_checkin(owner=self.owner, checkin_id=row.pk, now=self.now)["awarded_points"]
                except ValidationError:
                    return 0
            return create_walk(owner=self.owner, request_id=uuid4(), started_at=started_at,
                               ended_at=started_at + timedelta(seconds=1010), dog_ids=[dog.pk], samples=samples).points_awarded

        awards = self.parallel(operation)
        total = daily_activity_points(self.owner, local_date(self.now))
        self.assertIn(total, (68, 72))
        self.assertEqual(total, 52 + sum(awards))
        self.assertLessEqual(total, 72)
