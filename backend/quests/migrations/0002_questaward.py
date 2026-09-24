import django.db.models.deletion
from django.conf import settings
from django.db import migrations, models


class Migration(migrations.Migration):
    dependencies = [
        ("quests", "0001_initial"),
        ("dogs", "0002_dog_uploaded_photo"),
        ("rewards", "0002_connected_redemptions"),
        migrations.swappable_dependency(settings.AUTH_USER_MODEL),
    ]

    operations = [
        migrations.CreateModel(
            name="QuestAward",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("kind", models.CharField(choices=[("BIRTHDAY", "Birthday")], max_length=20)),
                ("dog_id_snapshot", models.PositiveBigIntegerField()),
                ("dog_name_snapshot", models.CharField(max_length=100)),
                ("year", models.PositiveSmallIntegerField()),
                ("rules_version", models.CharField(max_length=40)),
                ("awarded_at", models.DateTimeField(auto_now_add=True)),
                ("dog", models.ForeignKey(null=True, on_delete=django.db.models.deletion.SET_NULL, related_name="quest_awards", to="dogs.dog")),
                ("owner", models.ForeignKey(on_delete=django.db.models.deletion.PROTECT, related_name="quest_awards", to=settings.AUTH_USER_MODEL)),
                ("point_entry", models.OneToOneField(on_delete=django.db.models.deletion.PROTECT, related_name="quest_award", to="rewards.pointentry")),
            ],
            options={
                "ordering": ("-awarded_at", "-id"),
                "constraints": [models.UniqueConstraint(fields=("kind", "dog_id_snapshot", "year"), name="quest_award_dog_year_unique")],
            },
        ),
    ]
