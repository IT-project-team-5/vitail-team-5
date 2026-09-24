from django.db import migrations, models


def seed_definitions(apps, schema_editor):
    definition = apps.get_model("quests", "QuestDefinition")
    for index, (code, title, description) in enumerate([
        ("DAILY_GOAL", "Daily goal", "Your dogs' daily walking goals."),
        ("STREAK", "Walking streak", "Build a streak with daily walks."),
        ("BIRTHDAY", "Birthday bonus", "Celebrate your dogs' birthdays."),
        ("CHECK_IN", "Venue check-in", "Spend time at participating venues."),
        ("DOCUMENTS", "Documents", "Submit self-reported documents to receive eligible points. Submissions may be checked later."),
    ]):
        definition.objects.using(schema_editor.connection.alias).create(
            code=code, title=title, description=description, sort_order=index,
            rules_version="2026-09-24",
        )


class Migration(migrations.Migration):
    initial = True
    dependencies = []

    operations = [
        migrations.CreateModel(
            name="QuestDefinition",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("code", models.CharField(choices=[("DAILY_GOAL", "Daily goal"), ("STREAK", "Walking streak"), ("BIRTHDAY", "Dog birthday"), ("CHECK_IN", "Venue check-in"), ("DOCUMENTS", "Documents")], max_length=20, unique=True)),
                ("title", models.CharField(max_length=100)),
                ("description", models.CharField(blank=True, max_length=500)),
                ("is_enabled", models.BooleanField(default=True)),
                ("sort_order", models.PositiveSmallIntegerField(default=0)),
                ("rules_version", models.CharField(default="2026-09-24", max_length=40)),
                ("updated_at", models.DateTimeField(auto_now=True)),
            ],
            options={"ordering": ("sort_order", "code")},
        ),
        migrations.RunPython(seed_definitions, migrations.RunPython.noop),
    ]
