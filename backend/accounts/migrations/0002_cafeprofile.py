import django.db.models.deletion
from django.conf import settings
from django.db import migrations, models


class Migration(migrations.Migration):
    dependencies = [("accounts", "0001_initial")]

    operations = [
        migrations.CreateModel(
            name="CafeProfile",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("address", models.CharField(blank=True, max_length=255)),
                ("description", models.TextField(blank=True, max_length=2000)),
                ("opening_hours", models.CharField(blank=True, max_length=500)),
                ("user", models.OneToOneField(on_delete=django.db.models.deletion.CASCADE, related_name="cafe_profile", to=settings.AUTH_USER_MODEL)),
            ],
        ),
    ]
