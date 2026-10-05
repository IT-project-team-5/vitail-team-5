from django.db import migrations, models


class Migration(migrations.Migration):
    dependencies = [("dogs", "0005_doggoaltarget")]

    operations = [
        migrations.AddField(
            model_name="dog", name="goal_owner_version",
            field=models.PositiveIntegerField(default=0, editable=False),
        ),
        migrations.AddField(
            model_name="doggoaltarget", name="owner_version",
            field=models.PositiveIntegerField(default=0, editable=False),
        ),
    ]
