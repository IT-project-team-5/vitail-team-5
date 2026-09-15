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
