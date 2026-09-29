from datetime import datetime, timedelta, timezone as dt_timezone
from uuid import uuid4

from django.db import connection
from django.test import TransactionTestCase

from evidence.models import DocumentEntitlement, DocumentSubmission
from rewards.models import PointEntry


class CouncilAnnualMigrationTests(TransactionTestCase):
    def test_original_submission_year_and_melbourne_fallback_preserve_all_history(self):
        from django.db.migrations.executor import MigrationExecutor

        executor = MigrationExecutor(connection)
        latest = executor.loader.graph.leaf_nodes()
        before = [("evidence", "0004_registration_details") if app == "evidence" else (app, name)
                  for app, name in latest]
        try:
            executor.migrate(before)
            apps = executor.loader.project_state(before).apps
            owner = apps.get_model("accounts", "User").objects.create(email="annual-migration@example.com", display_name="Legacy")
            Entitlement = apps.get_model("evidence", "DocumentEntitlement")
            Submission = apps.get_model("evidence", "DocumentSubmission")
            Entry = apps.get_model("rewards", "PointEntry")
            entry = Entry.objects.create(user_id=owner.pk, type="EARN", amount=275, remaining_points=123,
                source_reference="preserved-council-credit", expires_at=datetime(2028, 1, 1, tzinfo=dt_timezone.utc))
            before_boundary = datetime(2025, 4, 9, 13, 59, tzinfo=dt_timezone.utc)
            after_boundary = before_boundary + timedelta(minutes=1)
            later = datetime(2026, 9, 27, 1, tzinfo=dt_timezone.utc)
            expected = {}

            def entitlement(snapshot, created, *, paid=False, kind="COUNCIL_REGISTRATION"):
                row = Entitlement.objects.create(owner_id=owner.pk, dog_id_snapshot=snapshot, kind=kind,
                    entitlement_key="lifetime", promised_points=275 if paid else 300,
                    point_entry_id=entry.pk if paid else None, collected_at=created if paid else None)
                Entitlement.objects.filter(pk=row.pk).update(created_at=created)
                return row

            def submission(row, at, year):
                record = Submission.objects.create(owner_id=owner.pk, dog_id_snapshot=row.dog_id_snapshot,
                    dog_name_snapshot="Historical dog", kind=row.kind, entitlement_id=row.pk,
                    request_id=uuid4(), request_fingerprint="a" * 64, registration_number="00042",
                    registration_year=year, awarded_points=275 if row.point_entry_id else 0,
                    response_snapshot={"original": str(uuid4()), "balance": 456},
                    filename="old-registration.pdf", file="documents/original.pdf", file_sha256="b" * 64)
                Submission.objects.filter(pk=record.pk).update(submitted_at=at)

            explicit = entitlement(710, later, paid=True)
            submission(explicit, before_boundary, 2025)
            submission(explicit, later, 2027)
            expected[explicit.pk] = 2025
            upload = entitlement(711, later)
            submission(upload, before_boundary, None)
            submission(upload, later, 2027)
            expected[upload.pk] = 2025
            after = entitlement(712, later)
            submission(after, after_boundary, None)
            expected[after.pk] = 2026
            orphan = entitlement(713, after_boundary)
            expected[orphan.pk] = 2026
            microchip = entitlement(714, before_boundary, kind="MICROCHIP_REGISTRATION")
            expected[microchip.pk] = None
            old_entitlements = list(Entitlement.objects.order_by("id").values())
            old_submissions = list(Submission.objects.order_by("id").values())
            old_entries = list(Entry.objects.order_by("id").values())

            annual = [("evidence", "0005_council_annual_rewards") if app == "evidence" else (app, name)
                      for app, name in latest]
            intermediate = MigrationExecutor(connection)
            intermediate.migrate(annual)
            annual_apps = intermediate.loader.project_state(annual).apps
            annual_entitlements = list(annual_apps.get_model("evidence", "DocumentEntitlement").objects.order_by("id").values())
            annual_submissions = list(annual_apps.get_model("evidence", "DocumentSubmission").objects.order_by("id").values())
            MigrationExecutor(connection).migrate(latest)
            self.assertEqual(list(DocumentEntitlement.objects.order_by("id").values(*annual_entitlements[0].keys())), annual_entitlements)
            self.assertEqual(list(DocumentSubmission.objects.order_by("id").values(*annual_submissions[0].keys())), annual_submissions)
            self.assertTrue(all(row.valid_to is None for row in DocumentEntitlement.objects.all()))
            self.assertTrue(all(row.document_reading is None and row.registry_name == "" and row.document_dog_name == ""
                                for row in DocumentSubmission.objects.all()))
            actual = list(DocumentEntitlement.objects.order_by("id").values(*annual_entitlements[0].keys()))
            for row in actual:
                self.assertEqual(row.pop("registration_year"), expected[row["id"]])
            self.assertEqual(actual, old_entitlements)
            self.assertEqual(list(DocumentSubmission.objects.order_by("id").values(*old_submissions[0].keys())), old_submissions)
            self.assertEqual(list(PointEntry.objects.order_by("id").values()), old_entries)
        finally:
            MigrationExecutor(connection).migrate(latest)


class RegistrationCorrectionMigrationTests(TransactionTestCase):
    def test_boundary_is_copied_only_from_known_council_expiry_without_changing_history(self):
        from datetime import date
        from django.db.migrations.executor import MigrationExecutor

        executor = MigrationExecutor(connection)
        latest = executor.loader.graph.leaf_nodes()
        before = [("evidence", "0006_council_document_expiry") if app == "evidence" else (app, name)
                  for app, name in latest]
        try:
            executor.migrate(before)
            apps = executor.loader.project_state(before).apps
            owner = apps.get_model("accounts", "User").objects.create(email="correction-migration@example.com")
            Entitlement = apps.get_model("evidence", "DocumentEntitlement")
            for dog_id, kind, expiry in ((810, "COUNCIL_REGISTRATION", date(2027, 6, 15)),
                                         (811, "COUNCIL_REGISTRATION", None),
                                         (812, "MICROCHIP_REGISTRATION", None)):
                Entitlement.objects.create(owner_id=owner.pk, dog_id_snapshot=dog_id, kind=kind,
                    entitlement_key="legacy", valid_to=expiry, promised_points=300)
            original = list(Entitlement.objects.order_by("id").values())
            MigrationExecutor(connection).migrate(latest)
            self.assertEqual(list(DocumentEntitlement.objects.order_by("id").values(*original[0].keys())), original)
            self.assertEqual(list(DocumentEntitlement.objects.order_by("id").values_list("renewal_blocked_through", flat=True)),
                             [date(2027, 6, 15), None, None])
        finally:
            MigrationExecutor(connection).migrate(latest)
