from django.db import migrations, models


class Migration(migrations.Migration):
    dependencies = [("venues", "0001_initial")]

    operations = [
        migrations.AddField(
            model_name="venue", name="import_source",
            field=models.CharField(blank=True, max_length=128, null=True, unique=True),
        ),
        migrations.AddField(
            model_name="venue", name="source_url",
            field=models.URLField(blank=True, max_length=2048),
        ),
    ]
