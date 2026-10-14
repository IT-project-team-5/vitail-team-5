from django.db import migrations, models


class Migration(migrations.Migration):
    dependencies = [
        ("accounts", "0005_user_activity_preferences"),
    ]

    operations = [
        migrations.AddField(
            model_name="user",
            name="dog_avatar_breed",
            field=models.CharField(
                max_length=20,
                choices=[
                    ("goldenRetriever", "Golden retriever"),
                    ("corgi", "Corgi"),
                    ("husky", "Husky"),
                    ("dalmatian", "Dalmatian"),
                    ("beagle", "Beagle"),
                    ("shiba", "Shiba"),
                    ("poodle", "Poodle"),
                    ("dachshund", "Dachshund"),
                    ("cat", "Cat"),
                ],
                default="goldenRetriever",
            ),
        ),
        migrations.AddField(
            model_name="user",
            name="bandana_color",
            field=models.CharField(
                max_length=10,
                choices=[("none", "No bandana"), ("red", "Red"), ("yellow", "Yellow"), ("green", "Green")],
                default="none",
            ),
        ),
        migrations.AddConstraint(
            model_name="user",
            constraint=models.CheckConstraint(
                condition=models.Q(dog_avatar_breed__in=("goldenRetriever", "corgi", "husky", "dalmatian", "beagle", "shiba", "poodle", "dachshund", "cat")),
                name="user_dog_avatar_breed_known",
            ),
        ),
        migrations.AddConstraint(
            model_name="user",
            constraint=models.CheckConstraint(
                condition=models.Q(bandana_color__in=("none", "red", "yellow", "green")),
                name="user_bandana_color_known",
            ),
        ),
    ]
