from datetime import timedelta
from uuid import uuid4

from django.db import connection
from django.db.migrations.executor import MigrationExecutor
from django.test import TransactionTestCase
from django.utils import timezone


class ExplicitWalkDogMigrationTests(TransactionTestCase):
    def test_existing_join_ids_and_links_survive_without_fabricated_history(self):
        executor = MigrationExecutor(connection)
        leaves = executor.loader.graph.leaf_nodes()
        old_target = [("walks", "0001_initial")]
        try:
            executor.migrate(old_target)
            executor = MigrationExecutor(connection)
            # Unrelated apps remain at their applied versions when only Walk
            # is rolled back. Use that actual state, not just Walk's ancestors.
            old = executor.loader.project_state(list(executor.loader.applied_migrations)).apps
            User, Breed, Dog, Walk = (old.get_model(app, model) for app, model in (
                ("accounts", "User"), ("dogs", "Breed"), ("dogs", "Dog"), ("walks", "Walk")))
            owner = User.objects.create(email="join-migration@example.com", display_name="Owner", role="OWNER")
            breed = Breed.objects.create(name="Join migration breed", energy_level="LOW", default_size="SMALL")
            dog = Dog.objects.create(owner=owner, breed=breed, name="Current name not historical", age_months=1, size="SMALL", is_brachycephalic=False)
            now = timezone.now()
            walk = Walk.objects.create(owner=owner, request_id=uuid4(), request_fingerprint="a" * 64,
                                       started_at=now - timedelta(minutes=5), ended_at=now, point_date=now.date(), distance_m=1000, points_awarded=8)
            walk.dogs.add(dog)
            old_id = Walk.dogs.through.objects.get(walk_id=walk.pk, dog_id=dog.pk).pk
            entry = old.get_model("rewards", "PointEntry").objects.create(
                user_id=owner.pk, amount=8, remaining_points=8, type="EARN", source_reference=f"walk:{walk.pk}",
                earn_category="WALK", earned_on=now.date(), rules_version="test-migration", expires_at=now + timedelta(days=365),
            )
            executor = MigrationExecutor(connection)
            executor.migrate(leaves)
            current = executor.loader.project_state(leaves).apps
            participant = current.get_model("walks", "WalkDog").objects.get(pk=old_id)
            self.assertEqual((participant.walk_id, participant.dog_id, participant.dog_id_snapshot), (walk.pk, dog.pk, dog.pk))
            self.assertIsNone(participant.dog_name_snapshot)
            self.assertIsNone(participant.active_seconds)
            self.assertIsNone(participant.distance_m)
            upgraded_walk = current.get_model("walks", "Walk").objects.get(pk=walk.pk)
            self.assertIsNone(upgraded_walk.active_seconds)
            self.assertEqual(upgraded_walk.base_point_entry_id, entry.pk)
            self.assertEqual(current.get_model("rewards", "PointEntry").objects.filter(user_id=owner.pk).count(), 1)
        finally:
            MigrationExecutor(connection).migrate(leaves)
