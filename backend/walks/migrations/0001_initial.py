import django.db.models.deletion
from django.conf import settings
from django.db import migrations, models


class Migration(migrations.Migration):
    initial = True
    dependencies = [
        migrations.swappable_dependency(settings.AUTH_USER_MODEL),
        ("dogs", "0001_initial"),
    ]
    operations = [
        migrations.CreateModel(
            name="Walk",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("request_id", models.UUIDField()),
                ("request_fingerprint", models.CharField(editable=False, max_length=64)),
                ("started_at", models.DateTimeField()),
                ("ended_at", models.DateTimeField()),
                ("point_date", models.DateField()),
                ("distance_m", models.DecimalField(decimal_places=2, max_digits=10)),
                ("points_awarded", models.PositiveSmallIntegerField(default=0)),
                ("created_at", models.DateTimeField(auto_now_add=True)),
                ("dogs", models.ManyToManyField(related_name="walks", to="dogs.dog")),
                ("owner", models.ForeignKey(on_delete=django.db.models.deletion.PROTECT, related_name="walks", to=settings.AUTH_USER_MODEL)),
            ],
            options={
                "ordering": ("-ended_at", "-id"),
                "constraints": [
                    models.UniqueConstraint(fields=("owner", "request_id"), name="walk_owner_request_unique"),
                    models.CheckConstraint(condition=models.Q(ended_at__gt=models.F("started_at")), name="walk_end_after_start"),
                    models.CheckConstraint(condition=models.Q(distance_m__gte=0), name="walk_distance_nonnegative"),
                    models.CheckConstraint(condition=models.Q(points_awarded__lte=40), name="walk_points_at_most_40"),
                ],
            },
        ),
    ]
