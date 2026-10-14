import django.db.models.deletion
from django.db import migrations, models


class Migration(migrations.Migration):
    dependencies = [
        ("accounts", "0006_user_dog_map_profile"),
        ("dogs", "0001_initial"),
    ]

    operations = [
        migrations.AddField(
            model_name="user",
            name="public_dog",
            field=models.ForeignKey(
                blank=True,
                default=None,
                null=True,
                on_delete=django.db.models.deletion.SET_NULL,
                related_name="public_profiles",
                to="dogs.dog",
            ),
        ),
    ]
