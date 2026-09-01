import django.core.validators
import django.db.models.deletion
from django.conf import settings
from django.db import migrations, models


def seed_breeds(apps, schema_editor):
    Breed = apps.get_model("dogs", "Breed")
    breeds = (
        ("Australian Kelpie", "HIGH", "MEDIUM", False),
        ("Cavalier King Charles Spaniel", "MODERATE", "SMALL", True),
        ("French Bulldog", "LOW", "SMALL", True),
        ("German Shepherd", "HIGH", "LARGE", False),
        ("Golden Retriever", "HIGH", "LARGE", False),
        ("Labrador Retriever", "HIGH", "LARGE", False),
        ("Mixed Breed", "MODERATE", "MEDIUM", False),
        ("Pug", "LOW", "SMALL", True),
    )
    Breed.objects.bulk_create(
        [
            Breed(
                name=name,
                energy_level=energy_level,
                default_size=default_size,
                is_brachycephalic=is_brachycephalic,
            )
            for name, energy_level, default_size, is_brachycephalic in breeds
        ]
    )


def remove_seed_breeds(apps, schema_editor):
    Breed = apps.get_model("dogs", "Breed")
    Breed.objects.filter(
        name__in=(
            "Australian Kelpie",
            "Cavalier King Charles Spaniel",
            "French Bulldog",
            "German Shepherd",
            "Golden Retriever",
            "Labrador Retriever",
            "Mixed Breed",
            "Pug",
        )
    ).delete()


class Migration(migrations.Migration):
    initial = True

    dependencies = [migrations.swappable_dependency(settings.AUTH_USER_MODEL)]

    operations = [
        migrations.CreateModel(
            name="Breed",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("name", models.CharField(max_length=100, unique=True)),
                ("energy_level", models.CharField(choices=[("LOW", "Low"), ("MODERATE", "Moderate"), ("HIGH", "High")], max_length=10)),
                ("default_size", models.CharField(choices=[("SMALL", "Small"), ("MEDIUM", "Medium"), ("LARGE", "Large")], max_length=10)),
                ("is_brachycephalic", models.BooleanField(default=False)),
            ],
            options={"ordering": ("name",)},
        ),
        migrations.CreateModel(
            name="Dog",
            fields=[
                ("id", models.BigAutoField(auto_created=True, primary_key=True, serialize=False, verbose_name="ID")),
                ("name", models.CharField(max_length=100)),
                ("photo", models.URLField(blank=True, null=True)),
                ("age_months", models.PositiveIntegerField(validators=[django.core.validators.MinValueValidator(0)])),
                ("size", models.CharField(choices=[("SMALL", "Small"), ("MEDIUM", "Medium"), ("LARGE", "Large")], max_length=10)),
                ("is_brachycephalic", models.BooleanField()),
                ("created_at", models.DateTimeField(auto_now_add=True)),
                ("breed", models.ForeignKey(on_delete=django.db.models.deletion.PROTECT, related_name="dogs", to="dogs.breed")),
                ("owner", models.ForeignKey(on_delete=django.db.models.deletion.CASCADE, related_name="dogs", to=settings.AUTH_USER_MODEL)),
            ],
            options={"ordering": ("created_at", "id")},
        ),
        migrations.RunPython(seed_breeds, remove_seed_breeds),
    ]
