from django.db import migrations, models


class Migration(migrations.Migration):
    dependencies = [("evidence", "0003_reward_metadata")]

    operations = [
        migrations.AddField(
            model_name="documentsubmission", name="council_name",
            field=models.CharField(blank=True, max_length=100),
        ),
        migrations.AddField(
            model_name="documentsubmission", name="registration_year",
            field=models.PositiveSmallIntegerField(blank=True, null=True),
        ),
    ]
