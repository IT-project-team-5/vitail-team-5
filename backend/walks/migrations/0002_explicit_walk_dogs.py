"""Promote the existing join table without recreating it or changing row IDs."""
import django.db.models.deletion
from django.db import migrations, models
from django.db.migrations.exceptions import IrreversibleError


def snapshot_ids(apps, schema_editor):
    Participant = apps.get_model("walks", "WalkDog")
    Participant.objects.using(schema_editor.connection.alias).update(dog_id_snapshot=models.F("dog_id"))


def ensure_links_can_be_implicit(apps, schema_editor):
    Participant = apps.get_model("walks", "WalkDog")
    if Participant.objects.using(schema_editor.connection.alias).filter(dog_id__isnull=True).exists():
        raise IrreversibleError("Deleted-dog history cannot be represented by the old implicit join table.")


class Migration(migrations.Migration):
    dependencies = [("walks", "0001_initial"), ("dogs", "0003_dog_date_of_birth")]

    operations = [
        migrations.SeparateDatabaseAndState(
            database_operations=[],
            state_operations=[
                migrations.CreateModel(
                    name="WalkDog",
                    fields=[
                        ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                        ("walk", models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name="participants", to="walks.walk")),
                        ("dog", models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name="walk_participations", to="dogs.dog")),
                    ],
                    options={"db_table": "walks_walk_dogs", "unique_together": {("walk", "dog")}},
                ),
                migrations.AlterField(model_name="walk", name="dogs", field=models.ManyToManyField(related_name="walks", through="walks.WalkDog", to="dogs.dog")),
            ],
        ),
        migrations.AddField(model_name="walkdog", name="dog_id_snapshot", field=models.BigIntegerField(null=True)),
        migrations.AddField(model_name="walkdog", name="dog_name_snapshot", field=models.CharField(blank=True, max_length=100, null=True)),
        migrations.AddField(model_name="walkdog", name="active_seconds", field=models.PositiveIntegerField(blank=True, null=True)),
        migrations.AddField(model_name="walkdog", name="distance_m", field=models.DecimalField(blank=True, decimal_places=2, max_digits=10, null=True)),
        migrations.RunPython(snapshot_ids, migrations.RunPython.noop),
        migrations.AlterField(model_name="walkdog", name="dog_id_snapshot", field=models.BigIntegerField()),
        migrations.AlterField(model_name="walkdog", name="dog", field=models.ForeignKey(blank=True, null=True, on_delete=django.db.models.deletion.SET_NULL, related_name="walk_participations", to="dogs.dog")),
        migrations.RunPython(migrations.RunPython.noop, ensure_links_can_be_implicit),
        migrations.AlterUniqueTogether(name="walkdog", unique_together=set()),
        migrations.AddConstraint(model_name="walkdog", constraint=models.UniqueConstraint(fields=("walk", "dog_id_snapshot"), name="walk_dog_snapshot_unique")),
        migrations.AddConstraint(model_name="walkdog", constraint=models.CheckConstraint(condition=models.Q(dog_id_snapshot__gt=0), name="walk_dog_snapshot_positive")),
        migrations.AddConstraint(model_name="walkdog", constraint=models.CheckConstraint(condition=models.Q(distance_m__isnull=True) | models.Q(distance_m__gte=0), name="walk_dog_distance_nonnegative")),
        migrations.AddIndex(model_name="walkdog", index=models.Index(fields=("dog_id_snapshot", "walk"), name="walk_dog_history")),
    ]
