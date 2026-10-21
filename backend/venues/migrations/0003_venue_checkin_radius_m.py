import django.core.validators
from django.db import migrations, models


class Migration(migrations.Migration):
    dependencies = [("venues", "0002_venue_import_source")]

    operations = [
        migrations.AddField(
            model_name="venue",
            name="checkin_radius_m",
            field=models.PositiveIntegerField(default=20, validators=[django.core.validators.MinValueValidator(1)]),
        ),
        migrations.AddConstraint(
            model_name="venue",
            constraint=models.CheckConstraint(condition=models.Q(checkin_radius_m__gt=0), name="venue_checkin_radius_positive"),
        ),
    ]
