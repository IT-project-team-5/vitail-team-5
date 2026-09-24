from concurrent.futures import ThreadPoolExecutor
from threading import Barrier
from unittest import skipUnless
from uuid import uuid4

from django.contrib.auth import get_user_model
from django.db import close_old_connections, connection
from django.test import TransactionTestCase
from django.utils import timezone

from social.models import Friendship
from social.services import request_friendship
from walks.models import WalkSession
from walks.services import WalkConflictError, start_walk_session


@skipUnless(connection.vendor == "mysql", "Exercises real MySQL row locks")
class ActivityConcurrencyTests(TransactionTestCase):
    def setUp(self):
        User = get_user_model()
        self.first = User.objects.create_user(email="parallel-first@example.com", display_name="First")
        self.second = User.objects.create_user(email="parallel-second@example.com", display_name="Second")

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

    def test_parallel_starts_create_exactly_one_active_session(self):
        started_at = timezone.now()

        def start(index):
            try:
                start_walk_session(owner=self.first, request_id=uuid4(), started_at=started_at, validation_version="test-only")
                return "created"
            except WalkConflictError:
                return "conflict"

        self.assertCountEqual(self.parallel(start), ["created", "conflict"])
        self.assertEqual(WalkSession.objects.filter(owner=self.first).count(), 1)
        self.first.refresh_from_db()
        self.assertEqual(self.first.active_walk_session_id, WalkSession.objects.get().pk)

    def test_parallel_reciprocal_requests_preserve_single_pending_relationship(self):
        def request(index):
            sender, recipient = (self.first, self.second) if index == 0 else (self.second, self.first)
            return request_friendship(sender=sender, recipient=recipient).pk

        ids = self.parallel(request)
        self.assertEqual(ids[0], ids[1])
        relationship = Friendship.objects.get()
        self.assertEqual(relationship.status, "PENDING")
        self.assertIsNone(relationship.responded_at)
