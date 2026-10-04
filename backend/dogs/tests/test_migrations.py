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
