from django.db import connection
from django.db.migrations.executor import MigrationExecutor
from django.test import TransactionTestCase


class DogMigrationRollbackTests(TransactionTestCase):
    migrate_to = [("dogs", "0001_initial")]

    def test_initial_migration_rolls_back_with_seeded_breed_in_use(self):
        executor = MigrationExecutor(connection)
        latest_targets = executor.loader.graph.leaf_nodes()
        try:
            # TransactionTestCase flushes seeded rows after earlier tests.
            # Reapply the migration so this test always exercises real seed data.
            executor.migrate([("dogs", None)])
            executor = MigrationExecutor(connection)
            executor.migrate(self.migrate_to)
            apps = executor.loader.project_state(self.migrate_to).apps
            User = apps.get_model("accounts", "User")
            Breed = apps.get_model("dogs", "Breed")
            Dog = apps.get_model("dogs", "Dog")

            owner = User.objects.create(
                email="migration-owner@example.com",
                display_name="Migration Owner",
                role="OWNER",
            )
            breed = Breed.objects.get(name="Mixed Breed")
            Dog.objects.create(
                owner=owner,
                name="Milo",
                breed=breed,
                age_months=0,
                size="MEDIUM",
                is_brachycephalic=False,
            )

            executor = MigrationExecutor(connection)
            executor.migrate([("dogs", None)])
            tables = connection.introspection.table_names()
            self.assertNotIn("dogs_dog", tables)
            self.assertNotIn("dogs_breed", tables)
        finally:
            MigrationExecutor(connection).migrate(latest_targets)


class GoalTargetMigrationTests(TransactionTestCase):
    def test_target_table_does_not_backfill_goals_or_change_history_and_balances(self):
        from datetime import date, datetime, timedelta, UTC
        executor = MigrationExecutor(connection)
        latest = executor.loader.graph.leaf_nodes()
        before = [("dogs", "0004_dog_daily_goal")]
        try:
            executor.migrate(before)
            executor = MigrationExecutor(connection)
            apps = executor.loader.project_state(list(executor.loader.applied_migrations)).apps
            User = apps.get_model("accounts", "User")
            Breed = apps.get_model("dogs", "Breed")
            Dog = apps.get_model("dogs", "Dog")
            Goal = apps.get_model("dogs", "DogDailyGoal")
            Entry = apps.get_model("rewards", "PointEntry")
            owner = User.objects.create(email="goal-migration@example.com", role="OWNER")
            breed = Breed.objects.create(name="Goal migration breed", energy_level="LOW", default_size="SMALL")
            dog = Dog.objects.create(owner=owner, breed=breed, name="Original", age_months=12,
                size="SMALL", is_brachycephalic=False)
            now = datetime(2026, 9, 20, tzinfo=UTC)
            goal = Goal.objects.create(dog=dog, owner=owner, dog_id_snapshot=dog.pk,
                local_date=date(2026, 9, 19), target_active_seconds=500, inputs_snapshot={"original": True},
                rules_version="historical", finalised_at=now, final_active_seconds=550, final_goal_met=True)
            entry = Entry.objects.create(user=owner, amount=37, remaining_points=19, type="ADMIN",
                expires_at=now + timedelta(days=365), source_reference="goal-migration-original")
            executor = MigrationExecutor(connection)
            executor.migrate(latest)
            apps = executor.loader.project_state(latest).apps
            self.assertEqual(apps.get_model("dogs", "DogGoalTarget").objects.count(), 0)
            preserved = apps.get_model("dogs", "DogDailyGoal").objects.get(pk=goal.pk)
            self.assertEqual((preserved.target_active_seconds, preserved.final_active_seconds, preserved.final_goal_met), (500, 550, True))
            self.assertEqual(preserved.inputs_snapshot, {"original": True})
            preserved_entry = apps.get_model("rewards", "PointEntry").objects.get(pk=entry.pk)
            self.assertEqual((preserved_entry.amount, preserved_entry.remaining_points), (37, 19))
        finally:
            MigrationExecutor(connection).migrate(latest)


class GoalOwnershipMigrationTests(TransactionTestCase):
    def test_existing_configuration_snapshots_and_ledger_are_preserved(self):
        from datetime import date, timedelta
        from django.utils import timezone
        executor = MigrationExecutor(connection)
        latest = executor.loader.graph.leaf_nodes()
        try:
            executor.migrate([("dogs", "0005_doggoaltarget")])
            executor = MigrationExecutor(connection)
            apps = executor.loader.project_state(list(executor.loader.applied_migrations)).apps
            owner = apps.get_model("accounts", "User").objects.create(email="ownership-migration@example.com", role="OWNER")
            breed = apps.get_model("dogs", "Breed").objects.create(name="Preserved", energy_level="LOW", default_size="SMALL")
            dog = apps.get_model("dogs", "Dog").objects.create(owner=owner, breed=breed, name="Milo",
                age_months=12, size="SMALL", is_brachycephalic=False)
            target = apps.get_model("dogs", "DogGoalTarget").objects.create(dog=dog, owner=owner,
                dog_id_snapshot=dog.pk, effective_from=date(2026, 10, 4), target_active_seconds=90)
            goal = apps.get_model("dogs", "DogDailyGoal").objects.create(dog=dog, owner=owner,
                dog_id_snapshot=dog.pk, local_date=target.effective_from, target_active_seconds=90,
                inputs_snapshot={"target_id": target.pk, "eligible_since": target.created_at.isoformat()},
                rules_version="manual-duration-v1", finalised_at=timezone.now(), final_active_seconds=100, final_goal_met=True)
            entry = apps.get_model("rewards", "PointEntry").objects.create(user=owner, type="ADMIN", amount=37,
                remaining_points=19, expires_at=timezone.now() + timedelta(days=365), source_reference="preserved-goal-owner")
            before = {model: list(apps.get_model(app, model).objects.values()) for app, model in
                      (("dogs", "DogDailyGoal"), ("rewards", "PointEntry"))}
            MigrationExecutor(connection).migrate(latest)
            apps = MigrationExecutor(connection).loader.project_state(latest).apps
            self.assertEqual(apps.get_model("dogs", "Dog").objects.get(pk=dog.pk).goal_owner_version, 0)
            preserved = apps.get_model("dogs", "DogGoalTarget").objects.get(pk=target.pk)
            self.assertEqual((preserved.owner_version, preserved.target_active_seconds, preserved.created_at),
                             (0, 90, target.created_at))
            for app, model in (("dogs", "DogDailyGoal"), ("rewards", "PointEntry")):
                self.assertEqual(list(apps.get_model(app, model).objects.values()), before[model])
        finally:
            MigrationExecutor(connection).migrate(latest)
