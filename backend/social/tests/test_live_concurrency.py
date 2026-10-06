from concurrent.futures import ThreadPoolExecutor
from datetime import timedelta
from threading import Barrier
from unittest import skipUnless
from uuid import uuid4

from django.contrib.auth import get_user_model
from django.db import close_old_connections, connection
from django.test import TransactionTestCase
from django.utils import timezone

from social.live import refresh_invitations, report_presence, respond_invitation, send_invitation, start_session, update_preferences, update_session_state
from social.models import NetWalkInvitation
from walks.models import WalkSession


@skipUnless(connection.vendor == "mysql", "Exercises real MySQL row locks")
class LiveSocialConcurrencyTests(TransactionTestCase):
    def setUp(self):
        User = get_user_model()
        self.first = User.objects.create_user(email="net-parallel-first@example.com", display_name="First", net_matching_enabled=True)
        self.second = User.objects.create_user(email="net-parallel-second@example.com", display_name="Second", net_matching_enabled=True)
        self.prepare_pair()

    def prepare_pair(self):
        started = timezone.now() - timedelta(seconds=1)
        self.sessions = [start_session(owner=user, request_id=uuid4(), started_at=started) for user in (self.first, self.second)]
        for user, session in zip((self.first, self.second), self.sessions):
            report_presence(owner=user, session_id=session.pk, latitude=0, longitude=0, accuracy_m=5, recorded_at=timezone.now(), is_simulated=False)
        self.invitation = send_invitation(sender=self.first, recipient=self.second)
        respond_invitation(actor=self.second, invitation_id=self.invitation.pk, accept=True)

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

    def test_both_owners_can_finish_concurrently_without_cross_session_deadlock(self):
        for iteration in range(5):
            if iteration:
                self.prepare_pair()

            def finish(index):
                session = self.sessions[index]
                owner = self.first if index == 0 else self.second
                return update_session_state(owner=owner, session_id=session.pk, state="FINISHED").state

            self.assertEqual(self.parallel(finish), ["FINISHED", "FINISHED"])
            self.assertFalse(NetWalkInvitation.objects.filter(status="ACTIVE").exists())
        self.assertEqual(WalkSession.objects.filter(state="FINISHED").count(), 10)

    def test_finish_and_matching_opt_out_do_not_deadlock(self):
        def operate(index):
            if index == 0:
                return update_session_state(owner=self.first, session_id=self.sessions[0].pk, state="FINISHED").state
            return update_preferences(owner=self.second, net_matching_enabled=False).net_matching_enabled

        self.assertEqual(self.parallel(operate), ["FINISHED", False])
        self.assertFalse(NetWalkInvitation.objects.filter(status="ACTIVE").exists())

    def test_worker_expiry_and_owner_finish_do_not_invert_locks(self):
        future = timezone.now() + timedelta(minutes=1)

        def operate(index):
            if index == 0:
                return update_session_state(owner=self.first, session_id=self.sessions[0].pk, state="FINISHED").state
            refresh_invitations(self.second.pk, now=future)
            return "expired"

        self.assertEqual(self.parallel(operate), ["FINISHED", "expired"])
        self.assertFalse(NetWalkInvitation.objects.filter(status="ACTIVE").exists())

    def test_invitation_foreign_key_support_indexes_are_immutable(self):
        with connection.cursor() as cursor:
            constraints = connection.introspection.get_constraints(cursor, NetWalkInvitation._meta.db_table)
        self.assertEqual(constraints["net_inv_sender_owner"]["columns"], ["sender_id"])
        self.assertEqual(constraints["net_inv_recipient_owner"]["columns"], ["recipient_id"])
        self.assertNotIn("net_invitation_sender", constraints)
        self.assertNotIn("net_invitation_recipient", constraints)
