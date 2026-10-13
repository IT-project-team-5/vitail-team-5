from datetime import timedelta
from uuid import uuid4

from django.db import connection
from django.db.migrations.executor import MigrationExecutor
from django.test import TransactionTestCase
from django.utils import timezone


class DogMapProfileMigrationTests(TransactionTestCase):
    def test_legacy_owner_gets_defaults_without_changing_existing_preferences(self):
        executor = MigrationExecutor(connection)
        leaves = executor.loader.graph.leaf_nodes()
        try:
            executor.migrate([("accounts", "0005_user_activity_preferences")])
            executor = MigrationExecutor(connection)
            old = executor.loader.project_state(list(executor.loader.applied_migrations)).apps
            User = old.get_model("accounts", "User")
            owner = User.objects.create(
                email="legacy-dog-profile@example.com", display_name="Legacy owner", role="OWNER",
                virtual_avatar_key="paw", location_visibility="FRIENDS", net_matching_enabled=True,
            )
            public_id = owner.public_id
            executor = MigrationExecutor(connection)
            executor.migrate(leaves)
            current = executor.loader.project_state(leaves).apps
            migrated = current.get_model("accounts", "User").objects.get(pk=owner.pk)
            self.assertEqual(migrated.dog_avatar_breed, "goldenRetriever")
            self.assertEqual(migrated.bandana_color, "none")
            self.assertEqual(migrated.virtual_avatar_key, "paw")
            self.assertEqual(migrated.location_visibility, "FRIENDS")
            self.assertTrue(migrated.net_matching_enabled)
            self.assertEqual(migrated.public_id, public_id)
        finally:
            MigrationExecutor(connection).migrate(leaves)


class InvitationShapeMigrationTests(TransactionTestCase):
    def test_every_legacy_status_timestamp_shape_is_canonicalized(self):
        executor = MigrationExecutor(connection)
        leaves = executor.loader.graph.leaf_nodes()
        try:
            executor.migrate([("social", "0003_stable_invitation_foreign_key_indexes")])
            executor = MigrationExecutor(connection)
            old = executor.loader.project_state(list(executor.loader.applied_migrations)).apps
            User = old.get_model("accounts", "User")
            Session = old.get_model("walks", "WalkSession")
            Invitation = old.get_model("social", "NetWalkInvitation")
            first = User.objects.create(
                email="legacy-net-first@example.com", display_name="First", role="OWNER",
            )
            second = User.objects.create(
                email="legacy-net-second@example.com", display_name="Second", role="OWNER",
            )
            now = timezone.now()
            sessions = [
                Session.objects.create(
                    owner=owner, request_id=uuid4(), state="RECORDING",
                    started_at=now - timedelta(minutes=2), heartbeat_at=now,
                    validation_version="legacy-test",
                )
                for owner in (first, second)
            ]
            statuses = (
                "PENDING", "ACTIVE", "ENDED", "DECLINED", "EXPIRED", "CANCELLED", "UNKNOWN",
            )
            expected = {}
            for status in statuses:
                for has_accepted in (False, True):
                    for has_ended in (False, True):
                        key = f"{status}:{int(has_accepted)}:{int(has_ended)}"
                        row = Invitation.objects.create(
                            sender=first, recipient=second,
                            sender_session=sessions[0], recipient_session=sessions[1],
                            status=status, expires_at=now + timedelta(minutes=2),
                            accepted_at=now - timedelta(minutes=1) if has_accepted else None,
                            ended_at=now if has_ended else None,
                            end_reason=key,
                        )
                        expected[row.pk] = self.expected_shape(status, has_accepted, has_ended)

            inverted_expiry = Invitation.objects.create(
                sender=first, recipient=second,
                sender_session=sessions[0], recipient_session=sessions[1],
                status="PENDING", expires_at=now + timedelta(minutes=1),
                end_reason="inverted-expiry",
            )
            Invitation.objects.filter(pk=inverted_expiry.pk).update(
                created_at=now,
                expires_at=now - timedelta(minutes=1),
            )
            expected[inverted_expiry.pk] = ("PENDING", False, False)

            executor = MigrationExecutor(connection)
            executor.migrate(leaves)
            current = executor.loader.project_state(leaves).apps
            upgraded = current.get_model("social", "NetWalkInvitation")
            for row in upgraded.objects.filter(pk__in=expected):
                self.assertEqual(
                    (row.status, row.accepted_at is not None, row.ended_at is not None),
                    expected[row.pk],
                    row.end_reason,
                )
                self.assertGreater(row.expires_at, row.created_at, row.end_reason)
                if row.accepted_at is not None:
                    self.assertGreaterEqual(row.accepted_at, row.created_at, row.end_reason)
                if row.ended_at is not None:
                    lower_bound = row.accepted_at or row.created_at
                    self.assertGreaterEqual(row.ended_at, lower_bound, row.end_reason)
        finally:
            MigrationExecutor(connection).migrate(leaves)

    @staticmethod
    def expected_shape(status, accepted, ended):
        if status == "PENDING":
            if accepted and ended:
                return "ENDED", True, True
            if accepted:
                return "ACTIVE", True, False
            if ended:
                return "CANCELLED", False, True
            return "PENDING", False, False
        if status == "ACTIVE":
            return ("ENDED", True, True) if ended else ("ACTIVE", True, False)
        if status == "ENDED":
            return ("ENDED", True, True) if accepted else ("CANCELLED", False, True)
        if status in ("DECLINED", "EXPIRED", "CANCELLED"):
            return ("ENDED", True, True) if accepted else (status, False, True)
        return ("ENDED", True, True) if accepted else ("CANCELLED", False, True)
