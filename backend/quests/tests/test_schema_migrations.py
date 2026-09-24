"""Exercise the real forward data migrations, not copies of their functions."""
from datetime import date, datetime, timedelta, timezone
from uuid import uuid4

from django.db import connection
from django.db.migrations.executor import MigrationExecutor
from django.test import TransactionTestCase


class CoreSchemaBackfillMigrationTests(TransactionTestCase):
    migrate_from = [
        ("accounts", "0004_remove_cafeprofile"),
        ("rewards", "0003_venue_catalogue"),
        ("quests", "0002_questaward"),
        ("evidence", "0002_documententitlement_collected_at"),
        ("walks", "0001_initial"),
        ("dogs", "0003_dog_date_of_birth"),
    ]
    ledger_receipt_fields = (
        "id", "user_id", "amount", "remaining_points", "type", "source_reference", "expires_at", "created_at",
    )

    def test_core_backfills_preserve_history_and_classify_only_proven_earnings(self):
        executor = MigrationExecutor(connection)
        leaves = executor.loader.graph.leaf_nodes()
        try:
            executor.migrate(self.migrate_from)
            executor = MigrationExecutor(connection)
            # Targeting one app does not revert every unrelated app. Historical
            # models must match the complete set actually applied in this DB.
            old = executor.loader.project_state(list(executor.loader.applied_migrations)).apps
            fixture = self.seed_historical_state(old)
            executor = MigrationExecutor(connection)
            executor.migrate(leaves)
            new = executor.loader.project_state(leaves).apps
            self.assert_accounts(new, fixture)
            self.assert_ledger(new, fixture)
            self.assert_birthdays(new, fixture)
            self.assert_documents(new, fixture)
        finally:
            MigrationExecutor(connection).migrate(leaves)

    def seed_historical_state(self, apps):
        User = apps.get_model("accounts", "User")
        Breed = apps.get_model("dogs", "Breed")
        Dog = apps.get_model("dogs", "Dog")
        Walk = apps.get_model("walks", "Walk")
        Entry = apps.get_model("rewards", "PointEntry")
        Award = apps.get_model("quests", "QuestAward")
        Entitlement = apps.get_model("evidence", "DocumentEntitlement")
        Submission = apps.get_model("evidence", "DocumentSubmission")
        Fingerprint = apps.get_model("evidence", "EvidenceFingerprint")
        # UTC July 11, Melbourne July 12: a backfill must preserve business dates.
        at = datetime(2025, 7, 11, 15, 30, tzinfo=timezone.utc)
        day = date(2025, 7, 12)
        users = [User.objects.create(
            email=f"core-migration-{index}@example.com", display_name=f"Original {index}",
            password=f"!preserved-password-{index}", role="CAFE" if index == 4 else "OWNER",
            is_active=index != 3,
        ) for index in range(5)]
        first, second = users[:2]
        original_users = list(User.objects.filter(pk__in=[user.pk for user in users]).order_by("pk").values(
            "id", "email", "display_name", "password", "role", "is_active",
        ))
        breed = Breed.objects.create(name="Core migration breed", energy_level="LOW", default_size="SMALL")

        def dog(owner, name):
            return Dog.objects.create(owner=owner, breed=breed, name=name, age_months=60,
                                      date_of_birth=date(2020, 7, 12), size="SMALL", is_brachycephalic=False)

        birthday_dog = dog(first, "Historical birthday dog")
        active_dog = dog(second, "Second birthday dog")
        document_dog = dog(first, "Pending documents")
        paid_document_dog = dog(second, "Collected documents")
        classified, unclassified = {}, []

        def credit(owner, amount, source, *, type="EARN", remaining=None):
            entry = Entry.objects.create(
                user=owner, amount=amount, remaining_points=amount if remaining is None else remaining,
                type=type, source_reference=source, expires_at=at + timedelta(days=365),
            )
            Entry.objects.filter(pk=entry.pk).update(created_at=at)
            entry.refresh_from_db()
            return entry

        def walk(owner, points):
            return Walk.objects.create(owner=owner, request_id=uuid4(), request_fingerprint="a" * 64,
                                       started_at=at - timedelta(minutes=10), ended_at=at, point_date=day,
                                       distance_m=1000, points_awarded=points)

        good_walk = walk(first, 8)
        valid_walk_entry = credit(first, 8, f"walk:{good_walk.pk}", remaining=0)
        classified[valid_walk_entry.pk] = ("WALK", day, "walk-gps-v1")
        wrong_owner_walk = walk(first, 8)
        unclassified.append(credit(second, 8, f"walk:{wrong_owner_walk.pk}").pk)
        wrong_amount_walk = walk(first, 8)
        unclassified.append(credit(first, 9, f"walk:{wrong_amount_walk.pk}").pk)
        refund_walk = walk(first, 8)
        unclassified.append(credit(first, 8, f"walk:{refund_walk.pk}", type="REFUND").pk)
        unclassified.append(credit(first, 8, "walk:999999999999").pk)
        unclassified.append(credit(first, 300, "document:unlinked-legacy-event").pk)
        unclassified.append(credit(first, 60, "birthday:unlinked-admin", type="ADMIN").pk)

        birthday_records = []
        for owner, participant, amount, remaining in ((first, birthday_dog, 55, 17), (second, active_dog, 60, 0)):
            entry = credit(owner, amount, f"legacy-birthday:{participant.pk}:2025", remaining=remaining)
            award = Award.objects.create(owner=owner, dog=participant, dog_id_snapshot=participant.pk,
                                         dog_name_snapshot=participant.name, kind="BIRTHDAY", year=2025,
                                         point_entry=entry, rules_version="historical-birthday-policy")
            Award.objects.filter(pk=award.pk).update(awarded_at=at)
            birthday_records.append(dict(id=award.pk, owner_id=owner.pk, dog_id_snapshot=participant.pk,
                                         dog_name_snapshot=participant.name, point_entry_id=entry.pk,
                                         amount=amount, awarded_at=at))
            classified[entry.pk] = ("BIRTHDAY", day, "historical-birthday-policy")
        # Current profile ownership/name are not a historical receipt. Deletion
        # must not stop migration of the immutable birthday identity.
        Dog.objects.filter(pk=birthday_dog.pk).update(owner=second, name="Renamed after collection")
        birthday_dog.delete()

        documents = []
        submissions = []

        def document(owner, participant, kind, key, *, entry=None, submitted_points=0):
            entitlement = Entitlement.objects.create(
                owner=owner, dog=participant, dog_id_snapshot=participant.pk, kind=kind,
                entitlement_key=key, point_entry=entry, collected_at=at if entry else None,
                event_date=day if kind == "VET_CHECKUP" else None,
                valid_from=date(2025, 1, 1) if kind == "MICROCHIP_REGISTRATION" else None,
                valid_to=date(2025, 12, 31) if kind == "MICROCHIP_REGISTRATION" else None,
            )
            response = {"original_receipt": str(uuid4()), "awarded_points": submitted_points}
            submission = Submission.objects.create(
                owner=owner, dog=participant, dog_id_snapshot=participant.pk, dog_name_snapshot=participant.name,
                kind=kind, request_id=uuid4(), request_fingerprint="b" * 64,
                entitlement=entitlement, registration_number=f"test-{key}", awarded_points=submitted_points,
                response_snapshot=response,
            )
            Fingerprint.objects.create(owner=owner, dog_id_snapshot=participant.pk, kind=kind,
                                       fingerprint=f"{submission.pk:064x}", entitlement=entitlement, is_file=False)
            documents.append(dict(id=entitlement.pk, kind=kind, point_entry_id=entry.pk if entry else None,
                                  owner_id=owner.pk, dog_id_snapshot=participant.pk, entitlement_key=key,
                                  collected_at=at if entry else None,
                                  promised_points=entry.amount if entry else {"COUNCIL_REGISTRATION": 300, "MICROCHIP_REGISTRATION": 300, "VET_CHECKUP": 200}[kind]))
            submissions.append(dict(id=submission.pk, entitlement_id=entitlement.pk, awarded_points=submitted_points,
                                    response_snapshot=response, request_id=submission.request_id,
                                    registration_number=submission.registration_number))
            return entitlement

        for kind, key in (("COUNCIL_REGISTRATION", "lifetime"), ("MICROCHIP_REGISTRATION", "2025-period"), ("VET_CHECKUP", "2025-07-12")):
            document(first, document_dog, kind, key)
        old_council = credit(second, 275, "legacy-document:council", remaining=100)
        document(second, paid_document_dog, "COUNCIL_REGISTRATION", "lifetime", entry=old_council, submitted_points=275)
        classified[old_council.pk] = ("DOCUMENT", day, "documents-2026-09-25")
        collected_after_submit = credit(second, 190, "legacy-document:vet", remaining=30)
        document(second, paid_document_dog, "VET_CHECKUP", "2025-07-12", entry=collected_after_submit)
        classified[collected_after_submit.pk] = ("DOCUMENT", day, "documents-2026-09-25")
        # A legacy FK alone is insufficient proof if the ledger owner differs.
        foreign_entry = credit(first, 39, "legacy-unrelated-credit")
        document(second, paid_document_dog, "MICROCHIP_REGISTRATION", "2025-period", entry=foreign_entry)
        unclassified.append(foreign_entry.pk)

        return dict(users=original_users, birthdays=birthday_records, documents=documents, submissions=submissions,
                    classified=classified, unclassified=unclassified,
                    ledger=list(Entry.objects.order_by("pk").values(*self.ledger_receipt_fields)),
                    fingerprints=list(Fingerprint.objects.order_by("pk").values()), day=day)

    def assert_accounts(self, apps, fixture):
        User = apps.get_model("accounts", "User")
        users = User.objects.filter(pk__in=[row["id"] for row in fixture["users"]]).order_by("pk")
        self.assertEqual(list(users.values(*fixture["users"][0].keys())), fixture["users"])
        public_ids = list(users.values_list("public_id", flat=True))
        self.assertEqual(len(public_ids), len(set(public_ids)))
        for user in users:
            self.assertRegex(user.public_id, r"^[0-9a-f]{32}$")
            self.assertEqual(user.auth_version, 1)
            self.assertEqual(user.location_visibility, "OFF")
            self.assertFalse(user.net_matching_enabled)
            self.assertFalse(user.leaderboard_visible)
            self.assertIsNone(user.active_walk_session_id)

    def assert_ledger(self, apps, fixture):
        Entry = apps.get_model("rewards", "PointEntry")
        self.assertEqual(list(Entry.objects.order_by("pk").values(*self.ledger_receipt_fields)), fixture["ledger"])
        for identity, expected in fixture["classified"].items():
            with self.subTest(classified_entry=identity):
                row = Entry.objects.get(pk=identity)
                self.assertEqual((row.earn_category, row.earned_on, row.rules_version), expected)
        for identity in fixture["unclassified"]:
            with self.subTest(unclassified_entry=identity):
                row = Entry.objects.get(pk=identity)
                self.assertEqual((row.earn_category, row.earned_on, row.rules_version), (None, None, None))

    def assert_birthdays(self, apps, fixture):
        Award = apps.get_model("quests", "QuestAward")
        self.assertEqual(Award.objects.count(), len(fixture["birthdays"]))
        for expected in fixture["birthdays"]:
            award = Award.objects.get(pk=expected["id"])
            for field in ("owner_id", "dog_id_snapshot", "dog_name_snapshot", "point_entry_id", "awarded_at"):
                self.assertEqual(getattr(award, field), expected[field])
            self.assertEqual(award.promised_points, expected["amount"])
            self.assertEqual(award.qualified_at, expected["awarded_at"])
            self.assertEqual(award.qualified_on, fixture["day"])
            self.assertEqual(award.qualification_key, f"birthday:{expected['dog_id_snapshot']}:2025")
            self.assertEqual(award.rules_version, "historical-birthday-policy")
        self.assertIsNone(Award.objects.get(pk=fixture["birthdays"][0]["id"]).dog_id)

    def assert_documents(self, apps, fixture):
        Entitlement = apps.get_model("evidence", "DocumentEntitlement")
        Submission = apps.get_model("evidence", "DocumentSubmission")
        Fingerprint = apps.get_model("evidence", "EvidenceFingerprint")
        self.assertEqual(Entitlement.objects.count(), len(fixture["documents"]))
        for expected in fixture["documents"]:
            row = Entitlement.objects.get(pk=expected["id"])
            for field, value in expected.items():
                self.assertEqual(getattr(row, field), value)
            self.assertEqual(row.eligibility_status, "ELIGIBLE")
            self.assertEqual(row.rules_version, "documents-2026-09-25")
        for expected in fixture["submissions"]:
            row = Submission.objects.get(pk=expected["id"])
            for field, value in expected.items():
                self.assertEqual(getattr(row, field), value)
            self.assertEqual(row.audit_status, "NOT_REVIEWED")
            self.assertIsNone(row.file_size_bytes)
            self.assertIsNone(row.reviewed_at)
            self.assertIsNone(row.reviewed_by_id)
        self.assertEqual(list(Fingerprint.objects.order_by("pk").values()), fixture["fingerprints"])
